// Fancy.cs
// The deck nameplate with its traveling foil rim, the guarded PNG limit
// override switch, and the card image loader the previews share.

using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator.Controls;

/// The deck name as a centerpiece: a plate with a holographic foil rim
/// whose colors slowly travel, an oil slick wash behind the letters,
/// twinkling corner sparkles, and the name itself as an editable field.
public class FoilNameplate : Grid
{
    public static readonly DependencyProperty DeckNameProperty = DependencyProperty.Register(nameof(DeckName), typeof(string), typeof(FoilNameplate),
        new FrameworkPropertyMetadata("", FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, (d, e) => ((FoilNameplate)d).OnNameChanged()));
    public static readonly DependencyProperty SubtitleProperty = DependencyProperty.Register(nameof(Subtitle), typeof(string), typeof(FoilNameplate),
        new PropertyMetadata("", (d, e) => ((FoilNameplate)d)._subtitle.Text = (string)e.NewValue));
    public string DeckName { get => (string)GetValue(DeckNameProperty); set => SetValue(DeckNameProperty, value); }
    public string Subtitle { get => (string)GetValue(SubtitleProperty); set => SetValue(SubtitleProperty, value); }

    public event Action<string>? Committed;

    private readonly TextBox _box;
    private readonly OutlinedText _subtitle = new() { Size = 20, HorizontalAlignment = HorizontalAlignment.Center };

    public FoilNameplate()
    {
        Margin = new Thickness(10, 8, 10, 8);
        var spin = new RotateTransform(0, 0.5, 0.5);
        var rimBrush = Theme.FoilLinear(); rimBrush.RelativeTransform = spin;
        var washBrush = Theme.FoilLinear(); washBrush.RelativeTransform = spin;
        Children.Add(new Border { CornerRadius = new CornerRadius(16), Background = rimBrush });
        Children.Add(new Border { CornerRadius = new CornerRadius(13), Margin = new Thickness(3), Background = new LinearGradientBrush(Theme.Leather, Theme.LeatherDeep, 90) });
        Children.Add(new Border { CornerRadius = new CornerRadius(13), Margin = new Thickness(3), Background = washBrush, Opacity = 0.16 });
        spin.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0, 360, TimeSpan.FromSeconds(18)) { RepeatBehavior = RepeatBehavior.Forever });

        _box = new TextBox
        {
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Foreground = Theme.Brush(Theme.Parchment),
            CaretBrush = Theme.Brush(Theme.Parchment),
            SelectionBrush = Theme.Brush(Theme.Gold),
            FontFamily = Theme.Kingdom,
            FontSize = 44,
            TextAlignment = TextAlignment.Center,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Cursor = Cursors.IBeam,
            ToolTip = "Click to rename the deck; Enter saves",
        };
        _box.TextChanged += (_, _) => { if (DeckName != _box.Text) DeckName = _box.Text; FitFont(); };
        _box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Committed?.Invoke(_box.Text); Keyboard.ClearFocus(); } };
        _box.LostKeyboardFocus += (_, _) => Committed?.Invoke(_box.Text);

        var stack = new StackPanel { Margin = new Thickness(20, 16, 20, 16) };
        stack.Children.Add(_box);
        stack.Children.Add(_subtitle);
        stack.Children.Add(new OutlinedText { Text = "click the name to rename it", Size = 16.5, HorizontalAlignment = HorizontalAlignment.Center });
        stack.Children.Add(new ManaPipRow { PipSize = 16, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 3, 0, 0) });
        Children.Add(stack);

        AddSparkle(HorizontalAlignment.Left, VerticalAlignment.Top, 13, 0.0, 10);
        AddSparkle(HorizontalAlignment.Right, VerticalAlignment.Top, 10, 0.7, 14);
        AddSparkle(HorizontalAlignment.Left, VerticalAlignment.Bottom, 10, 1.3, 16);
        AddSparkle(HorizontalAlignment.Right, VerticalAlignment.Bottom, 14, 0.4, 9);
        SizeChanged += (_, _) => FitFont();
    }

    private void AddSparkle(HorizontalAlignment h, VerticalAlignment v, double size, double delay, double inset)
    {
        var p = new System.Windows.Shapes.Path { Data = Theme.Sparkle, Fill = Brushes.White, Stretch = Stretch.Uniform, Width = size * 1.2, Height = size * 1.2,
            HorizontalAlignment = h, VerticalAlignment = v, Margin = new Thickness(inset), IsHitTestVisible = false, Opacity = 0.15 };
        p.BeginAnimation(OpacityProperty, new DoubleAnimation(0.15, 0.9, TimeSpan.FromSeconds(1.6))
        { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, BeginTime = TimeSpan.FromSeconds(delay), EasingFunction = new SineEase() });
        Children.Add(p);
    }

    private void OnNameChanged()
    {
        if (_box.Text != DeckName) _box.Text = DeckName;
        FitFont();
    }

    /// Short names ride at full size; long names step down until they fit.
    private void FitFont()
    {
        var width = ActualWidth > 0 ? ActualWidth : 700;
        var chars = Math.Max(1, (_box.Text ?? "").Length);
        var fit = (width - 64) / chars * 1.25;
        var ceiling = Math.Min(54, Math.Max(32, width * 0.058));
        _box.FontSize = Math.Min(ceiling, Math.Max(16, fit));
    }
}

