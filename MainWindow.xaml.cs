using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using ProxyPrintGenerator.Controls;
using ProxyPrintGenerator.Views;

namespace ProxyPrintGenerator;

public partial class MainWindow : Window
{
    public static MainWindow Instance { get; private set; } = null!;

    private readonly LibraryView _library = new();
    private readonly Stack<FrameworkElement> _sheets = new();

    public MainWindow()
    {
        Instance = this;
        InitializeComponent();
        Tabs.ItemsSource = new[] { new Choice(0, "Deck Library"), new Choice(1, "Quick Build") };
        Tabs.SelectedIndex = 0;
        LibraryHost.Content = _library;
        SourceInitialized += (_, _) => DarkTitleBar();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape && _sheets.Count > 0) { CloseTopSheet(); e.Handled = true; } };
    }

    private void OnTabChanged(object sender, SelectionChangedEventArgs e)
    {
        if (LibraryHost == null) return;
        var quick = Tabs.SelectedIndex == 1;
        LibraryHost.Visibility = quick ? Visibility.Collapsed : Visibility.Visible;
        QuickBuild.Visibility = quick ? Visibility.Visible : Visibility.Collapsed;
    }

    // MARK: - Library navigation

    public void ShowDeck(Guid id) => LibraryHost.Content = new DeckDetailView(id);
    public void ShowLibrary() { _library.Refresh(); LibraryHost.Content = _library; }

    // MARK: - Sheets (in-window modal panels, stackable)

    /// Shows a sheet: a rounded leather panel with a title row and a
    /// Close button over a dimmed window. Returns the close action.
    public Action ShowSheet(string title, FrameworkElement body, double maxWidth = 980, FrameworkElement? headerExtra = null)
    {
        var dim = new Grid { Background = new SolidColorBrush(Color.FromArgb(150, 0, 0, 0)) };
        var panel = new Grid { MaxWidth = maxWidth, Margin = new Thickness(40, 34, 40, 34) };
        panel.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(22),
            Background = new SolidColorBrush(Theme.LeatherDeep),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 40, ShadowDepth = 6, Opacity = 0.6 },
        });
        var bg = new LeatherBackground();
        bg.Clip = null;
        var bgHost = new Border { CornerRadius = new CornerRadius(22), Child = bg, ClipToBounds = true };
        bgHost.SizeChanged += (_, e) => bgHost.Clip = new RectangleGeometry(new Rect(e.NewSize), 22, 22);
        panel.Children.Add(bgHost);
        // A dark scrim over the tooled artwork so parchment text stays legible.
        panel.Children.Add(new Border { CornerRadius = new CornerRadius(22), Background = new SolidColorBrush(Color.FromArgb(175, 20, 12, 6)) });
        panel.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(22),
            BorderBrush = new SolidColorBrush(Color.FromArgb(140, Theme.Gold.R, Theme.Gold.G, Theme.Gold.B)),
            BorderThickness = new Thickness(1.5),
        });

        var layout = new DockPanel { Margin = new Thickness(22, 16, 22, 18) };
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        var close = new Button { Content = "Close", FontSize = 17 };
        close.SetResourceReference(StyleProperty, "LeatherButton");
        DockPanel.SetDock(close, Dock.Right);
        header.Children.Add(close);
        if (headerExtra != null) { DockPanel.SetDock(headerExtra, Dock.Right); headerExtra.Margin = new Thickness(0, 0, 10, 0); header.Children.Add(headerExtra); }
        header.Children.Add(new OutlinedText { Text = title, Size = 30, VerticalAlignment = VerticalAlignment.Center });
        DockPanel.SetDock(header, Dock.Top);
        layout.Children.Add(header);
        layout.Children.Add(body);
        panel.Children.Add(layout);
        dim.Children.Add(panel);

        void Close()
        {
            if (!_sheets.Contains(dim)) return;
            SheetLayer.Children.Remove(dim);
            var rest = _sheets.Where(s => s != dim).Reverse().ToList();
            _sheets.Clear();
            foreach (var s in rest) _sheets.Push(s);
            if (_sheets.Count == 0) SheetLayer.Visibility = Visibility.Collapsed;
        }
        close.Click += (_, _) => Close();
        _sheets.Push(dim);
        SheetLayer.Children.Add(dim);
        SheetLayer.Visibility = Visibility.Visible;
        dim.Opacity = 0;
        dim.BeginAnimation(OpacityProperty, new DoubleAnimation(1, TimeSpan.FromMilliseconds(160)));
        dim.Tag = (Action)Close;
        return Close;
    }

    private void CloseTopSheet()
    {
        if (_sheets.TryPeek(out var top) && top.Tag is Action close) close();
    }

    // MARK: - Leather colored title bar

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    private void DarkTitleBar()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        var on = 1;
        DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int));          // immersive dark mode
        var caption = 0x000A121C;                                      // COLORREF of leather deep (0x00BBGGRR)
        DwmSetWindowAttribute(hwnd, 35, ref caption, sizeof(int));     // caption color
        var text = 0x00B5DEED;                                         // parchment
        DwmSetWindowAttribute(hwnd, 36, ref text, sizeof(int));        // caption text color
    }
}
