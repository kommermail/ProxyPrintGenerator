// Layout.cs
// Page geometry and the page plan, ported from PDFBuilder.swift:
//   - any portrait paper size; as many cards as fit inside the edge the
//     printer can't reach, centered (3x3 on Letter and A4, 4x4 on 11x17
//     and A3)
//   - true card size 63x88 mm, 3 mm gaps measured art edge to art edge,
//     shrinking (to 0.5 mm) before a row or column is given up
//   - 1 mm buffer per card filled with the card's own border color
//   - blue dotted guide at true card size, following the 3 mm corners
//   - fronts in deck order; two sided backs go in the highest free slot
//     of the final page, or on a fresh page
//   - or, back to back: one sided cards first, then front/back page
//     pairs for duplex printing, each back mirrored behind its front

namespace ProxyPrintGenerator.Engine;

public static class PageGeometry
{
    public const double PointsPerMM = 72.0 / 25.4;
    public const double CardWidthPoints = 63 * PointsPerMM;
    public const double CardHeightPoints = 88 * PointsPerMM;
    public const double CardCornerRadiusPoints = 3 * PointsPerMM;
    public const double CardWidthMM = 63, CardHeightMM = 88;
    /// The narrowest gap a grid squeezes to before it drops a row or column.
    public const double MinGapMM = 0.5;
    public static readonly RgbColor GuideColor = new(13, 71, 255);
}

/// A sheet of paper, portrait, in mm. Key names it for the printer:
/// "letter", "a4" and so on for the standard sizes, "media:Name" for a
/// size the printer's driver lists by name, "custom:WxH" otherwise.
public sealed record PaperSize(string Key, string Label, double WidthMM, double HeightMM)
{
    public static readonly PaperSize Letter = new("letter", "Letter (8.5 × 11 in)", 215.9, 279.4);
    public static readonly PaperSize A4 = new("a4", "A4 (210 × 297 mm)", 210, 297);
    public static readonly PaperSize Legal = new("legal", "Legal (8.5 × 14 in)", 215.9, 355.6);
    public static readonly PaperSize Tabloid = new("tabloid", "Tabloid (11 × 17 in)", 279.4, 431.8);
    public static readonly PaperSize A3 = new("a3", "A3 (297 × 420 mm)", 297, 420);
    public static IReadOnlyList<PaperSize> Standard { get; } = [Letter, A4, Legal, Tabloid, A3];

    public string ShortLabel => Label.Contains(" (") ? Label[..Label.IndexOf(" (", StringComparison.Ordinal)] : Label;

    /// True when the two are the same sheet, within a millimeter.
    public bool SameSheet(PaperSize other)
        => Math.Abs(WidthMM - other.WidthMM) < 1.0 && Math.Abs(HeightMM - other.HeightMM) < 1.0;
}

/// How much of each paper edge a printer can't reach, in mm.
public readonly record struct PrinterMargins(double Top, double Bottom, double Left, double Right);

/// A printer's unprintable border, widened by a feed tolerance.
public enum SafeAreaProfile { None, CanonInkjet }

public sealed class PrintSettings
{
    public PaperSize Paper { get; set; } = PaperSize.Letter;
    /// The reach the printer's driver reported. When set, the cards stay
    /// inside it (plus a millimeter for the paper feed), whatever
    /// SafeArea says.
    public PrinterMargins? PrinterMargins { get; set; }
    public double GapMM { get; set; } = 3.0;
    public double BufferMM { get; set; } = 1.0;
    public double ShiftUpMM { get; set; }
    public SafeAreaProfile SafeArea { get; set; } = SafeAreaProfile.None;
    public bool MaximizeGap { get; set; }
    public bool ThickGuides { get; set; }
    public bool ShowGuides { get; set; } = true;
    public InkCalibration Calibration { get; set; } = InkCalibration.None;

    public double PageWidthPoints => Paper.WidthMM * PageGeometry.PointsPerMM;
    public double PageHeightPoints => Paper.HeightMM * PageGeometry.PointsPerMM;

