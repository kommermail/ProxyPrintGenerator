using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using ProxyPrintGenerator.Controls;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator.Views;

public static class Choices
{
    public static Choice[] Scales { get; } = [new(1, "300"), new(2, "600"), new(4, "1200"), new(6, "1800")];
    public static Choice[] Formats { get; } = [new(OutputFormat.Pdf, "PDF"), new(OutputFormat.Png, "PNG"), new(OutputFormat.Jpeg, "JPEG")];
    public static Choice[] SafeAreas { get; } = [new(SafeAreaProfile.None, "Off"), new(SafeAreaProfile.CanonInkjet, "Canon")];

    public static Choice[] MarkKinds { get; } =
        [new(ProxyMarkKind.None, "None"), new(ProxyMarkKind.Label, "PROXY label"), new(ProxyMarkKind.Border, "Border"), new(ProxyMarkKind.Logo, "Logo")];

    public static Choice[] MarkPositions { get; } =
    [
        new(MarkPosition.TopLeft, "Top left"), new(MarkPosition.Top, "Top middle"), new(MarkPosition.TopRight, "Top right"),
        new(MarkPosition.MiddleLeft, "Middle left"), new(MarkPosition.Middle, "Middle"), new(MarkPosition.MiddleRight, "Middle right"),
        new(MarkPosition.BottomLeft, "Bottom left"), new(MarkPosition.Bottom, "Bottom middle"), new(MarkPosition.BottomRight, "Bottom right"),
    ];

    public static MarkFontChoice[] MarkFonts { get; } =
    [
        new(MarkFont.Cinzel, "Cinzel"), new(MarkFont.CinzelDecorative, "Cinzel Decorative"), new(MarkFont.FellEnglish, "Fell English"),
        new(MarkFont.FellEnglishItalic, "Fell English Italic"), new(MarkFont.FaerieMoot, "Faerie Moot"),
    ];

    public static MarkSwatch[] MarkColors { get; } =
    [
        new("#C41C2C", "Red"), new("#141414", "Black"), new("#FAFAFA", "White"), new("#1E5AC8", "Blue"),
        new("#1E8246", "Green"), new("#7A2E9E", "Purple"), new("#E0701A", "Orange"), new("#C9962F", "Gold"),
    ];
}

/// One font the PROXY label can be lettered in, with what the picker needs
/// to show "PROXY" in it.
public sealed record MarkFontChoice(MarkFont Value, string Name)
{
    public FontFamily Family { get; } = ProxyMarkArt.FamilyFor(Value);
    public FontWeight Weight { get; } = ProxyMarkArt.WeightFor(Value);
    public FontStyle Style { get; } = ProxyMarkArt.StyleFor(Value);
}

/// One color the proxy mark can be.
public sealed record MarkSwatch(string Hex, string Name)
{
    public Brush Brush { get; } = Theme.Freeze(new SolidColorBrush((Color)ColorConverter.ConvertFromString(Hex)));
}

/// A sample card with the chosen proxy mark on it, drawn the same way the
/// build draws it.
public sealed class ProxyMarkPreview : FrameworkElement
{
    public static readonly DependencyProperty MarkProperty = DependencyProperty.Register(nameof(Mark), typeof(ProxyMark), typeof(ProxyMarkPreview),
        new FrameworkPropertyMetadata(ProxyMark.None, FrameworkPropertyMetadataOptions.AffectsRender));
    public ProxyMark Mark { get => (ProxyMark)GetValue(MarkProperty); set => SetValue(MarkProperty, value); }

    private static readonly Brush Edge = Theme.Brush(Color.FromRgb(20, 20, 20));
    private static readonly Brush Frame = Theme.Freeze(new LinearGradientBrush(Color.FromRgb(58, 120, 78), Color.FromRgb(30, 78, 48), 90));
    private static readonly Brush Bar = Theme.Brush(Color.FromRgb(226, 232, 220));
    private static readonly Brush TextBox = Theme.Brush(Color.FromRgb(232, 239, 228));
    private static readonly Brush Ink = Theme.Brush(Color.FromRgb(60, 60, 60), 0.55);
    private static readonly Brush Sky = Theme.Freeze(new LinearGradientBrush(Color.FromRgb(70, 120, 120), Color.FromRgb(24, 52, 44), 90));
    private static readonly Brush Hills = Theme.Brush(Color.FromRgb(16, 40, 30));

