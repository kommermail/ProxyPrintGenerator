// ProxyMarks.cs
// Marks that say "this is a proxy", drawn onto every card face:
//   - a PROXY label over the art, in a chosen color, spot and font (the
//     fonts the app ships, all free to print with),
//   - a colored band around the card's edge (3 mm recolors the black
//     border; wider eats into the frame),
//   - the app's logo, the sleeping fox under two trees in a ring, as
//     outlines in a chosen color, in a chosen spot.
// The label and logo get a thin halo (white, or dark for light colors) so
// they read on busy art. The band is filled straight into the pixels; the
// label and logo are drawn once per build as a small patch and blended
// onto each face, so even 1800 dpi faces need no full size overlay.

using System.Collections.Concurrent;
using System.Globalization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ProxyPrintGenerator.Engine;

public enum ProxyMarkKind { None, Label, Border, Logo }

public enum MarkPosition { TopLeft, Top, TopRight, MiddleLeft, Middle, MiddleRight, BottomLeft, Bottom, BottomRight }

/// The PROXY label's lettering: only the fonts the app ships, all free to
/// print with (Cinzel, Cinzel Decorative and IM FELL English under the SIL
/// Open Font License; Faerie Moot is freeware).
public enum MarkFont { Cinzel, CinzelDecorative, FellEnglish, FellEnglishItalic, FaerieMoot }

/// One proxy mark. Color is as chosen, before ink calibration.
public sealed record ProxyMark(ProxyMarkKind Kind, RgbColor Color, MarkPosition Position, double BorderMM, MarkFont Font = MarkFont.Cinzel)
{
    public static readonly RgbColor DefaultColor = new(196, 28, 44);
    public static readonly ProxyMark None = new(ProxyMarkKind.None, DefaultColor, MarkPosition.TopLeft, 3.0);
}

/// Where and how a mark is drawn, in millimeters on a 63 x 88 mm card.
public static class ProxyMarkArt
{
    public const double CardW = 63, CardH = 88;
    public const double LogoMM = 15;
    public const double LabelEmMM = 7;
    /// The art window of a modern frame, which the spots sit inside.
    private static readonly Rect Art = new(5.0, 10.5, 53.0, 38.0);
    private const double Inset = 2.5;

    /// The sleeping fox between two trees, inside a ring: stroke paths in a
    /// 240 x 240 box, drawn from the app icon.
    public static readonly Geometry Logo = Freeze(Geometry.Parse(LogoPath));

    /// Every label font's letters are scaled to this height, and narrowed
    /// to fit the art if a font runs wide.
    private const double LabelHeightMM = 5.0, LabelMaxWidthMM = 46.0;

    public static FontFamily FamilyFor(MarkFont font) => new(new Uri("pack://application:,,,/"), "./Assets/Fonts/#" + font switch
    {
        MarkFont.CinzelDecorative => "Cinzel Decorative",
        MarkFont.FellEnglish or MarkFont.FellEnglishItalic => "IM FELL English",
        MarkFont.FaerieMoot => "Faerie Moot Ornate",
        _ => "Cinzel",
    });

    public static FontWeight WeightFor(MarkFont font) => font is MarkFont.Cinzel or MarkFont.CinzelDecorative ? FontWeights.Bold : FontWeights.Normal;
    public static FontStyle StyleFor(MarkFont font) => font == MarkFont.FellEnglishItalic ? FontStyles.Italic : FontStyles.Normal;

    private static T Freeze<T>(T f) where T : Freezable { f.Freeze(); return f; }

    public static Color ToColor(RgbColor c) => Color.FromRgb((byte)c.R, (byte)c.G, (byte)c.B);

    /// A light mark gets a dark halo; everything else a white one.
    private static Color Halo(RgbColor c)
        => 0.299 * c.R + 0.587 * c.G + 0.114 * c.B > 170 ? Color.FromArgb(150, 20, 20, 20) : Color.FromArgb(215, 255, 255, 255);

