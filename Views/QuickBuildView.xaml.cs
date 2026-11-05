using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace ProxyPrintGenerator.Views;

/// Paste a list and print it, no saving.
public partial class QuickBuildView : UserControl
{
    private readonly PrintJobModel _model = new();

    public QuickBuildView()
    {
        InitializeComponent();
        DataContext = _model;
    }

    private void OnOpenFile(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog { Filter = "Deck lists (*.txt)|*.txt|All files (*.*)|*.*" };
        if (dlg.ShowDialog(Window.GetWindow(this)) == true) _model.LoadDeckFile(dlg.FileName);
    }
}