    protected override void OnRender(DrawingContext dc)
    {
        var k = Math.Min(ActualWidth / ProxyMarkArt.CardW, ActualHeight / ProxyMarkArt.CardH);
        if (k <= 0) return;
        dc.PushTransform(new ScaleTransform(k, k));
        dc.PushClip(new RectangleGeometry(new Rect(0, 0, ProxyMarkArt.CardW, ProxyMarkArt.CardH), 3, 3));
        dc.DrawRectangle(Edge, null, new Rect(0, 0, 63, 88));
        dc.DrawRoundedRectangle(Frame, null, new Rect(3, 3, 57, 82), 1.2, 1.2);
        dc.DrawRoundedRectangle(Bar, null, new Rect(4.3, 4.3, 54.4, 5.2), 1.4, 1.4);
        dc.DrawRectangle(Sky, null, new Rect(5, 10.5, 53, 38));
        var hills = Geometry.Parse("M5,48.5 L5,36 C14,30 22,34 30,31 C38,28 46,33 58,29 L58,48.5 Z");
        dc.DrawGeometry(Hills, null, hills);
        dc.DrawRoundedRectangle(Bar, null, new Rect(4.3, 49.2, 54.4, 5.0), 1.4, 1.4);
        dc.DrawRectangle(TextBox, null, new Rect(5, 55, 53, 26));
        foreach (var y in new[] { 59.0, 63.0, 67.0, 72.0, 76.0 })
            dc.DrawRectangle(Ink, null, new Rect(8, y, y > 70 ? 34 : 46, 1.1));
        dc.DrawRectangle(Ink, null, new Rect(7, 5.9, 22, 1.8));
        dc.DrawRectangle(Ink, null, new Rect(7, 50.8, 18, 1.8));
        ProxyMarkArt.Draw(dc, Mark);
        dc.Pop();
        dc.Pop();
    }
}

public partial class PrintSettingsPanel : UserControl
{
    private PrintJobModel? _watched;
    private bool _quiet;
    private int _readCount;

    public PrintSettingsPanel()
    {
        InitializeComponent();
        DataContextChanged += (_, _) => Watch(Model);
        // Shown again (another page may have changed the paper): pick up
        // the saved choice and check the printer's driver once more.
        IsVisibleChanged += (_, e) => { if (e.NewValue is true) _ = Refresh(); };
    }

    private PrintJobModel? Model => DataContext as PrintJobModel;
    private void ShiftDown(object s, RoutedEventArgs e) { if (Model != null) Model.ShiftUpMM -= 0.5; }
    private void ShiftUp(object s, RoutedEventArgs e) { if (Model != null) Model.ShiftUpMM += 0.5; }
    private void GapDown(object s, RoutedEventArgs e) { if (Model != null) Model.ExtraGapMM -= 0.25; }
    private void GapUp(object s, RoutedEventArgs e) { if (Model != null) Model.ExtraGapMM += 0.25; }
    private void ReadAgain(object s, RoutedEventArgs e) => _ = ReadPrinterAsync(adoptDriverPaper: false);
    private void BorderThinner(object s, RoutedEventArgs e) { if (Model != null) Model.MarkBorderMM -= 0.5; }
    private void BorderWider(object s, RoutedEventArgs e) { if (Model != null) Model.MarkBorderMM += 0.5; }

    // MARK: - Fit to my printer

    private void Watch(PrintJobModel? model)
    {
        if (_watched != null) _watched.PropertyChanged -= OnModelChanged;
        _watched = model;
        if (model != null) model.PropertyChanged += OnModelChanged;
    }

    private async Task Refresh()
    {
        if (Model is not { } m) return;
        _quiet = true;
        try { m.ReloadLayout(); } finally { _quiet = false; }
        if (m.Printers.Count == 0) m.Printers = await PrinterFit.PrinterNamesAsync();
        if (m.FitToPrinter) await ReadPrinterAsync(adoptDriverPaper: false);
    }