    private static Geometry LabelGeometry(MarkFont font)
    {
        var face = new Typeface(FamilyFor(font), StyleFor(font), WeightFor(font), FontStretches.Normal);
        FormattedText Text(double em) => new("PROXY", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, face, em, Brushes.Black, 1.0);
        // Size every font by its capital height, so swashes and tails don't
        // shrink the letters; then narrow it if it runs wider than the art.
        var em = face.TryGetGlyphTypeface(out var glyphs) && glyphs.CapsHeight > 0.3 ? LabelHeightMM / glyphs.CapsHeight : LabelEmMM;
        var width = Text(em).BuildGeometry(new Point(0, 0)).Bounds.Width;
        if (width > LabelMaxWidthMM) em *= LabelMaxWidthMM / width;
        var sized = Text(em);
        var b = sized.BuildGeometry(new Point(0, 0)).Bounds;
        return Freeze(sized.BuildGeometry(new Point(-b.X, -b.Y)));
    }

    private static readonly ConcurrentDictionary<MarkFont, Geometry> Labels = new();
    private static Geometry LabelFor(MarkFont font) => Labels.GetOrAdd(font, LabelGeometry);

    /// The mark's own size in mm, before its halo.
    private static Size SizeOf(ProxyMark mark) => mark.Kind switch
    {
        ProxyMarkKind.Label => LabelFor(mark.Font).Bounds.Size,
        ProxyMarkKind.Logo => new Size(LogoMM, LogoMM),
        _ => new Size(0, 0),
    };

    /// The mark's box on the card, in mm.
    public static Rect Place(ProxyMark mark)
    {
        var s = SizeOf(mark);
        var col = (int)mark.Position % 3;
        var row = (int)mark.Position / 3;
        var x = col switch { 0 => Art.Left + Inset, 1 => Art.Left + (Art.Width - s.Width) / 2, _ => Art.Right - Inset - s.Width };
        var y = row switch { 0 => Art.Top + Inset, 1 => Art.Top + (Art.Height - s.Height) / 2, _ => Art.Bottom - Inset - s.Height };
        return new Rect(x, y, s.Width, s.Height);
    }

