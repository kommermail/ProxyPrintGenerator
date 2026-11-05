// Visuals.cs
// The Printing Selector theme's drawn pieces, ported from Theme.swift:
// outlined Faerie Moot text, living glitter, the five land pips, the
// holographic wash plaque, spectacular section headers, the masthead,
// the leather backdrop with its stitched edge, and the panel scaffold.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace ProxyPrintGenerator.Controls;

public static class Theme
{
    public static readonly Color LeatherDeep = Color.FromRgb(0x1C, 0x12, 0x0A);
    public static readonly Color Leather = Color.FromRgb(0x33, 0x1F, 0x12);
    public static readonly Color LeatherLight = Color.FromRgb(0x52, 0x33, 0x1C);
    public static readonly Color Parchment = Color.FromRgb(0xED, 0xDE, 0xB5);
    public static readonly Color Ink = Color.FromRgb(0x26, 0x17, 0x0D);
    public static readonly Color Gold = Color.FromRgb(0xD4, 0x9E, 0x38);
    public static readonly Color Ivory = Color.FromRgb(0xF7, 0xF0, 0xD9);

    public static readonly FontFamily Kingdom = new(new Uri("pack://application:,,,/"), "./Assets/Fonts/#Faerie Moot Ornate");
    public static readonly FontFamily Plaque = new(new Uri("pack://application:,,,/"), "./Assets/Fonts/#Cinzel");
    public static readonly FontFamily Fell = new(new Uri("pack://application:,,,/"), "./Assets/Fonts/#IM FELL English");

    public static readonly Color[] FoilColors =
    [
        Color.FromRgb(255, 115, 140), Color.FromRgb(255, 191, 89), Color.FromRgb(242, 242, 115), Color.FromRgb(128, 242, 140),
        Color.FromRgb(102, 217, 255), Color.FromRgb(153, 140, 255), Color.FromRgb(255, 140, 242), Color.FromRgb(255, 115, 140),
    ];

    public static LinearGradientBrush FoilLinear(double angle = 0)
    {
        var b = new LinearGradientBrush { StartPoint = new Point(0, 0.5), EndPoint = new Point(1, 0.5) };
        for (var i = 0; i < FoilColors.Length; i++) b.GradientStops.Add(new GradientStop(FoilColors[i], i / (double)(FoilColors.Length - 1)));
        if (angle != 0) b.RelativeTransform = new RotateTransform(angle, 0.5, 0.5);
        return b;
    }

    public static ImageSource Image(string name)
    {
        var bmp = new BitmapImage();
        bmp.BeginInit();
        bmp.UriSource = new Uri($"pack://application:,,,/Assets/Images/{name}");
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.EndInit();
        bmp.Freeze();
        return bmp;
    }

    /// The four pointed sparkle, in a 24 x 24 box.
    public static readonly Geometry Sparkle = Freeze(Geometry.Parse(
        "M12,0 C12.9,7.5 16.5,11.1 24,12 C16.5,12.9 12.9,16.5 12,24 C11.1,16.5 7.5,12.9 0,12 C7.5,11.1 11.1,7.5 12,0 Z"));

    public static T Freeze<T>(T f) where T : Freezable { f.Freeze(); return f; }

    public static SolidColorBrush Brush(Color c, double opacity = 1) => Freeze(new SolidColorBrush(c) { Opacity = opacity });
}

/// A tiny deterministic random source (SplitMix64), so glitter always
/// lands in the same places.
public struct SplitMix(ulong seed)
{
    private ulong _state = seed;
    public ulong Next()
    {
        _state += 0x9E3779B97F4A7C15;
        var z = _state;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }
    public double NextDouble(double lo, double hi) => lo + (Next() >> 11) * (1.0 / (1UL << 53)) * (hi - lo);
    public int NextInt(int n) => (int)(Next() % (ulong)n);
}

