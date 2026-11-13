// PrinterFit.cs
// "Fit to my printer": asks a printer's driver (nothing is printed) for
// the paper sizes it lists, the paper it is set to now, and how much of
// each edge of a sheet it can't reach. The layout keeps the cards inside
// that reach, so no card edge gets cut off on that printer.
//
// Windows can't see what paper is physically in most home printers; the
// driver's current paper setting is the closest thing, so that is what
// "the paper your printer is set to" means here.

using System.Printing;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator.Views;

/// What a printer's driver said. Margins are for the paper asked about
/// (null when the driver gave no printable area); PaperListed is false
/// when the driver doesn't offer that paper at all.
public sealed record PrinterReading(PrinterMargins? Margins, bool PaperListed, PaperSize? DriverPaper, IReadOnlyList<PaperSize> Sizes);

public static class PrinterFit
{
    private const double MmPerDip = 25.4 / 96.0;
    private static readonly EnumeratedPrintQueueTypes[] Kinds = [EnumeratedPrintQueueTypes.Local, EnumeratedPrintQueueTypes.Connections];

    public static Task<List<string>> PrinterNamesAsync() => Task.Run(() =>
    {
        try
        {
            using var server = new LocalPrintServer();
            return server.GetPrintQueues(Kinds).Select(q => q.FullName).OrderBy(n => n, StringComparer.OrdinalIgnoreCase).ToList();
        }
        catch { return new List<string>(); }
    });

    public static string? DefaultPrinter()
    {
        try { return LocalPrintServer.GetDefaultPrintQueue().FullName; } catch { return null; }
    }

    /// Reads the printer: its paper sizes, its current paper, and its
    /// reach on the given paper (or on its current paper, when null).
    public static Task<PrinterReading> ReadAsync(string printer, PaperSize? paper) => Task.Run(() =>
    {
        using var server = new LocalPrintServer();
        var queue = server.GetPrintQueues(Kinds).FirstOrDefault(q => q.FullName == printer)
                    ?? throw new PpgException($"{printer} isn't installed on this PC any more.");
        var basis = queue.UserPrintTicket ?? queue.DefaultPrintTicket ?? new PrintTicket();
        var driverPaper = FromMedia(basis.PageMediaSize);

        var sizes = new List<PaperSize>();
        foreach (var media in queue.GetPrintCapabilities(basis).PageMediaSizeCapability)
            if (FromMedia(media) is { } p && p.WidthMM >= 67 && p.HeightMM >= 92 && !sizes.Any(s => s.SameSheet(p))
                && !p.Label.Contains("Envelope", StringComparison.OrdinalIgnoreCase) && !p.Label.Contains("Postcard", StringComparison.OrdinalIgnoreCase))
                sizes.Add(p);
        sizes.Sort((a, b) => (a.WidthMM * a.HeightMM).CompareTo(b.WidthMM * b.HeightMM));

        var target = paper ?? driverPaper ?? PaperSize.Letter;
        var wanted = basis.Clone();
        wanted.PageMediaSize = MediaSize(target);
        wanted.PageOrientation = PageOrientation.Portrait;
        var ticket = queue.MergeAndValidatePrintTicket(basis, wanted).ValidatedPrintTicket;
        var listed = FromMedia(ticket.PageMediaSize) is { } got && got.SameSheet(target);

        PrinterMargins? margins = null;
        if (listed && queue.GetPrintCapabilities(ticket).PageImageableArea is { } area)
        {
            var left = area.OriginWidth * MmPerDip;
            var top = area.OriginHeight * MmPerDip;
            margins = new PrinterMargins(
                Math.Max(0, top),
                Math.Max(0, target.HeightMM - top - area.ExtentHeight * MmPerDip),
                Math.Max(0, left),
                Math.Max(0, target.WidthMM - left - area.ExtentWidth * MmPerDip));
        }
        return new PrinterReading(margins, listed, driverPaper, sizes);
    });

    /// The paper as a print ticket names it: by name for the standard
    /// sizes and those the driver listed by name, by measure otherwise.
    public static PageMediaSize MediaSize(PaperSize paper)
    {
        var w = paper.WidthMM / MmPerDip;
        var h = paper.HeightMM / MmPerDip;
        PageMediaSizeName? name = paper.Key switch
        {
            "letter" => PageMediaSizeName.NorthAmericaLetter,
            "a4" => PageMediaSizeName.ISOA4,
            "legal" => PageMediaSizeName.NorthAmericaLegal,
            "tabloid" => PageMediaSizeName.NorthAmericaTabloid,
            "a3" => PageMediaSizeName.ISOA3,
            _ when paper.Key.StartsWith("media:") && Enum.TryParse<PageMediaSizeName>(paper.Key[6..], out var n) => n,
            _ => null,
        };
        return name is { } named ? new PageMediaSize(named, w, h) : new PageMediaSize(w, h);
    }

    /// A ticket's paper as a PaperSize, portrait, matched to a standard
    /// size when it is one.
    public static PaperSize? FromMedia(PageMediaSize? media)
    {
        if (media?.Width is not { } wd || media.Height is not { } hd || wd <= 0 || hd <= 0) return null;
        var w = Math.Round(Math.Min(wd, hd) * MmPerDip, 1);
        var h = Math.Round(Math.Max(wd, hd) * MmPerDip, 1);
        var probe = new PaperSize("", "", w, h);
        if (PaperSize.Standard.FirstOrDefault(s => s.SameSheet(probe)) is { } standard) return standard;
        var size = $"{w:0.#} × {h:0.#} mm";
        if (media.PageMediaSizeName is { } name && name != PageMediaSizeName.Unknown)
            return new PaperSize($"media:{name}", $"{Pretty(name.ToString())} ({size})", w, h);
        return new PaperSize($"custom:{w:0.#}x{h:0.#}", size, w, h);
    }

    /// "NorthAmerica5x7" → "5x7", "ISOA5" → "A5", "JapanHagakiPostcard" → "Hagaki Postcard".
    private static string Pretty(string name)
    {
        foreach (var prefix in new[] { "NorthAmerica", "ISO", "JIS", "Japan", "PRC", "Roc", "Other" })
            if (name.StartsWith(prefix, StringComparison.Ordinal) && name.Length > prefix.Length) { name = name[prefix.Length..]; break; }
        var spaced = new System.Text.StringBuilder();
        for (var i = 0; i < name.Length; i++)
        {
            if (i > 0 && char.IsUpper(name[i]) && char.IsLower(name[i - 1])) spaced.Append(' ');
            spaced.Append(name[i]);
        }
        return spaced.ToString();
    }
}
