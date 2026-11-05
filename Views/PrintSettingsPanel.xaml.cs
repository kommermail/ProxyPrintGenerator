using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using ProxyPrintGenerator.Controls;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator.Views;

public static class Choices
{
    public static Choice[] Scales { get; } = [new(1, "300"), new(2, "600"), new(4, "1200"), new(6, "1800")];
    public static Choice[] Formats { get; } = [new(OutputFormat.Pdf, "PDF"), new(OutputFormat.Png, "PNG"), new(OutputFormat.Jpeg, "JPEG")];
    public static Choice[] SafeAreas { get; } = [new(SafeAreaProfile.None, "Off"), new(SafeAreaProfile.CanonInkjet, "Canon")];
}

public partial class PrintSettingsPanel : UserControl
{
    public PrintSettingsPanel() { InitializeComponent(); }

    private PrintJobModel? Model => DataContext as PrintJobModel;
    private void ShiftDown(object s, RoutedEventArgs e) { if (Model != null) Model.ShiftUpMM -= 0.5; }
    private void ShiftUp(object s, RoutedEventArgs e) { if (Model != null) Model.ShiftUpMM += 0.5; }
    private void GapDown(object s, RoutedEventArgs e) { if (Model != null) Model.ExtraGapMM -= 0.25; }
    private void GapUp(object s, RoutedEventArgs e) { if (Model != null) Model.ExtraGapMM += 0.25; }
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