    /// The paper feed's wobble, added to the reach a driver reports.
    public const double FeedToleranceMM = 1.0;

    /// The edges the cards must stay inside, when something says so: the
    /// printer's own reach, or the Canon MAXIFY Letter spec (top 3.0,
    /// bottom 5.0, left 6.4, right 6.3 mm unreachable) plus about 1.5 mm
    /// of feed tolerance.
    private (double Top, double Bottom, double Left, double Right)? Floors
        => PrinterMargins is { } m
            ? (m.Top + FeedToleranceMM, m.Bottom + FeedToleranceMM, m.Left + FeedToleranceMM, m.Right + FeedToleranceMM)
            : SafeArea switch
            {
                SafeAreaProfile.CanonInkjet => (4.5, 6.5, 7.9, 7.8),
                _ => null,
            };

    /// The edges used to count how many cards fit: the floors, or 2 mm.
    private (double Top, double Bottom, double Left, double Right) Edges => Floors ?? (2.0, 2.0, 2.0, 2.0);

    /// Columns and rows that fit, gaps squeezed to their minimum if they
    /// must be. Zero when not even one card fits on the paper.
    public int Columns => Fit(Paper.WidthMM - Edges.Left - Edges.Right, PageGeometry.CardWidthMM);
    public int Rows => Fit(Paper.HeightMM - Edges.Top - Edges.Bottom, PageGeometry.CardHeightMM);
    public int CardsPerPage => Columns * Rows;

    private static int Fit(double room, double card)
        => room < card ? 0 : (int)Math.Floor((room + PageGeometry.MinGapMM) / (card + PageGeometry.MinGapMM) + 1e-9);

    /// The gaps the layout actually uses, per axis, in mm.
    public (double Row, double Column) ResolvedGapsMM()
    {
        var f = Edges;
        double Axis(double room, int count, double card)
        {
            if (count < 2) return GapMM;
            var max = (room - count * card) / (count - 1);
            return MaximizeGap ? Math.Max(PageGeometry.MinGapMM, max) : Math.Max(PageGeometry.MinGapMM, Math.Min(GapMM, max));
        }
        return (Axis(Paper.HeightMM - f.Top - f.Bottom, Rows, PageGeometry.CardHeightMM),
                Axis(Paper.WidthMM - f.Left - f.Right, Columns, PageGeometry.CardWidthMM));
    }

    public double GridWidthMM => Columns * PageGeometry.CardWidthMM + Math.Max(0, Columns - 1) * ResolvedGapsMM().Column;
    public double GridHeightMM => Rows * PageGeometry.CardHeightMM + Math.Max(0, Rows - 1) * ResolvedGapsMM().Row;

    /// Top row's card edge in mm from the top of the sheet.
    public double ResolvedTopMarginMM()
    {
        var gridH = GridHeightMM;
        var top = (Paper.HeightMM - gridH) / 2 - ShiftUpMM;
        if (Floors is { } f) top = Math.Min(Math.Max(top, f.Top), Paper.HeightMM - gridH - f.Bottom);
        return top;
    }

    /// Left column's card edge in mm from the left of the sheet.
    public double ResolvedLeftMarginMM()
    {
        var gridW = GridWidthMM;
        var left = (Paper.WidthMM - gridW) / 2;
        if (Floors is { } f) left = Math.Min(Math.Max(left, f.Left), Paper.WidthMM - gridW - f.Right);
        return left;
    }

    /// The true size rect for a slot in points, measured from the TOP LEFT.
    public (double X, double Top, double W, double H) SlotRectFromTop(int slot)
    {
        var col = slot % Columns;
        var row = slot / Columns;
        var gaps = ResolvedGapsMM();
        var x = ResolvedLeftMarginMM() * PageGeometry.PointsPerMM + col * (PageGeometry.CardWidthPoints + gaps.Column * PageGeometry.PointsPerMM);
        var top = ResolvedTopMarginMM() * PageGeometry.PointsPerMM + row * (PageGeometry.CardHeightPoints + gaps.Row * PageGeometry.PointsPerMM);
        return (x, top, PageGeometry.CardWidthPoints, PageGeometry.CardHeightPoints);
    }
}