/// Text drawn as geometry: a fill (gold or ink) over a thick outline
/// (leather or ivory), with a hard one pixel drop shadow. Covers both
/// KingdomText and PlaqueTitleText from the Swift app.
public class OutlinedText : FrameworkElement
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(OutlinedText),
        new FrameworkPropertyMetadata("", FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty SizeProperty = DependencyProperty.Register(nameof(Size), typeof(double), typeof(OutlinedText),
        new FrameworkPropertyMetadata(20.0, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty PlaqueStyleProperty = DependencyProperty.Register(nameof(PlaqueStyle), typeof(bool), typeof(OutlinedText),
        new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty WrapProperty = DependencyProperty.Register(nameof(Wrap), typeof(bool), typeof(OutlinedText),
        new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty TextAlignmentProperty = DependencyProperty.Register(nameof(TextAlignment), typeof(TextAlignment), typeof(OutlinedText),
        new FrameworkPropertyMetadata(TextAlignment.Left, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

    public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public double Size { get => (double)GetValue(SizeProperty); set => SetValue(SizeProperty, value); }
    public static readonly DependencyProperty BlackOutlineProperty = DependencyProperty.Register(nameof(BlackOutline), typeof(bool), typeof(OutlinedText),
        new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty ReadableProperty = DependencyProperty.Register(nameof(Readable), typeof(bool), typeof(OutlinedText),
        new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));

    /// Gold letters with a solid black outline, for text that has to stand
    /// out over busy art (the two sided card notices).
    public bool BlackOutline { get => (bool)GetValue(BlackOutlineProperty); set => SetValue(BlackOutlineProperty, value); }
    /// Bold Cinzel instead of the ornate Faerie Moot, for notices that must
    /// be read at a glance.
    public bool Readable { get => (bool)GetValue(ReadableProperty); set => SetValue(ReadableProperty, value); }
    /// Ink letters with an ivory outline (plaque titles) instead of gold
    /// letters with a leather outline.
    public bool PlaqueStyle { get => (bool)GetValue(PlaqueStyleProperty); set => SetValue(PlaqueStyleProperty, value); }
    public bool Wrap { get => (bool)GetValue(WrapProperty); set => SetValue(WrapProperty, value); }
    public TextAlignment TextAlignment { get => (TextAlignment)GetValue(TextAlignmentProperty); set => SetValue(TextAlignmentProperty, value); }

    private static readonly Typeface KingdomFace = new(Theme.Kingdom, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
    private static readonly Typeface ReadableFace = new(Theme.Plaque, FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
    private Typeface Face => Readable ? ReadableFace : KingdomFace;

    private double Outline => PlaqueStyle ? Math.Max(0.9, Size * 0.04) * 2 : (Size * 0.06 + 0.8) * 2;
    private double Pad => Outline / 2 + 1.5;

    private FormattedText Format(double size, double maxWidth)
    {
        var ft = new FormattedText(Text ?? "", CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, Face, size,
            Brushes.Black, 1.25) { TextAlignment = TextAlignment };
        if (maxWidth is > 0 and < double.PositiveInfinity) ft.MaxTextWidth = maxWidth;
        if (!Wrap) ft.MaxLineCount = 1;
        return ft;
    }

    private double _fitSize;

    protected override Size MeasureOverride(Size available)
    {
        var pad = Pad;
        var avail = available.Width - 2 * pad;
        _fitSize = Size;
        FormattedText ft;
        if (Wrap)
            ft = Format(Size, double.IsInfinity(available.Width) ? 0 : Math.Max(10, avail));
        else
        {
            ft = Format(Size, 0);
            // Shrink to fit (down to half size) instead of clipping.
            if (!double.IsInfinity(available.Width) && ft.WidthIncludingTrailingWhitespace > avail && avail > 0)
            {
                _fitSize = Math.Max(Size * 0.5, Size * avail / ft.WidthIncludingTrailingWhitespace);
                ft = Format(_fitSize, 0);
            }
        }
        // Rounded up with a pixel to spare: layout rounding can shave a
        // fraction off, and the line would then wrap at render time.
        var want = Math.Ceiling(ft.WidthIncludingTrailingWhitespace + 2 * pad) + 1;
        return new Size(Math.Min(want, double.IsInfinity(available.Width) ? double.MaxValue : available.Width),
            Math.Ceiling(ft.Height + 2 * pad));
    }

    protected override void OnRender(DrawingContext dc)
    {
        if (string.IsNullOrEmpty(Text)) return;
        var pad = Pad;
        var width = Math.Max(1, RenderSize.Width - 2 * pad);
        var ft = Format(_fitSize > 0 ? _fitSize : Size, (Wrap || TextAlignment != TextAlignment.Left) ? width : 0);
        var geo = ft.BuildGeometry(new Point(pad, pad));
        var lineH = new FormattedText("Ag", CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, Face,
            _fitSize > 0 ? _fitSize : Size, Brushes.Black, 1.25).Height;

        Brush fill, stroke;
        if (PlaqueStyle)
        {
            fill = Theme.Brush(Theme.Ink);
            stroke = Theme.Brush(Theme.Ivory);
        }
        else
        {
            fill = LineGradient(pad, lineH, Color.FromRgb(0xF6, 0xE0, 0xA4), Color.FromRgb(0xD8, 0xB4, 0x6C), Color.FromRgb(0xB2, 0x8A, 0x44));
            stroke = BlackOutline ? Brushes.Black : LineGradient(pad, lineH, Theme.LeatherLight, Theme.Leather, Theme.LeatherDeep);
        }
        var outline = Outline;
        var shadowPen = new Pen(Theme.Brush(Colors.Black, 0.35), outline) { LineJoin = PenLineJoin.Round };
        dc.PushTransform(new TranslateTransform(0, 1));
        dc.DrawGeometry(Theme.Brush(Colors.Black, 0.35), shadowPen, geo);
        dc.Pop();
        dc.DrawGeometry(null, new Pen(stroke, outline) { LineJoin = PenLineJoin.Round }, geo);
        // A whisper of stroke in the fill color fattens the thin face,
        // standing in for the Swift version's five fold strike.
        dc.DrawGeometry(fill, PlaqueStyle ? null : new Pen(fill, Size * 0.03 + 0.4) { LineJoin = PenLineJoin.Round }, geo);
    }

    private static LinearGradientBrush LineGradient(double top, double lineH, Color a, Color b, Color c)
    {
        var g = new LinearGradientBrush
        {
            MappingMode = BrushMappingMode.Absolute,
            StartPoint = new Point(0, top),
            EndPoint = new Point(0, top + lineH),
            SpreadMethod = GradientSpreadMethod.Repeat,
        };
        g.GradientStops.Add(new GradientStop(a, 0.0));
        g.GradientStops.Add(new GradientStop(a, 0.22));
        g.GradientStops.Add(new GradientStop(b, 0.5));
        g.GradientStops.Add(new GradientStop(c, 0.8));
        g.GradientStops.Add(new GradientStop(c, 1.0));
        g.Freeze();
        return g;
    }
}

/// Living glitter: neon sparkles strewn about, each blinking on its own
/// rhythm. One shared 30 fps clock drives every overlay.
public class GlitterOverlay : FrameworkElement
{
    private static readonly DispatcherTimer Clock = new(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(33) };
    private static event Action? Tick;
    static GlitterOverlay() { Clock.Tick += (_, _) => Tick?.Invoke(); Clock.Start(); }

    public static readonly DependencyProperty SeedProperty = DependencyProperty.Register(nameof(Seed), typeof(int), typeof(GlitterOverlay),
        new FrameworkPropertyMetadata(7, (d, _) => ((GlitterOverlay)d).Scatter()));
    public int Seed { get => (int)GetValue(SeedProperty); set => SetValue(SeedProperty, value); }

    private record struct Speck(double X, double Y, double Size, Brush Color, double Period, double Phase);
    private Speck[] _specks = [];
    private static readonly Color[] Neon =
    [
        Color.FromRgb(77, 242, 255), Color.FromRgb(255, 89, 217), Color.FromRgb(140, 255, 89),
        Color.FromRgb(255, 230, 64), Color.FromRgb(179, 140, 255), Color.FromRgb(255, 140, 77),
    ];

    public GlitterOverlay()
    {
        IsHitTestVisible = false;
        Scatter();
        Loaded += (_, _) => Tick += OnTick;
        Unloaded += (_, _) => Tick -= OnTick;
    }

    private void OnTick() { if (IsVisible) InvalidateVisual(); }

    private void Scatter()
    {
        var rng = new SplitMix(unchecked((ulong)(long)Seed));
        _specks = Enumerable.Range(0, 14).Select(_ => new Speck(rng.NextDouble(0.05, 0.95), rng.NextDouble(0.12, 0.88),
            rng.NextDouble(4, 8), Theme.Brush(Neon[rng.NextInt(Neon.Length)]), rng.NextDouble(0.8, 2.1), rng.NextDouble(0, 1))).ToArray();
    }

    protected override void OnRender(DrawingContext dc)
    {
        var t = Environment.TickCount64 / 1000.0;
        foreach (var s in _specks)
        {
            var cycle = (t / s.Period + s.Phase) % 1.0;
            var glow = Math.Max(0, 1 - Math.Abs(cycle - 0.5) * 5);
            if (glow <= 0.01) continue;
            var size = s.Size * 1.3;
            dc.PushOpacity(glow * 0.95);
            dc.PushTransform(new TranslateTransform(s.X * ActualWidth - size / 2, s.Y * ActualHeight - size / 2));
            dc.PushTransform(new ScaleTransform(size / 24, size / 24));
            dc.DrawGeometry(s.Color, null, Theme.Sparkle);
            dc.Pop(); dc.Pop(); dc.Pop();
        }
    }
}

/// The five land symbols: sun, water, moon, fire and tree in tinted
/// circles with gold rims.
public class ManaPipRow : FrameworkElement
{
    public static readonly DependencyProperty PipSizeProperty = DependencyProperty.Register(nameof(PipSize), typeof(double), typeof(ManaPipRow),
        new FrameworkPropertyMetadata(18.0, FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));
    public static readonly DependencyProperty SubsetProperty = DependencyProperty.Register(nameof(Subset), typeof(string), typeof(ManaPipRow),
        new FrameworkPropertyMetadata("01234", FrameworkPropertyMetadataOptions.AffectsMeasure | FrameworkPropertyMetadataOptions.AffectsRender));
    public double PipSize { get => (double)GetValue(PipSizeProperty); set => SetValue(PipSizeProperty, value); }
    /// Which pips show, as digits into the five ("012" = sun, water, moon).
    public string Subset { get => (string)GetValue(SubsetProperty); set => SetValue(SubsetProperty, value); }

    private static readonly (Color Fill, Color Glyph, Geometry Shape)[] Pips =
    [
        (Color.FromRgb(245, 230, 184), Color.FromRgb(140, 107, 26), Theme.Freeze(Geometry.Parse(
            "M12,7 A5,5 0 1 1 11.99,7 Z M11,1.5 H13 V5 H11 Z M11,19 H13 V22.5 H11 Z M1.5,11 H5 V13 H1.5 Z M19,11 H22.5 V13 H19 Z " +
            "M4.2,5.6 L5.6,4.2 L8.1,6.7 L6.7,8.1 Z M15.9,17.3 L17.3,15.9 L19.8,18.4 L18.4,19.8 Z M4.2,18.4 L6.7,15.9 L8.1,17.3 L5.6,19.8 Z M15.9,6.7 L18.4,4.2 L19.8,5.6 L17.3,8.1 Z"))),
        (Color.FromRgb(64, 115, 217), Colors.White, Theme.Freeze(Geometry.Parse("M12,2.5 C12,2.5 5.5,10.5 5.5,14.8 A6.5,6.5 0 0 0 18.5,14.8 C18.5,10.5 12,2.5 12,2.5 Z"))),
        (Color.FromRgb(41, 36, 51), Color.FromRgb(217, 209, 191), Theme.Freeze(Geometry.Parse("M14.5,3 A9,9 0 1 0 21,15.5 A7.2,7.2 0 1 1 14.5,3 Z"))),
        (Color.FromRgb(217, 77, 46), Color.FromRgb(255, 217, 140), Theme.Freeze(Geometry.Parse(
            "M12,2 C13.2,6.5 18,8.6 18,14.3 A6,6 0 0 1 6,14.3 C6,11.2 8,9.6 9.2,7.4 C9.8,9.6 10.8,10.8 12,11 C12.6,8.4 11.4,5 12,2 Z"))),
        (Color.FromRgb(64, 140, 77), Colors.White, Theme.Freeze(Geometry.Parse("M12,2 L18.8,10.6 H15.6 L20,16.4 H13.3 V22 H10.7 V16.4 H4 L8.4,10.6 H5.2 Z"))),
    ];

    private int[] Indices => (Subset ?? "01234").Where(char.IsDigit).Select(c => c - '0').Where(i => i < 5).ToArray();

    protected override Size MeasureOverride(Size availableSize)
    {
        var n = Indices.Length;
        return new Size(n * PipSize + Math.Max(0, n - 1) * 7 + 2, PipSize + 2);
    }

    protected override void OnRender(DrawingContext dc)
    {
        var x = 1.0;
        var r = PipSize / 2;
        var rim = new Pen(Theme.Brush(Theme.Gold, 0.75), 1);
        foreach (var i in Indices)
        {
            var (fill, glyph, shape) = Pips[i];
            dc.DrawEllipse(Theme.Brush(fill), rim, new Point(x + r, 1 + r), r - 0.5, r - 0.5);
            var g = PipSize * 0.62;
            dc.PushTransform(new TranslateTransform(x + (PipSize - g) / 2, 1 + (PipSize - g) / 2));
            dc.PushTransform(new ScaleTransform(g / 24, g / 24));
            dc.DrawGeometry(Theme.Brush(glyph), null, shape);
            dc.Pop(); dc.Pop();
            x += PipSize + 7;
        }
    }
}

/// The section plaque: carved gold under an oil slick rainbow, shaped
/// like a coin with capsule ends, a raised metallic rim and an inner
/// bevel line, gloss pooled across the top.
public class WashPlaque : Grid
{
    private static readonly ImageSource Wash = Theme.Image("plaque-wash.jpg");

    public WashPlaque() : this(999) { }

    /// A corner radius below 999 makes a rounded panel instead of a capsule,
    /// for plaques that hold several lines.
    public WashPlaque(double radius)
    {
        IsHitTestVisible = true;
        var r = new CornerRadius(radius);
        Children.Add(new Border { CornerRadius = r, Background = Theme.FoilLinear() });
        Children.Add(new Border { CornerRadius = r, Background = new ImageBrush(Wash) { Stretch = Stretch.UniformToFill } });
        var gloss = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 0.5) };
        gloss.GradientStops.Add(new GradientStop(Color.FromArgb(77, 255, 255, 255), 0));
        gloss.GradientStops.Add(new GradientStop(Color.FromArgb(13, 255, 255, 255), 0.6));
        gloss.GradientStops.Add(new GradientStop(Colors.Transparent, 1));
        Children.Add(new Border { CornerRadius = r, Background = gloss });
        var rim = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1) };
        rim.GradientStops.Add(new GradientStop(Color.FromRgb(250, 222, 128), 0));
        rim.GradientStops.Add(new GradientStop(Theme.Gold, 0.5));
        rim.GradientStops.Add(new GradientStop(Color.FromRgb(140, 97, 31), 1));
        Children.Add(new Border { CornerRadius = r, BorderBrush = rim, BorderThickness = new Thickness(5) });
        Children.Add(new Border { CornerRadius = r, BorderBrush = Theme.Brush(Colors.White, 0.35), BorderThickness = new Thickness(1), Margin = new Thickness(5) });
    }
}

/// A section heading gone spectacular: big Faerie Moot on the wash
/// plaque, glitter over it, the five land symbols beneath (or split
/// across the two sides, for a shorter heading).
public class SpectacularHeader : ContentControl
{
    public static readonly DependencyProperty TitleProperty = DependencyProperty.Register(nameof(Title), typeof(string), typeof(SpectacularHeader),
        new PropertyMetadata("", (d, _) => ((SpectacularHeader)d).Build()));
    public static readonly DependencyProperty PipsOnSidesProperty = DependencyProperty.Register(nameof(PipsOnSides), typeof(bool), typeof(SpectacularHeader),
        new PropertyMetadata(false, (d, _) => ((SpectacularHeader)d).Build()));
    public string Title { get => (string)GetValue(TitleProperty); set => SetValue(TitleProperty, value); }
    public bool PipsOnSides { get => (bool)GetValue(PipsOnSidesProperty); set => SetValue(PipsOnSidesProperty, value); }

    public SpectacularHeader()
    {
        Focusable = false;
        HorizontalAlignment = HorizontalAlignment.Center;
        Margin = new Thickness(0, 14, 0, 8);
        Build();
    }

    private void Build()
    {
        var seed = (Title ?? "").Aggregate(7, (acc, ch) => unchecked(acc * 31 + ch));
        var text = new OutlinedText { Text = (Title ?? "").ToUpperInvariant(), Size = PipsOnSides ? 34 : 38, PlaqueStyle = true, HorizontalAlignment = HorizontalAlignment.Center };
        FrameworkElement inner;
        if (PipsOnSides)
        {
            // Columns, so a long title shrinks to fit between the pips.
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var left = new ManaPipRow { PipSize = 19, Subset = "012", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
            var right = new ManaPipRow { PipSize = 19, Subset = "34", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
            Grid.SetColumn(text, 1); Grid.SetColumn(right, 2);
            row.Children.Add(left); row.Children.Add(text); row.Children.Add(right);
            inner = row;
        }
        else
        {
            var col = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
            col.Children.Add(text);
            col.Children.Add(new ManaPipRow { PipSize = 19, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 3, 0, 0) });
            inner = col;
        }
        inner.Margin = new Thickness(24, PipsOnSides ? 8 : 10, 24, PipsOnSides ? 8 : 10);
        var grid = new Grid { Width = 500 };
        grid.Children.Add(new WashPlaque());
        grid.Children.Add(inner);
        grid.Children.Add(new GlitterOverlay { Seed = seed });
        Content = grid;
    }
}

/// A small caption between two sparkles, for quiet helper lines.
public class OrnamentCaption : ContentControl
{
    public static readonly DependencyProperty TextProperty = DependencyProperty.Register(nameof(Text), typeof(string), typeof(OrnamentCaption),
        new PropertyMetadata("", (d, e) => ((OrnamentCaption)d)._text.Text = (string)e.NewValue));
    public static readonly DependencyProperty SizeProperty = DependencyProperty.Register(nameof(Size), typeof(double), typeof(OrnamentCaption),
        new PropertyMetadata(18.0, (d, _) => ((OrnamentCaption)d).Resize()));
    public string Text { get => (string)GetValue(TextProperty); set => SetValue(TextProperty, value); }
    public double Size { get => (double)GetValue(SizeProperty); set => SetValue(SizeProperty, value); }

    private readonly OutlinedText _text = new() { Wrap = true, TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly System.Windows.Shapes.Path _left = Star(), _right = Star();

    private static System.Windows.Shapes.Path Star() => new()
    {
        Data = Theme.Sparkle, Fill = Theme.Brush(Color.FromRgb(0x6B, 0x4D, 0x0D)), Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Center,
    };

    public OrnamentCaption()
    {
        Focusable = false;
        HorizontalAlignment = HorizontalAlignment.Center;
        // A dock panel, not a star column: a centered caption must size to
        // its text, and only wrap when the row is genuinely too narrow.
        var g = new DockPanel();
        DockPanel.SetDock(_left, Dock.Left); DockPanel.SetDock(_right, Dock.Right);
        _left.Margin = new Thickness(0, 0, 7, 0); _right.Margin = new Thickness(7, 0, 0, 0);
        g.Children.Add(_left); g.Children.Add(_right); g.Children.Add(_text);
        Content = g;
        Resize();
    }

    private void Resize()
    {
        _text.Size = Size;
        _left.Width = _left.Height = _right.Width = _right.Height = Size * 0.72;
    }
}

/// The dark leather backdrop: the embossed forest artwork filled to the
/// window, a glossy diagonal sheen, and a vignette.
public class LeatherBackground : Grid
{
    private static readonly ImageSource Forest = Theme.Image("leather-forest.jpg");

    public LeatherBackground()
    {
        IsHitTestVisible = false;
        var baseGrad = new LinearGradientBrush(Theme.LeatherLight, Theme.LeatherDeep, 45);
        Children.Add(new Border { Background = baseGrad });
        Children.Add(new Border { Background = new ImageBrush(Forest) { Stretch = Stretch.UniformToFill } });
        var sheen = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        sheen.GradientStops.Add(new GradientStop(Color.FromArgb(26, 255, 255, 255), 0));
        sheen.GradientStops.Add(new GradientStop(Colors.Transparent, 0.5));
        sheen.GradientStops.Add(new GradientStop(Color.FromArgb(26, 0, 0, 0), 1));
        Children.Add(new Border { Background = sheen });
        var vignette = new RadialGradientBrush { RadiusX = 0.75, RadiusY = 0.75 };
        vignette.GradientStops.Add(new GradientStop(Colors.Transparent, 0.35));
        vignette.GradientStops.Add(new GradientStop(Color.FromArgb(64, 0, 0, 0), 1));
        Children.Add(new Border { Background = vignette });
    }
}

/// The wallet's stitched edge as the window border: a dark leather band
/// with a dashed line of tan thread through it. Decoration only.
public class StitchedEdge : FrameworkElement
{
    public StitchedEdge() { IsHitTestVisible = false; }
    protected override void OnRender(DrawingContext dc)
    {
        var r = new Rect(RenderSize);
        if (r.Width < 40 || r.Height < 40) return;
        dc.DrawRoundedRectangle(null, new Pen(Theme.Brush(Theme.LeatherDeep), 18), new Rect(9, 9, r.Width - 18, r.Height - 18), 6, 6);
        var thread = new Pen(Theme.Brush(Color.FromRgb(199, 161, 107)), 2.5) { DashStyle = new DashStyle([7 / 2.5, 5 / 2.5], 0) };
        dc.DrawRoundedRectangle(null, thread, new Rect(9, 9, r.Width - 18, r.Height - 18), 8, 8);
    }
}

/// The app masthead: the painted ProxyPrintGenerator plaque with living
/// glitter, and the section name on a small dark chip beneath it.
public class AppMasthead : StackPanel
{
    private static readonly ImageSource Art = Theme.Image("masthead.jpg");

    public static readonly DependencyProperty SectionProperty = DependencyProperty.Register(nameof(Section), typeof(string), typeof(AppMasthead),
        new PropertyMetadata("", (d, e) => ((AppMasthead)d)._chip.Text = (string)e.NewValue));
    public string Section { get => (string)GetValue(SectionProperty); set => SetValue(SectionProperty, value); }

    private readonly OutlinedText _chip = new() { Size = 19 };

    public AppMasthead()
    {
        Margin = new Thickness(12, 12, 12, 10);
        var art = new Grid { MaxWidth = 760, HorizontalAlignment = HorizontalAlignment.Center };
        art.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 16, ShadowDepth = 3, Opacity = 0.4 };
        var img = new Image { Source = Art, Stretch = Stretch.Uniform };
        img.SizeChanged += (_, e) => img.Clip = new RectangleGeometry(new Rect(e.NewSize), 16, 16);
        art.Children.Add(img);
        art.Children.Add(new Border { CornerRadius = new CornerRadius(16), BorderBrush = Theme.Brush(Colors.Black, 0.3), BorderThickness = new Thickness(1) });
        art.Children.Add(new GlitterOverlay { Seed = 4242 });
        art.Children.Add(KofiPill(art));
        Children.Add(art);
        var chip = new Border
        {
            CornerRadius = new CornerRadius(999),
            Background = Theme.Brush(Theme.LeatherDeep),
            BorderBrush = Theme.Brush(Theme.Gold, 0.55),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(15, 2, 15, 2),
            Margin = new Thickness(0, 7, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = _chip,
        };
        Children.Add(chip);
    }

    /// A small tooled leather pill for Ko-fi, tucked into the bottom right
    /// of the masthead's leather frame, under the gold plaque. It scales
    /// with the artwork so it always sits in the same spot.
    private static Button KofiPill(FrameworkElement art)
    {
        var cup = new System.Windows.Shapes.Path
        {
            // A steaming cup with a heart, in a 24 x 24 box.
            Data = Geometry.Parse("M3,8 H17 V14 A5,5 0 0 1 12,19 H8 A5,5 0 0 1 3,14 Z M17,9.5 H18.5 A2.75,2.75 0 0 1 18.5,15 H17 V13.2 H18.4 A1,1 0 0 0 18.4,11.3 H17 Z " +
                                  "M10,15.6 C7.6,13.8 6.8,12.9 6.8,11.8 A1.6,1.6 0 0 1 10,11.3 A1.6,1.6 0 0 1 13.2,11.8 C13.2,12.9 12.4,13.8 10,15.6 Z " +
                                  "M7,2.5 C6,4 8,4.5 7,6.5 M10,2 C9,3.5 11,4 10,6 M13,2.5 C12,4 14,4.5 13,6.5"),
            Fill = Theme.Brush(Color.FromRgb(0xF6, 0xE0, 0xA4)),
            Stroke = Theme.Brush(Color.FromRgb(0xF6, 0xE0, 0xA4)), StrokeThickness = 0.9,
            Width = 22, Height = 22, Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 5, 0),
        };
        var label = new TextBlock
        {
            Text = "Ko-fi", FontFamily = Theme.Plaque, FontWeight = FontWeights.Bold, FontSize = 17,
            Foreground = Theme.Brush(Color.FromRgb(0xF6, 0xE0, 0xA4)), VerticalAlignment = VerticalAlignment.Center,
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(cup); row.Children.Add(label);
        var rim = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1) };
        rim.GradientStops.Add(new GradientStop(Color.FromRgb(250, 222, 128), 0));
        rim.GradientStops.Add(new GradientStop(Color.FromRgb(140, 97, 31), 1));
        var pill = new Border
        {
            CornerRadius = new CornerRadius(999), Padding = new Thickness(9, 3, 12, 3), BorderBrush = rim, BorderThickness = new Thickness(1.5),
            Background = new LinearGradientBrush(Theme.LeatherLight, Theme.LeatherDeep, 90), Child = row,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 4, ShadowDepth = 1.5, Opacity = 0.6 },
        };
        var button = new Button
        {
            Content = new Viewbox { Child = pill, Stretch = Stretch.Uniform },
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
            ToolTip = "Enjoying it? Support ProxyPrintGenerator on Ko-fi (ko-fi.com/kommermail)",
        };
        button.SetResourceReference(StyleProperty, "PlainButton");
        System.Windows.Automation.AutomationProperties.SetName(button, "Support on Ko-fi");
        button.MouseEnter += (_, _) => pill.BorderBrush = Theme.Brush(Color.FromRgb(255, 240, 192));
        button.MouseLeave += (_, _) => pill.BorderBrush = rim;
        button.Click += (_, _) => System.Diagnostics.Process.Start(
            new System.Diagnostics.ProcessStartInfo("https://ko-fi.com/kommermail") { UseShellExecute = true });
        art.SizeChanged += (_, e) =>
        {
            // The leather strip under the plaque runs the bottom ~11% of the art.
            var w = e.NewSize.Width; var h = e.NewSize.Height;
            button.Height = Math.Max(16, h * 0.072);
            button.Margin = new Thickness(0, 0, w * 0.028, h * 0.022);
        };
        return button;
    }
}

/// The main layout: the screen's content on one floating suede panel,
/// with an optional leather bar beneath it, inset from the window edges
/// so the forest artwork frames it.
public class PanelScaffold : ContentControl
{
    public static readonly DependencyProperty BarProperty = DependencyProperty.Register(nameof(Bar), typeof(object), typeof(PanelScaffold),
        new PropertyMetadata(null, (d, e) => d.SetValue(BarVisibilityProperty, e.NewValue == null ? Visibility.Collapsed : Visibility.Visible)));
    public static readonly DependencyProperty BarVisibilityProperty = DependencyProperty.Register(nameof(BarVisibility), typeof(Visibility), typeof(PanelScaffold),
        new PropertyMetadata(Visibility.Collapsed));
    public object? Bar { get => GetValue(BarProperty); set => SetValue(BarProperty, value); }
    public Visibility BarVisibility { get => (Visibility)GetValue(BarVisibilityProperty); set => SetValue(BarVisibilityProperty, value); }

    public PanelScaffold() { Focusable = false; }

    protected override Size MeasureOverride(Size constraint)
    {
        if (!double.IsInfinity(constraint.Width) && !double.IsInfinity(constraint.Height))
        {
            var w = constraint.Width; var h = constraint.Height;
            var side = w >= 1250 ? (w - 920) / 2 : w >= 700 ? 44 : 10;
            var top = Math.Min(38, Math.Max(10, h * 0.03));
            var pad = new Thickness(side, top, side, 26);
            if (Padding != pad) Padding = pad;
        }
        return base.MeasureOverride(constraint);
    }

}

/// One option of a segmented control.
public sealed record Choice(object Value, string Label);
