using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator.Views;

/// The always visible action strip: Build before a run, progress and
/// Cancel during one, Save / Open / Show in folder after one.
public partial class BuildBar : UserControl
{
    public BuildBar() { InitializeComponent(); }

    /// The deck page offers a compact options drawer in the bar.
    public bool HasOptionsDrawer
    {
        get => OptionsToggle.Visibility == Visibility.Visible;
        set => OptionsToggle.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
    }

    public event Action? BeforeBuild;

    private PrintJobModel Model => (PrintJobModel)DataContext;

    private void OnBuild(object sender, RoutedEventArgs e)
    {
        BeforeBuild?.Invoke();
        Keyboard.ClearFocus();
        Model.Start();
    }

    private void OnCancel(object sender, RoutedEventArgs e) => Model.Cancel();

    private void OnSave(object sender, RoutedEventArgs e)
    {
        if (Model.Result is not { } result) return;
        var ext = Path.GetExtension(result.OutputPath).TrimStart('.');
        var dlg = new SaveFileDialog
        {
            FileName = Path.GetFileName(result.OutputPath),
            DefaultExt = ext,
            Filter = ext switch
            {
                "pdf" => "PDF document (*.pdf)|*.pdf",
                "png" => "PNG image (*.png)|*.png",
                _ => "JPEG image (*.jpg)|*.jpg",
            },
        };
        if (dlg.ShowDialog(Window.GetWindow(this)) != true) return;
        try
        {
            if (!string.Equals(Path.GetFullPath(dlg.FileName), Path.GetFullPath(result.OutputPath), StringComparison.OrdinalIgnoreCase))
                File.Copy(result.OutputPath, dlg.FileName, true);
            Model.SavedMessage = $"Saved to {Path.GetFileName(dlg.FileName)}";
        }
        catch (Exception ex) { Model.ErrorText = $"Save failed: {ex.Message}"; }
    }

    private void OnPrint(object sender, RoutedEventArgs e)
    {
        if (Model.Result == null || Model.IsPrinting) return;
        PrintSheet.Show(Model);
    }

    private void OnOpen(object sender, RoutedEventArgs e)
    {
        if (Model.Result is { } r) Process.Start(new ProcessStartInfo(r.OutputPath) { UseShellExecute = true });
    }

    private void OnReveal(object sender, RoutedEventArgs e)
    {
        if (Model.Result is { } r) Process.Start("explorer.exe", $"/select,\"{r.OutputPath}\"");
    }

    private void OnToggleOptions(object sender, RoutedEventArgs e)
    {
        var show = OptionsRow.Visibility != Visibility.Visible;
        OptionsRow.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        OptionsText.Text = show ? "▼ Hide options" : "▲ Options";
    }
}