/// An embossed lab label: white monospaced capitals on a black strip.
public class LabLabel : Border
{
    private readonly TextBlock _t = new()
    {
        FontFamily = new FontFamily("Consolas"), FontWeight = FontWeights.Bold, Foreground = Theme.Brush(Colors.White, 0.92),
    };
    public string Text { get => _t.Text; set => _t.Text = value.ToUpperInvariant(); }
    public double Size { get => _t.FontSize; set => _t.FontSize = value; }

    public LabLabel()
    {
        CornerRadius = new CornerRadius(3);
        Background = Theme.Brush(Color.FromRgb(13, 13, 13));
        BorderBrush = Theme.Brush(Colors.White, 0.22);
        BorderThickness = new Thickness(0.75);
        Padding = new Thickness(10, 4, 10, 4);
        HorizontalAlignment = HorizontalAlignment.Center;
        _t.Effect = new System.Windows.Media.Effects.DropShadowEffect { ShadowDepth = 0.8, BlurRadius = 1, Opacity = 0.85 };
        Child = _t;
        Size = 12;
    }
}

/// The PNG limit override, built like the thing it is: a guarded switch.
/// Hazard striped housing, a plexiglass cover that lifts, and a red
/// rocker underneath. Closing the cover knocks the switch off.
public class GuardedOverride : StackPanel
{
    public static readonly DependencyProperty IsOnProperty = DependencyProperty.Register(nameof(IsOn), typeof(bool), typeof(GuardedOverride),
        new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault, (d, _) => ((GuardedOverride)d).Refresh()));
    public bool IsOn { get => (bool)GetValue(IsOnProperty); set => SetValue(IsOnProperty, value); }

    private bool _coverOpen;
    private readonly Border _onHalf = new(), _offHalf = new();
    private readonly Grid _cover = new();
    private readonly TranslateTransform _coverShift = new();
    private readonly LabLabel _status = new() { Size = 11 };
    private readonly ScaleTransform _rockerTilt = new(1, 1, 26, 32);

    public GuardedOverride()
    {
        HorizontalAlignment = HorizontalAlignment.Center;
        Margin = new Thickness(0, 6, 0, 2);
        Children.Add(new LabLabel { Text = "PNG LIMIT OVERRIDE", Size = 13, Margin = new Thickness(0, 0, 0, 5) });

        var housing = new Grid { Width = 210, Height = 118 };
        housing.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 12, ShadowDepth = 3, Opacity = 0.35 };
        var stripes = new LinearGradientBrush
        {
            MappingMode = BrushMappingMode.Absolute, StartPoint = new Point(0, 0), EndPoint = new Point(12.7, 12.7), SpreadMethod = GradientSpreadMethod.Repeat,
        };
        var yellow = Color.FromRgb(235, 184, 26);
        stripes.GradientStops.Add(new GradientStop(yellow, 0)); stripes.GradientStops.Add(new GradientStop(yellow, 0.5));
        stripes.GradientStops.Add(new GradientStop(Colors.Black, 0.5)); stripes.GradientStops.Add(new GradientStop(Colors.Black, 1));
        housing.Children.Add(new Border { CornerRadius = new CornerRadius(10), Background = stripes });
        var bezel = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1) };
        bezel.GradientStops.Add(new GradientStop(Color.FromArgb(33, 255, 255, 255), 0));
        bezel.GradientStops.Add(new GradientStop(Theme.LeatherDeep, 0.5));
        bezel.GradientStops.Add(new GradientStop(Color.FromArgb(160, 0, 0, 0), 1));
        housing.Children.Add(new Border { CornerRadius = new CornerRadius(6), Margin = new Thickness(7), Background = bezel,
            BorderBrush = Theme.Brush(Colors.White, 0.3), BorderThickness = new Thickness(1) });

        // The rocker: ON on the top half, OFF on the bottom; the live side
        // sits pressed (darker) into the bezel.
        var rocker = new Grid { Width = 66, Height = 78, Cursor = Cursors.Hand, Background = Brushes.Transparent };
        rocker.Children.Add(new Border { CornerRadius = new CornerRadius(8), Background = Theme.Brush(Color.FromRgb(20, 20, 20)),
            BorderBrush = Theme.Brush(Colors.Black, 0.8), BorderThickness = new Thickness(2) });
        var paddle = new Grid { Width = 52, Height = 64, RenderTransform = _rockerTilt };
        paddle.RowDefinitions.Add(new RowDefinition()); paddle.RowDefinitions.Add(new RowDefinition());
        paddle.Clip = new RectangleGeometry(new Rect(0, 0, 52, 64), 5, 5);
        _onHalf.Child = RockerText("ON"); _offHalf.Child = RockerText("OFF");
        Grid.SetRow(_offHalf, 1);
        paddle.Children.Add(_onHalf); paddle.Children.Add(_offHalf);
        rocker.Children.Add(paddle);
        rocker.MouseLeftButtonUp += (_, _) => { if (_coverOpen) IsOn = !IsOn; };
        housing.Children.Add(rocker);

        // The cover: clear plexiglass with screws at the corners.
        var plexi = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        plexi.GradientStops.Add(new GradientStop(Color.FromArgb(77, 255, 255, 255), 0));
        plexi.GradientStops.Add(new GradientStop(Color.FromArgb(20, 255, 255, 255), 0.5));
        plexi.GradientStops.Add(new GradientStop(Color.FromArgb(46, 255, 255, 255), 1));
        _cover.Margin = new Thickness(26, 12, 26, 12);
        _cover.Cursor = Cursors.Hand;
        _cover.RenderTransform = _coverShift;
        _cover.Children.Add(new Border { CornerRadius = new CornerRadius(6), Background = plexi,
            BorderBrush = Theme.Brush(Colors.White, 0.65), BorderThickness = new Thickness(1.5) });
        foreach (var (h, v) in new[] { (HorizontalAlignment.Left, VerticalAlignment.Top), (HorizontalAlignment.Right, VerticalAlignment.Top),
                                       (HorizontalAlignment.Left, VerticalAlignment.Bottom), (HorizontalAlignment.Right, VerticalAlignment.Bottom) })
        {
            _cover.Children.Add(new Ellipse { Width = 7, Height = 7, Margin = new Thickness(7), HorizontalAlignment = h, VerticalAlignment = v,
                Fill = new RadialGradientBrush(Color.FromArgb(230, 255, 255, 255), Color.FromRgb(115, 115, 115)) { GradientOrigin = new Point(0.3, 0.3) },
                Stroke = Theme.Brush(Colors.Black, 0.35), StrokeThickness = 0.5 });
        }
        _cover.Children.Add(new LabLabel { Text = "LIFT", Size = 12, VerticalAlignment = VerticalAlignment.Center });
        _cover.MouseLeftButtonUp += (_, _) =>
        {
            _coverOpen = !_coverOpen;
            if (!_coverOpen) IsOn = false;
            var ease = new BackEase { Amplitude = 0.3, EasingMode = EasingMode.EaseOut };
            _coverShift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(_coverOpen ? -64 : 0, TimeSpan.FromMilliseconds(350)) { EasingFunction = ease });
            _cover.BeginAnimation(OpacityProperty, new DoubleAnimation(_coverOpen ? 0.45 : 1, TimeSpan.FromMilliseconds(350)));
            Refresh();
        };
        housing.Children.Add(_cover);
        Children.Add(housing);
        _status.Margin = new Thickness(0, 5, 0, 0);
        Children.Add(_status);
        Refresh();
    }

    private static TextBlock RockerText(string s) => new()
    {
        Text = s, FontWeight = FontWeights.Black, FontSize = 13, Foreground = Theme.Brush(Colors.White, 0.92),
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontFamily = new FontFamily("Segoe UI"),
    };

    private void Refresh()
    {
        var pressed = Theme.Brush(Color.FromRgb(115, 13, 10));
        var raised = Theme.Brush(Color.FromRgb(209, 36, 28));
        _onHalf.Background = IsOn ? pressed : raised;
        _offHalf.Background = IsOn ? raised : pressed;
        _rockerTilt.ScaleY = 0.96;
        _status.Text = _coverOpen ? (IsOn ? "OVERRIDE ACTIVE: PNG LIMIT OFF" : "COVER OPEN: FLIP SWITCH TO ARM") : "SAFETY COVER ENGAGED";
    }
}

