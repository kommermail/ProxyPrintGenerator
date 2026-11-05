// ProxyPrintEngine.cs
// The whole pipeline (parse, Scryfall lookup, image preparation, page
// by page assembly) as one async call with progress and cancellation,
// ported from ProxyPrintEngine.swift. Faces are prepared one at a time
// and released after drawing, so memory stays flat even at 1800 DPI.

using System.IO;

namespace ProxyPrintGenerator.Engine;

public readonly record struct PrintProgress(string Stage, long Done, long Total)
{
    public double Fraction => Total > 0 ? (double)Done / Total : 0;
}

public sealed record PrintJobResult(string OutputPath, int FrontCount, int BackCount, List<string> BackNames,
    int PageCount, long SizeBytes, List<string> Warnings)
{
    /// Back to back builds: the 0-based page where the front/back pairs
    /// for duplex printing begin, or -1 when there are none.
    public int DuplexStartPage { get; init; } = -1;
    public int DuplexSheets => DuplexStartPage < 0 ? 0 : (PageCount - DuplexStartPage) / 2;
}

public sealed class PrintJobOptions
{
    public int Scale { get; init; } = 4;
    public InkCalibration Calibration { get; init; } = InkCalibration.None;
    public double Vibrance { get; init; }
    public double MidtoneLift { get; init; }
    public bool PngOverride { get; init; }
    public bool ShuffleDeck { get; init; }
    public SafeAreaProfile SafeArea { get; init; }
    public bool MaximizeGap { get; init; }
    public bool ThickGuides { get; init; }
    public bool Guides { get; init; } = true;
    public OutputFormat Format { get; init; } = OutputFormat.Pdf;
    public double JpegQuality { get; init; } = 0.65;
    public double ExtraGapMM { get; init; }
    public double ShiftUpMM { get; init; }
    /// Two sided cards print back to back (duplex) after the one sided
    /// pages, instead of each back as its own card.
    public bool BackToBack { get; init; }
}

public static class ProxyPrintEngine
{
    public static string AppDataRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ProxyPrintGenerator");
    public static string DefaultCacheDirectory => Path.Combine(AppDataRoot, "FaceCache");

    private sealed record FaceSource(string Url, string Set, string Collector);

