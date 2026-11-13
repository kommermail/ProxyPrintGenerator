using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Threading;

namespace ProxyPrintGenerator;

public partial class App : Application
{
    /// Headless harness, like the Swift command line tool:
    ///   ProxyPrintGenerator.exe --build deck.txt out.pdf [scale] [pdf|png|jpeg] [duplex]
    ///       [paper=letter|a4|legal|tabloid|a3] [margins=top,bottom,left,right]
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
                var paperKey = e.Args.FirstOrDefault(a => a.StartsWith("paper="))?[6..];
                var paper = Engine.PaperSize.Standard.FirstOrDefault(p => p.Key == paperKey) ?? Engine.PaperSize.Letter;
                Engine.PrinterMargins? margins = null;
                if (e.Args.FirstOrDefault(a => a.StartsWith("margins="))?[8..].Split(',').Select(s => double.Parse(s, CultureInfo.InvariantCulture)).ToArray() is [var t, var b, var l, var rt])
                    margins = new Engine.PrinterMargins(t, b, l, rt);
                var r = await Task.Run(() => Engine.ProxyPrintEngine.RunAsync(text, output,
                    new Engine.PrintJobOptions { Scale = scale, Format = format, PngOverride = true, BackToBack = e.Args.Contains("duplex"),
                        Paper = paper, PrinterMargins = margins }, progress, CancellationToken.None));
                var layout = new Engine.PrintSettings { Paper = paper, PrinterMargins = margins };
                log.AppendLine($"OK {r.FrontCount} fronts, {r.BackCount} backs, {r.PageCount} pages (duplex from {r.DuplexStartPage}), {r.SizeBytes} bytes in {sw.Elapsed.TotalSeconds:0.0}s");
                log.AppendLine($"paper {paper.Key} {paper.WidthMM}x{paper.HeightMM} mm, {layout.Columns}x{layout.Rows} = {layout.CardsPerPage} per page, " +
                               $"left {layout.ResolvedLeftMarginMM():0.00} top {layout.ResolvedTopMarginMM():0.00} gaps {layout.ResolvedGapsMM().Row:0.00}/{layout.ResolvedGapsMM().Column:0.00} mm");
                foreach (var w in r.Warnings) log.AppendLine("warning: " + w);
            }
            catch (Exception ex) { log.AppendLine("FAILED " + ex); code = 1; }
            System.IO.File.WriteAllText(output + ".log", log.ToString());
            Shutdown(code);
            return;
        }
        if (e.Args.Length >= 3 && e.Args[0] == "--read-printer")
        {
            // Checks "Fit to my printer" without the window: what the driver says.
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            var log = new System.Text.StringBuilder();
            try
            {
                var paper = e.Args.Length > 3 ? Engine.PaperSize.Standard.FirstOrDefault(p => p.Key == e.Args[3]) : null;
                var r = await Views.PrinterFit.ReadAsync(e.Args[1], paper);
                log.AppendLine($"driver paper: {r.DriverPaper?.Label ?? "none"}");
                log.AppendLine($"asked: {paper?.Label ?? "(driver paper)"}, listed: {r.PaperListed}");
                log.AppendLine(r.Margins is { } m ? $"margins mm: top {m.Top:0.00} bottom {m.Bottom:0.00} left {m.Left:0.00} right {m.Right:0.00}" : "margins: none");
                log.AppendLine($"{r.Sizes.Count} sizes: " + string.Join("; ", r.Sizes.Select(s => s.Label)));
            }
            catch (Exception ex) { log.AppendLine("FAILED " + ex); }
            System.IO.File.WriteAllText(e.Args[2], log.ToString());
            Shutdown();
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