    private void OnModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (_quiet || Model is not { } m) return;
        switch (e.PropertyName)
        {
            case nameof(PrintJobModel.FitToPrinter) when m.FitToPrinter:
                _ = TurnOnFitAsync(m);
                break;
            case nameof(PrintJobModel.FitToPrinter):
                m.FitStatus = "";
                break;
            case nameof(PrintJobModel.FitPrinter) when m.FitToPrinter:
                // A printer just picked: start from the paper it is set to.
                _ = ReadPrinterAsync(adoptDriverPaper: true);
                break;
            case nameof(PrintJobModel.Paper) when m.FitToPrinter:
                _ = ReadPrinterAsync(adoptDriverPaper: false);
                break;
        }
    }

    /// The first time on: the printer last printed to, or Windows'
    /// default, then that printer's own paper.
    private async Task TurnOnFitAsync(PrintJobModel m)
    {
        if (m.Printers.Count == 0) m.Printers = await PrinterFit.PrinterNamesAsync();
        if (m.FitPrinter == null || !m.Printers.Contains(m.FitPrinter))
        {
            var pick = new[] { PrintMemory.Load().Printer, PrinterFit.DefaultPrinter() }.FirstOrDefault(p => p != null && m.Printers.Contains(p))
                       ?? m.Printers.FirstOrDefault();
            if (pick == null) { m.FitStatus = "No printers are installed on this PC."; return; }
            _quiet = true;
            try { m.FitPrinter = pick; } finally { _quiet = false; }
        }
        await ReadPrinterAsync(adoptDriverPaper: true);
    }

    private async Task ReadPrinterAsync(bool adoptDriverPaper)
    {
        if (Model is not { FitToPrinter: true, FitPrinter: { } printer } m) return;
        var mine = ++_readCount;
        m.FitStatus = $"Asking the {printer} driver what it can reach…";
        try
        {
            var reading = await PrinterFit.ReadAsync(printer, adoptDriverPaper ? null : m.Paper);
            if (mine != _readCount) return;
            m.PrinterSizes = reading.Sizes;
            var note = "";
            if (adoptDriverPaper && reading.DriverPaper is { } set)
            {
                if (!set.SameSheet(m.Paper)) note = $"Your printer is set to {set.ShortLabel} paper, so the paper size is now {set.ShortLabel}. ";
                _quiet = true;
                try { m.Paper = m.PaperChoices.FirstOrDefault(p => p.SameSheet(set)) ?? set; } finally { _quiet = false; }
            }
            m.FitMargins = reading.Margins;
            m.FitStatus = note + reading switch
            {
                { PaperListed: false } => $"{printer} doesn't list {m.Paper.ShortLabel} paper, so the cards are laid out without its edges. " +
                                          "Pick a paper size it lists, or another printer.",
                { Margins: null } => $"{printer} didn't say where it can print, so the cards are laid out without its edges.",
                { Margins: { } x } when x.Top + x.Bottom + x.Left + x.Right < 0.1 =>
                    $"{printer} prints edge to edge on {m.Paper.ShortLabel} (borderless), so the cards just stay 1 mm in from the edge.",
                { Margins: { } x } => $"{printer} can't print the outer {x.Top:0.0} mm at the top, {x.Bottom:0.0} mm at the bottom, " +
                                      $"{x.Left:0.0} mm on the left and {x.Right:0.0} mm on the right of {m.Paper.ShortLabel} paper. " +
                                      "The cards stay at least 1 mm inside that, so no edge gets cut off.",
            };
        }
        catch (Exception ex)
        {
            if (mine == _readCount) m.FitStatus = $"Couldn't read {printer}'s driver: {ex.Message}";
        }
    }
}

/// One labeled slider row: label, gold slider, value.
public class SliderRow : Grid
{
    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(nameof(Label), typeof(string), typeof(SliderRow),
        new PropertyMetadata("", (d, e) => ((SliderRow)d)._label.Text = (string)e.NewValue));
    public static readonly DependencyProperty ValueTextProperty = DependencyProperty.Register(nameof(ValueText), typeof(string), typeof(SliderRow),
        new PropertyMetadata("", (d, e) => ((SliderRow)d)._value.Text = (string)e.NewValue));
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(nameof(Value), typeof(double), typeof(SliderRow),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault));
    public string Label { get => (string)GetValue(LabelProperty); set => SetValue(LabelProperty, value); }
    public string ValueText { get => (string)GetValue(ValueTextProperty); set => SetValue(ValueTextProperty, value); }
    public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    public double Minimum { get => _slider.Minimum; set => _slider.Minimum = value; }
    public double Maximum { get => _slider.Maximum; set => _slider.Maximum = value; }

    private readonly OutlinedText _label = new() { Size = 21, VerticalAlignment = VerticalAlignment.Center };
    private readonly OutlinedText _value = new() { Size = 21, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
    private readonly Slider _slider = new() { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 10, 0) };

    public SliderRow()
    {
        Margin = new Thickness(0, 3, 0, 3);
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(160) });
        ColumnDefinitions.Add(new ColumnDefinition());
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(78) });
        _slider.SetResourceReference(StyleProperty, "GoldSlider");
        _slider.SetBinding(System.Windows.Controls.Primitives.RangeBase.ValueProperty, new Binding(nameof(Value)) { Source = this, Mode = BindingMode.TwoWay });
        SetColumn(_slider, 1); SetColumn(_value, 2);
        Children.Add(_label); Children.Add(_slider); Children.Add(_value);
    }
}