    public static async Task<PrintJobResult> RunAsync(string deckText, string outputPath, PrintJobOptions o,
        IProgress<PrintProgress> progress, CancellationToken ct)
    {
        var parsed = DeckList.Parse(deckText);
        var printable = parsed.Entries.Where(e => e.Board == DeckBoard.Main).ToList();
        if (printable.Count == 0)
            throw new PpgException("[PPG:DECK-EMPTY] No printable cards in the deck list.");

        progress.Report(new("Looking up cards on Scryfall", 0, 1));
        var keys = printable.Where(e => e.HasPrinting).Select(e => new PrintingKey(e.SetCode!, e.CollectorNumber!))
            .Distinct().OrderBy(k => k.Set).ThenBy(k => k.CollectorNumber, StringComparer.Ordinal).ToList();
        var cards = await ScryfallClient.LookupPrintingsAsync(keys, true, ct).ConfigureAwait(false);

        var resolved = new List<(DeckEntry Entry, ScryfallCard Card)>();
        var namedCache = new Dictionary<string, ScryfallCard>();
        foreach (var entry in printable)
        {
            ct.ThrowIfCancellationRequested();
            if (entry.HasPrinting)
            {
                if (!cards.TryGetValue(new PrintingKey(entry.SetCode!, entry.CollectorNumber!), out var card))
                    throw new PpgException($"[PPG:CARD-LOOKUP] No card data for ({entry.SetCode}) {entry.CollectorNumber}");
                resolved.Add((entry, card));
            }
            else
            {
                var cacheKey = $"{entry.Name}|{entry.SetCode}";
                if (!namedCache.TryGetValue(cacheKey, out var card))
                {
                    card = await ScryfallClient.LookupNamedAsync(entry.Name, entry.SetCode, ct).ConfigureAwait(false);
                    namedCache[cacheKey] = card;
                }
                resolved.Add((entry, card));
            }
        }

        // Flatten into face references: fronts in deck order, backs in order.
        var sources = new Dictionary<FaceRef, FaceSource>();
        // Each copy keeps its back (if any) beside it, so a shuffle or a
        // back to back layout can never pair a front with the wrong back.
        var copies = new List<(string Name, FaceRef Front, FaceRef? Back)>();
        var backs = new List<(string Name, FaceRef Face)>();
        foreach (var (entry, card) in resolved)
        {
            var urls = ScryfallClient.FacePngUrls(card);
            var front = FaceRef.Of(card.Set, card.CollectorNumber, 0);
            sources[front] = new FaceSource(urls[0], card.Set, card.CollectorNumber);
            FaceRef? back = null;
            if (urls.Count > 1)
            {
                back = FaceRef.Of(card.Set, card.CollectorNumber, 1);
                sources[back.Value] = new FaceSource(urls[1], card.Set, card.CollectorNumber);
                backs.Add((card.Name, back.Value));
            }
            copies.AddRange(Enumerable.Repeat((card.Name, front, back), entry.Quantity));
        }

        if (o.ShuffleDeck)
        {
            // The commander (and a legendary partner beside it) stays at
            // the front; everything after is shuffled.
            var pinCount = 0;
            for (var i = 0; i < Math.Min(2, resolved.Count); i++)
            {
                if (i == 0 || (resolved[i].Card.TypeLine ?? "").Contains("Legendary")) pinCount += resolved[i].Entry.Quantity;
                else break;
            }
            var rest = copies.Skip(pinCount).ToArray();
            Random.Shared.Shuffle(rest);
            copies = copies.Take(pinCount).Concat(rest).ToList();
        }
        var fronts = copies.Select(c => c.Front).ToList();
        // Back to back: every two sided copy needs its own back behind it.
        var twoSided = copies.Where(c => c.Back != null).Select(c => (c.Name, c.Front, Back: c.Back!.Value)).ToList();
        if (o.BackToBack) backs = twoSided.Select(c => (c.Name, c.Back)).ToList();

        // PNG is a test print format: capped at a dozen cards and two two
        // sided cards. PDF prints the same pixels far faster.
        if (o.Format == OutputFormat.Png && !o.PngOverride && (fronts.Count > 12 || backs.Count > 2))
            throw new PpgException($"[PPG:PNG-LIMIT] PNG is capped at small test prints: 12 cards and 2 two sided cards at most. " +
                                   $"This build has {fronts.Count} cards and {backs.Count} two sided. Use PDF for the full deck.");

        var pipeline = new ImagePipeline(DefaultCacheDirectory, o.Calibration, o.Vibrance, o.MidtoneLift);

        // Preparation pass over the unique faces warms the disk cache.
        var unique = fronts.Concat(backs.Select(b => b.Face)).Distinct().ToList();
        for (var i = 0; i < unique.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            progress.Report(new("Preparing images", i, unique.Count));
            var src = sources[unique[i]];
            _ = await pipeline.PrepareFaceAsync(src.Url, src.Set, src.Collector, unique[i].FaceIndex, o.Scale, ct).ConfigureAwait(false);
            progress.Report(new("Preparing images", i + 1, unique.Count));
        }
        GC.Collect();

        var plan = o.BackToBack && twoSided.Count > 0
            ? LayoutPlan.MakeBackToBack(copies.Where(c => c.Back == null).Select(c => c.Front).ToList(), twoSided)
            : LayoutPlan.Make(fronts, backs);
        var settings = new PrintSettings
        {
            GapMM = 3.0 + o.ExtraGapMM,
            BufferMM = 1.0,
            ShowGuides = o.Guides,
            ShiftUpMM = o.ShiftUpMM,
            SafeArea = o.SafeArea,
            MaximizeGap = o.MaximizeGap,
            ThickGuides = o.ThickGuides,
            Calibration = o.Calibration,
        };

        if (o.Format == OutputFormat.Jpeg)
        {
            var pagePixels = (long)(settings.PageHeightPoints / 72.0 * 300.0 * o.Scale);
            if (pagePixels * plan.PageCount > 65_535)
                throw new PpgException($"[PPG:JPEG-SIZE] JPEG cannot hold this build: the format caps an image at 65,535 pixels tall " +
                                       $"and {plan.PageCount} pages at this scale run {pagePixels * plan.PageCount}. Use PNG or PDF here, or lower the scale.");
        }

        Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
        IPageBuilder builder;
        if (o.Format == OutputFormat.Pdf)
            builder = new PdfBuilder(outputPath, settings, "Proxies");
        else
        {
            var ib = new ImagePageBuilder(outputPath, settings, o.Scale, o.Format, o.JpegQuality)
            {
                ShouldCancel = () => ct.IsCancellationRequested,
                OnVerifyProgress = (d, t) => progress.Report(new("Checking the stitched PNG", d, t)),
            };
            builder = ib;
        }
        builder.OnFaceDrawn = (placed, total) =>
            progress.Report(new(o.Format == OutputFormat.Pdf ? "Assembling PDF" : "Assembling pages", placed, total));

        try
        {
            builder.Begin(plan.TotalPlacements, plan.PageCount);
            for (var pageIndex = 0; pageIndex < plan.Pages.Count; pageIndex++)
            {
                ct.ThrowIfCancellationRequested();
                builder.BeginPage();
                Func<Task<PreparedFace>> Loader(FaceRef r) => () =>
                {
                    var s = sources[r];
                    return pipeline.PrepareFaceAsync(s.Url, s.Set, s.Collector, r.FaceIndex, o.Scale, ct);
                };
                var pageFronts = plan.Pages[pageIndex];
                for (var slot = 0; slot < pageFronts.Count; slot++)
                    await builder.DrawCardAsync(slot, pageFronts[slot], Loader(pageFronts[slot])).ConfigureAwait(false);
                if (plan.BackPlacements.TryGetValue(pageIndex, out var pageBacks))
                    foreach (var slot in pageBacks.Keys.Order())
                        await builder.DrawCardAsync(slot, pageBacks[slot], Loader(pageBacks[slot])).ConfigureAwait(false);
                builder.EndPage();
                GC.Collect();
            }

            progress.Report(new(o.Format switch
            {
                OutputFormat.Pdf => "Saving PDF",
                OutputFormat.Png => "Finishing the PNG",
                _ => "Encoding the JPEG",
            }, 0, 1));
            await Task.Run(builder.Finish, ct).ConfigureAwait(false);
        }
        catch
        {
            builder.Dispose();
            try { File.Delete(outputPath); } catch { }
            throw;
        }
        builder.Dispose();

        return new PrintJobResult(outputPath, fronts.Count, backs.Count, plan.BackNames, plan.PageCount,
            new FileInfo(outputPath).Length, parsed.Warnings) { DuplexStartPage = plan.DuplexStartPage };
    }
}
