using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Threading;

namespace ProxyPrintGenerator;

public partial class App : Application
{
    /// Headless harness, like the Swift command line tool:
    ///   ProxyPrintGenerator.exe --build deck.txt out.pdf [scale] [pdf|png|jpeg] [duplex]
    /// Writes progress and the result to out.log next to the output.
    protected override async void OnStartup(StartupEventArgs e)
    {
        if (e.Args.Length >= 3 && e.Args[0] == "--build")
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            var output = System.IO.Path.GetFullPath(e.Args[2]);
            var log = new System.Text.StringBuilder();
            var code = 0;
            try
            {
                var scale = e.Args.Length > 3 ? int.Parse(e.Args[3]) : 1;
                var format = e.Args.Length > 4 ? Enum.Parse<Engine.OutputFormat>(e.Args[4], true) : Engine.OutputFormat.Pdf;
                var text = System.IO.File.ReadAllText(e.Args[1]);
                var last = "";
                var progress = new Progress<Engine.PrintProgress>(p => { if (p.Stage != last) { last = p.Stage; log.AppendLine($"{DateTime.Now:HH:mm:ss} {p.Stage}"); } });
                var sw = System.Diagnostics.Stopwatch.StartNew();
                var r = await Task.Run(() => Engine.ProxyPrintEngine.RunAsync(text, output,
                    new Engine.PrintJobOptions { Scale = scale, Format = format, PngOverride = true, BackToBack = e.Args.Contains("duplex") }, progress, CancellationToken.None));
                log.AppendLine($"OK {r.FrontCount} fronts, {r.BackCount} backs, {r.PageCount} pages (duplex from {r.DuplexStartPage}), {r.SizeBytes} bytes in {sw.Elapsed.TotalSeconds:0.0}s");
                foreach (var w in r.Warnings) log.AppendLine("warning: " + w);
            }
            catch (Exception ex) { log.AppendLine("FAILED " + ex); code = 1; }
            System.IO.File.WriteAllText(output + ".log", log.ToString());
            Shutdown(code);
            return;
        }
        if (e.Args.Length >= 3 && e.Args[0] == "--print-xps")
        {
            // Checks the print path without a printer: PDF in, spooled XPS out.
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            var dpi = e.Args.Length > 3 ? int.Parse(e.Args[3]) : 600;
            string msg;
            try { msg = $"OK {await Views.PdfPrinter.WriteXpsAsync(System.IO.Path.GetFullPath(e.Args[1]), System.IO.Path.GetFullPath(e.Args[2]), dpi)} pages"; }
            catch (Exception ex) { msg = "FAILED " + ex; }
            System.IO.File.WriteAllText(e.Args[2] + ".log", msg);
            Shutdown();
            return;
        }
        base.OnStartup(e);
        // --import deck.txt adds a deck to the library at launch.
        if (e.Args.Length >= 2 && e.Args[0] == "--import" && System.IO.File.Exists(e.Args[1]))
            Engine.DeckStore.Shared.Add(System.IO.Path.GetFileNameWithoutExtension(e.Args[1]), "File", System.IO.File.ReadAllText(e.Args[1]));
        var window = new MainWindow();
        window.Show();
        if (e.Args.Length >= 1 && e.Args[^1] == "--open-first" && Engine.DeckStore.Shared.Decks.Count > 0)
            window.ShowDeck(Engine.DeckStore.Shared.Decks[0].Id);
    }

    private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        MessageBox.Show(e.Exception.Message, "ProxyPrintGenerator", MessageBoxButton.OK, MessageBoxImage.Warning);
        e.Handled = true;
    }
}

/// Visible when the bound value is "truthy": true, a non-empty string,
/// a non-null object. ConverterParameter "invert" flips it.
public sealed class VisibleWhen : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var on = value switch
        {
            null => false,
            bool b => b,
            string s => s.Length > 0,
            _ => true,
        };
        if (parameter as string == "invert") on = !on;
        return on ? Visibility.Visible : Visibility.Collapsed;
    }
    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}