/// Card art for the previews, fetched with the browser agent (the CDN
/// drops custom agents), cached on disk, decoded at preview size, and
/// throttled so a deck page never fires a hundred downloads at once.
public static class CardImages
{
    private static readonly SemaphoreSlim Gate = new(6);
    private static readonly ConcurrentDictionary<string, Task<BitmapSource?>> Memory = new();
    private static readonly string Folder = System.IO.Path.Combine(ProxyPrintEngine.AppDataRoot, "Previews");

    public static Task<BitmapSource?> GetAsync(string? url, int decodeWidth = 0)
    {
        if (string.IsNullOrEmpty(url)) return Task.FromResult<BitmapSource?>(null);
        return Memory.GetOrAdd($"{decodeWidth}|{url}", _ => LoadAsync(url, decodeWidth));
    }

    public static async Task<byte[]?> GetBytesAsync(string url)
    {
        var path = PathFor(url);
        if (File.Exists(path)) return await File.ReadAllBytesAsync(path);
        var (data, status) = await ScryfallTransport.GetAsync(url, 3, 2, CancellationToken.None);
        if (status != HttpStatusCode.OK) return null;
        Directory.CreateDirectory(Folder);
        await File.WriteAllBytesAsync(path, data);
        return data;
    }

    private static string PathFor(string url)
        => System.IO.Path.Combine(Folder, Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(url))) + ".img");

    private static async Task<BitmapSource?> LoadAsync(string url, int decodeWidth)
    {
        await Gate.WaitAsync();
        try
        {
            var data = await GetBytesAsync(url);
            if (data == null) { Memory.TryRemove($"{decodeWidth}|{url}", out _); return null; }
            return await Task.Run(() =>
            {
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.StreamSource = new MemoryStream(data);
                bmp.CacheOption = BitmapCacheOption.OnLoad;
                if (decodeWidth > 0) bmp.DecodePixelWidth = decodeWidth;
                bmp.EndInit();
                bmp.Freeze();
                return (BitmapSource)bmp;
            });
        }
        catch
        {
            Memory.TryRemove($"{decodeWidth}|{url}", out _);
            return null;
        }
        finally { Gate.Release(); }
    }
}