/// Identifies one face of one printing.
public readonly record struct FaceRef(string CardKey, int FaceIndex)
{
    public static FaceRef Of(string set, string collectorNumber, int faceIndex)
        => new($"{set.ToLowerInvariant()}|{collectorNumber}", faceIndex);
}

/// Which faces land in which slots, computed before any image work.
public sealed class LayoutPlan
{
    public List<List<FaceRef>> Pages { get; } = [];
    public Dictionary<int, Dictionary<int, FaceRef>> BackPlacements { get; } = [];
    public List<string> BackNames { get; } = [];
    public int TotalPlacements { get; private set; }
    public int PageCount => Pages.Count;
    /// Back to back plans: the 0-based page where the front/back pairs
    /// begin, or -1 when the plan has none.
    public int DuplexStartPage { get; private set; } = -1;
    public int DuplexSheets => DuplexStartPage < 0 ? 0 : (Pages.Count - DuplexStartPage) / 2;

    /// The slot behind a slot when the sheet flips on its long edge: same
    /// row, column mirrored. The grid is centered, so it lines up.
    public static int MirroredSlot(int slot, int columns)
        => slot / columns * columns + (columns - 1 - slot % columns);

    /// One sided cards fill the first pages; then every two sided copy
    /// gets a front page slot with its back on the next page, mirrored.
    public static LayoutPlan MakeBackToBack(List<FaceRef> singles, List<(string Name, FaceRef Front, FaceRef Back)> twoSided,
        int perPage, int columns)
    {
        var plan = new LayoutPlan();
        for (var i = 0; i < singles.Count; i += perPage)
            plan.Pages.Add(singles.Skip(i).Take(perPage).ToList());
        if (twoSided.Count > 0) plan.DuplexStartPage = plan.Pages.Count;
        for (var i = 0; i < twoSided.Count; i += perPage)
        {
            var chunk = twoSided.Skip(i).Take(perPage).ToList();
            plan.Pages.Add(chunk.Select(c => c.Front).ToList());
            plan.Pages.Add([]);
            var backs = new Dictionary<int, FaceRef>();
            for (var slot = 0; slot < chunk.Count; slot++) backs[MirroredSlot(slot, columns)] = chunk[slot].Back;
            plan.BackPlacements[plan.Pages.Count - 1] = backs;
        }
        if (plan.Pages.Count == 0) plan.Pages.Add([]);
        plan.BackNames.AddRange(twoSided.Select(c => c.Name).Distinct());
        plan.TotalPlacements = singles.Count + twoSided.Count * 2;
        return plan;
    }

    /// Backs fill the highest free slot of the final page; when it is full
    /// a fresh page starts with its first back in slot 0 (later backs then
    /// fill that page from the last slot down, as the original loop behaves).
    public static LayoutPlan Make(List<FaceRef> fronts, List<(string Name, FaceRef Face)> backs, int perPage)
    {
        var plan = new LayoutPlan();
        for (var i = 0; i < fronts.Count; i += perPage)
            plan.Pages.Add(fronts.Skip(i).Take(perPage).ToList());
        if (plan.Pages.Count == 0) plan.Pages.Add([]);

        foreach (var back in backs)
        {
            var pageIndex = plan.Pages.Count - 1;
            var frontCount = plan.Pages[pageIndex].Count;
            var placed = false;
            for (var slot = perPage - 1; slot >= frontCount; slot--)
            {
                if (!plan.BackPlacements.TryGetValue(pageIndex, out var map))
                    plan.BackPlacements[pageIndex] = map = [];
                if (!map.ContainsKey(slot)) { map[slot] = back.Face; placed = true; break; }
            }
            if (!placed)
            {
                plan.Pages.Add([]);
                plan.BackPlacements[plan.Pages.Count - 1] = new() { [0] = back.Face };
            }
            plan.BackNames.Add(back.Name);
        }
        plan.TotalPlacements = fronts.Count + backs.Count;
        return plan;
    }
}