    /// Draws the mark in card millimeters (the caller scales to pixels).
    public static void Draw(DrawingContext dc, ProxyMark mark)
    {
        var ink = new SolidColorBrush(ToColor(mark.Color));
        var halo = new SolidColorBrush(Halo(mark.Color));
        switch (mark.Kind)
        {
            case ProxyMarkKind.Border:
            {
                var band = Math.Clamp(mark.BorderMM, 0.5, 12);
                var ring = new CombinedGeometry(GeometryCombineMode.Exclude,
                    new RectangleGeometry(new Rect(0, 0, CardW, CardH)),
                    new RectangleGeometry(new Rect(band, band, CardW - 2 * band, CardH - 2 * band), 1, 1));
                dc.DrawGeometry(ink, null, ring);
                break;
            }
            case ProxyMarkKind.Label:
            {
                var at = Place(mark);
                var letters = LabelFor(mark.Font);
                dc.PushTransform(new TranslateTransform(at.X, at.Y));
                dc.DrawGeometry(null, new Pen(halo, 1.0) { LineJoin = PenLineJoin.Round }, letters);
                dc.DrawGeometry(ink, null, letters);
                dc.Pop();
                break;
            }
            case ProxyMarkKind.Logo:
            {
                var at = Place(mark);
                var k = LogoMM / 240.0;
                dc.PushTransform(new TranslateTransform(at.X, at.Y));
                dc.PushTransform(new ScaleTransform(k, k));
                Pen P(Brush b, double w) => new(b, w) { LineJoin = PenLineJoin.Round, StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
                dc.DrawGeometry(null, P(halo, 13), Logo);
                dc.DrawGeometry(null, P(ink, 6), Logo);
                dc.Pop();
                dc.Pop();
                break;
            }
        }
    }

    // The fox and trees, generated from the icon (see the logo samples).
    private const string LogoPath = 
        "M 44.8,208.8 C 45.6,184.8 47.2,159.2 51.2,127.2 M 50.4,133.6 C 57.6,117.6 67.2,104.8 80,95.2 M 51.2,127.2 C 51.2,114.4 52.8,101.6 56,92 "
        + "M 45.6,194.4 C 37.6,191.2 31.2,197.6 35.2,203.2 C 38.4,208 45.6,204.8 43.2,199.2 M 45.6,186.4 C 54.4,184 60,190.4 56,195.2 "
        + "C 52.8,198.4 48,195.2 50.4,191.2 M 56.6,120 C 48,125.5 25.6,124.7 20.4,113.6 C 4.9,109.2 9.8,92.5 25.2,97.1 C 11.1,89.4 19.5,74.2 33.5,82.1 "
        + "C 21.4,71.5 32.9,58.5 44.9,69.2 C 35.3,56.3 49.4,46 58.7,59.1 C 52.3,44.4 68.2,37.5 74.5,52.3 C 71.4,36.5 88.4,33.2 91.4,49 "
        + "C 91.7,33 109.1,33.5 108.5,49.6 C 115,57.3 109.6,79.1 103.4,86 C 100.8,93 90.8,93.5 87.5,86.8 C 87.7,94.2 78.7,98.5 73.1,93.5 "
        + "C 76.1,100.3 69.3,107.6 62.3,105.2 C 67.6,110.3 64,119.7 56.6,120 Z M 195.2,208.8 C 194.4,184.8 192.8,159.2 188.8,127.2 "
        + "M 189.6,133.6 C 182.4,117.6 172.8,104.8 160,95.2 M 188.8,127.2 C 188.8,114.4 187.2,101.6 184,92 M 194.4,194.4 "
        + "C 202.4,191.2 208.8,197.6 204.8,203.2 C 201.6,208 194.4,204.8 196.8,199.2 M 194.4,186.4 C 185.6,184 180,190.4 184,195.2 "
        + "C 187.2,198.4 192,195.2 189.6,191.2 M 183.4,120 C 192,125.5 214.4,124.7 219.6,113.6 C 235.1,109.2 230.2,92.5 214.8,97.1 "
        + "C 228.9,89.4 220.5,74.2 206.5,82.1 C 218.6,71.5 207.1,58.5 195.1,69.2 C 204.7,56.3 190.6,46 181.3,59.1 C 187.7,44.4 171.8,37.5 165.5,52.3 "
        + "C 168.6,36.5 151.6,33.2 148.6,49 C 148.3,33 130.9,33.5 131.5,49.6 C 125,57.3 130.4,79.1 136.6,86 C 139.2,93 149.2,93.5 152.5,86.8 "
        + "C 152.3,94.2 161.3,98.5 166.9,93.5 C 163.9,100.3 170.7,107.6 177.7,105.2 C 172.4,110.3 176,119.7 183.4,120 Z M 118.1,143 "
        + "C 142.3,127.5 180.4,137.8 182.1,172.4 C 183.8,196.6 164.8,210.4 137.2,210.4 C 109.5,210.4 80.1,208.7 66.3,196.6 "
        + "C 60.3,190.5 62.8,183.6 70.6,183.6 C 92.2,187.1 119.9,189.7 140.6,185.3 C 156.2,181.9 164.8,173.2 164.8,162 M 81.9,186.2 "
        + "C 76.7,192.3 76.7,199.2 82.7,205.2 M 100.9,148.2 L 107.8,122.3 L 119.9,143.9 M 82.7,156.8 L 73.2,132.6 L 93.1,149.1 "
        + "M 106,134.4 L 110.4,143.9 M 77.5,143 L 85.3,150.8 M 93.1,149.1 C 95.7,147.3 98.3,147.3 100.9,148.2 M 82.7,156.8 "
        + "C 76.7,164.6 68,170.7 59.4,175.8 C 64.6,181 80.1,182.8 95.7,180.2 M 119.9,143.9 C 125.1,156 121.6,170.7 107.8,178.4 "
        + "C 103.5,180.2 99.1,181 95.7,180.2 M 85.3,164.6 C 88.8,168.1 94,168.1 97.4,164.6 M 120,6 A 114,114 0 1 1 119.9,6 "
        + "Z ";
}

/// Puts the mark onto prepared faces during a build.
public static class ProxyMarker
{
    private sealed record Patch(int X, int Y, int W, int H, byte[] Bgra);
    private static readonly ConcurrentDictionary<(ProxyMark, int, int), Patch> Patches = new();

    /// The face with the mark on it. The face's pixels are changed in
    /// place (each prepared face is a fresh copy); a band also becomes the
    /// face's border color, so the bleed around the card matches it.
    public static PreparedFace Apply(PreparedFace face, ProxyMark mark, InkCalibration calibration)
    {
        if (mark.Kind == ProxyMarkKind.None) return face;
        var img = face.Image;
        var ink = calibration.Boosted(mark.Color);
        if (mark.Kind == ProxyMarkKind.Border)
        {
            FillBand(img, mark.BorderMM, ink);
            return new PreparedFace(img, mark.Color);
        }
        var patch = Patches.GetOrAdd((mark with { Color = ink }, img.Width, img.Height), key => Render(key.Item1, key.Item2, key.Item3));
        Blend(img, patch);
        return face;
    }

