// Layout.cs
// Page geometry and the page plan, ported from PDFBuilder.swift:
//   - Letter (or A4), 9 cards per page in a 3x3 grid, centered
//   - true card size 63x88 mm, 3 mm gaps measured art edge to art edge
//   - 1 mm buffer per card filled with the card's own border color
//   - blue dotted guide at true card size, following the 3 mm corners
//   - fronts in deck order; two sided backs go in the highest free slot
//     of the final page, or on a fresh page

namespace ProxyPrintGenerator.Engine;

public static class PageGeometry
{
    public const double PointsPerMM = 72.0 / 25.4;
    public const double CardWidthPoints = 63 * PointsPerMM;
    public const double CardHeightPoints = 88 * PointsPerMM;
    public const double CardCornerRadiusPoints = 3 * PointsPerMM;
    public const int GridColumns = 3;
    public const int GridRows = 3;
    public const int CardsPerPage = GridColumns * GridRows;
    public static readonly RgbColor GuideColor = new(13, 71, 255);
}

public enum PaperSize { Letter, A4 }

/// A printer's unprintable border, widened by a feed tolerance.
public enum SafeAreaProfile { None, CanonInkjet }

public sealed class PrintSettings
{
    public PaperSize Paper { get; set; } = PaperSize.Letter;
    public double GapMM { get; set; } = 3.0;
    public double BufferMM { get; set; } = 1.0;
    public double ShiftUpMM { get; set; }
    public SafeAreaProfile SafeArea { get; set; } = SafeAreaProfile.None;
    public bool MaximizeGap { get; set; }
    public bool ThickGuides { get; set; }
    public bool ShowGuides { get; set; } = true;
    public InkCalibration Calibration { get; set; } = InkCalibration.None;

    public double PageWidthPoints => Paper == PaperSize.Letter ? 612.0 : 595.28;
    public double PageHeightPoints => Paper == PaperSize.Letter ? 792.0 : 841.89;

    /// Canon MAXIFY Letter spec (top 3.0, bottom 5.0, left 6.4, right
    /// 6.3 mm unreachable) plus about 1.5 mm of feed tolerance.
    private (double Top, double Bottom, double Left, double Right)? Floors => SafeArea switch
    {
        SafeAreaProfile.CanonInkjet => (4.5, 6.5, 7.9, 7.8),
        _ => null,
    };

    /// The gaps the layout actually uses, per axis, in mm.
    public (double Row, double Column) ResolvedGapsMM()
    {
        var paperW = PageWidthPoints / PageGeometry.PointsPerMM;
        var paperH = PageHeightPoints / PageGeometry.PointsPerMM;
        var cardW = PageGeometry.CardWidthPoints / PageGeometry.PointsPerMM;
        var cardH = PageGeometry.CardHeightPoints / PageGeometry.PointsPerMM;
        var f = Floors ?? (2.0, 2.0, 2.0, 2.0);
        var maxRow = (paperH - f.Top - f.Bottom - PageGeometry.GridRows * cardH) / (PageGeometry.GridRows - 1);
        var maxColumn = (paperW - f.Left - f.Right - PageGeometry.GridColumns * cardW) / (PageGeometry.GridColumns - 1);
        if (MaximizeGap) return (Math.Max(0.5, maxRow), Math.Max(0.5, maxColumn));
        return (Math.Max(0.5, Math.Min(GapMM, maxRow)), Math.Max(0.5, Math.Min(GapMM, maxColumn)));
    }

    /// Top row's card edge in mm from the top of the sheet.
    public double ResolvedTopMarginMM()
    {
        var gap = ResolvedGapsMM().Row;
        var paperH = PageHeightPoints / PageGeometry.PointsPerMM;
        var gridH = PageGeometry.GridRows * (PageGeometry.CardHeightPoints / PageGeometry.PointsPerMM) + (PageGeometry.GridRows - 1) * gap;
        var top = (paperH - gridH) / 2 - ShiftUpMM;
        if (Floors is { } f) top = Math.Min(Math.Max(top, f.Top), paperH - gridH - f.Bottom);
        return top;
    }

    /// Left column's card edge in mm from the left of the sheet.
    public double ResolvedLeftMarginMM()
    {
        var gap = ResolvedGapsMM().Column;
        var paperW = PageWidthPoints / PageGeometry.PointsPerMM;
        var gridW = PageGeometry.GridColumns * (PageGeometry.CardWidthPoints / PageGeometry.PointsPerMM) + (PageGeometry.GridColumns - 1) * gap;
        var left = (paperW - gridW) / 2;
        if (Floors is { } f) left = Math.Min(Math.Max(left, f.Left), paperW - gridW - f.Right);
        return left;
    }

    /// The true size rect for a slot in points, measured from the TOP LEFT.
    public (double X, double Top, double W, double H) SlotRectFromTop(int slot)
    {
        var col = slot % PageGeometry.GridColumns;
        var row = slot / PageGeometry.GridColumns;
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

    /// Backs fill the highest free slot of the final page; when it is full
    /// a fresh page starts with its first back in slot 0 (later backs then
    /// fill that page from slot 8 down, as the original loop behaves).
    public static LayoutPlan Make(List<FaceRef> fronts, List<(string Name, FaceRef Face)> backs)
    {
        var plan = new LayoutPlan();
        for (var i = 0; i < fronts.Count; i += PageGeometry.CardsPerPage)
            plan.Pages.Add(fronts.Skip(i).Take(PageGeometry.CardsPerPage).ToList());
        if (plan.Pages.Count == 0) plan.Pages.Add([]);

        foreach (var back in backs)
        {
            var pageIndex = plan.Pages.Count - 1;
            var frontCount = plan.Pages[pageIndex].Count;
            var placed = false;
            for (var slot = PageGeometry.CardsPerPage - 1; slot >= frontCount; slot--)
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