    /// The outer band in the mark's color, its inner corners rounded 1 mm.
    private static void FillBand(RgbImage img, double bandMM, RgbColor c)
    {
        double sx = img.Width / ProxyMarkArt.CardW, sy = img.Height / ProxyMarkArt.CardH;
        var bx = (int)Math.Round(Math.Clamp(bandMM, 0.5, 12) * sx);
        var by = (int)Math.Round(Math.Clamp(bandMM, 0.5, 12) * sy);
        var r = 1.0 * sx;
        var p = img.Pixels;
        for (var y = 0; y < img.Height; y++)
        {
            var edgeRow = y < by || y >= img.Height - by;
            for (var x = 0; x < img.Width; x++)
            {
                var fill = edgeRow || x < bx || x >= img.Width - bx;
                if (!fill)
                {
                    // Inside the band: only the rounded inner corners fill.
                    var cx = x < bx + r ? bx + r : x > img.Width - bx - r ? img.Width - bx - r : x;
                    var cy = y < by + r ? by + r : y > img.Height - by - r ? img.Height - by - r : y;
                    if (cx == x || cy == y) continue;
                    var dx = x - cx; var dy = y - cy;
                    if (dx * dx + dy * dy <= r * r) continue;
                    fill = true;
                }
                if (!fill) continue;
                var o = (y * img.Width + x) * 3;
                p[o] = (byte)c.R; p[o + 1] = (byte)c.G; p[o + 2] = (byte)c.B;
            }
        }
    }

    private static void Blend(RgbImage img, Patch patch)
    {
        var p = img.Pixels;
        for (var y = 0; y < patch.H; y++)
        {
            var iy = patch.Y + y;
            if (iy < 0 || iy >= img.Height) continue;
            for (var x = 0; x < patch.W; x++)
            {
                var ix = patch.X + x;
                if (ix < 0 || ix >= img.Width) continue;
                var s = (y * patch.W + x) * 4;
                int a = patch.Bgra[s + 3];
                if (a == 0) continue;
                var o = (iy * img.Width + ix) * 3;
                var ia = 255 - a;
                // Premultiplied BGRA over RGB.
                p[o] = (byte)Math.Min(255, patch.Bgra[s + 2] + (p[o] * ia + 127) / 255);
                p[o + 1] = (byte)Math.Min(255, patch.Bgra[s + 1] + (p[o + 1] * ia + 127) / 255);
                p[o + 2] = (byte)Math.Min(255, patch.Bgra[s] + (p[o + 2] * ia + 127) / 255);
            }
        }
    }

    /// Draws the label or logo into a patch the size of its box (plus the
    /// halo), at the face's pixel scale. WPF draws on an STA thread of its own.
    private static Patch Render(ProxyMark mark, int faceW, int faceH)
    {
        Patch? result = null;
        Exception? error = null;
        var thread = new Thread(() =>
        {
            try
            {
                double sx = faceW / ProxyMarkArt.CardW, sy = faceH / ProxyMarkArt.CardH;
                var box = ProxyMarkArt.Place(mark);
                box.Inflate(1.2, 1.2);
                var x0 = (int)Math.Floor(box.X * sx); var y0 = (int)Math.Floor(box.Y * sy);
                var w = (int)Math.Ceiling(box.Right * sx) - x0; var h = (int)Math.Ceiling(box.Bottom * sy) - y0;
                var dv = new DrawingVisual();
                using (var dc = dv.RenderOpen())
                {
                    dc.PushTransform(new TranslateTransform(-x0, -y0));
                    dc.PushTransform(new ScaleTransform(sx, sy));
                    ProxyMarkArt.Draw(dc, mark);
                    dc.Pop(); dc.Pop();
                }
                var rtb = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
                rtb.Render(dv);
                var px = new byte[w * h * 4];
                rtb.CopyPixels(px, w * 4, 0);
                result = new Patch(x0, y0, w, h, px);
            }
            catch (Exception e) { error = e; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (error != null) throw new PpgException($"[PPG:PROXY-MARK] The proxy mark couldn't be drawn: {error.Message}");
        return result!;
    }
}
