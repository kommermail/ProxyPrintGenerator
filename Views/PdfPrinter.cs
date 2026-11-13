// PdfPrinter.cs
// Prints a finished proxy PDF straight from the app.
//
// The Print sheet is the app's own print menu: printer, copies, pages,
// print quality, paper type, a live preview, and a Printer preferences
// button that opens the driver's own full settings window (every option
// the printer has). It also checks the printer's reachable area against
// the card grid and warns when a card edge would be clipped.
//
// Pages are rendered with Windows' PDF engine (Windows.Data.Pdf) at the
// printer's resolution (capped by the build's DPI), staged as PNG files,
// and spooled through XPS. Each page is drawn across the whole sheet
// from the paper's corner, never "fit to page", so cards print at true
// size exactly as they sit in the PDF.

using System.IO;
using System.Printing;
using System.Printing.Interop;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Xps;
using ProxyPrintGenerator.Controls;
using ProxyPrintGenerator.Engine;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;

namespace ProxyPrintGenerator.Views;

public static class PdfPrinter
{
    // MARK: - Rendering

    internal static async Task<PdfDocument> OpenAsync(string pdfPath)
        => await PdfDocument.LoadFromFileAsync(await StorageFile.GetFileFromPathAsync(pdfPath));

    /// Renders pages [from, to] (1-based) to PNG files in a temp folder.
    internal static Task<(DirectoryInfo Folder, List<(string Path, Size Size)> Pages)> StageAsync(
        PdfDocument doc, int from, int to, int dpi, Action<string> status)
        => StageAsync(doc, Enumerable.Range(from, to - from + 1).ToList(), dpi, status);

    /// Renders the given pages (1-based, in that order) to PNG files.
    internal static async Task<(DirectoryInfo Folder, List<(string Path, Size Size)> Pages)> StageAsync(
        PdfDocument doc, IList<int> pageNumbers, int dpi, Action<string> status)
    {
        var temp = Directory.CreateTempSubdirectory("ProxyPrintSpool-");
        var folder = await StorageFolder.GetFolderFromPathAsync(temp.FullName);
        var pages = new List<(string Path, Size Size)>();
        for (var n = 0; n < pageNumbers.Count; n++)
        {
            var i = pageNumbers[n];
            status($"Preparing page {n + 1} of {pageNumbers.Count} for printing…");
            using var page = doc.GetPage((uint)(i - 1));
            var size = new Size(page.Size.Width, page.Size.Height); // DIPs, 96 per inch
            var file = await folder.CreateFileAsync($"page-{i:000}.png", CreationCollisionOption.ReplaceExisting);
            using (var stream = await file.OpenAsync(FileAccessMode.ReadWrite))
                await page.RenderToStreamAsync(stream, new PdfPageRenderOptions
                {
                    DestinationWidth = (uint)Math.Round(size.Width / 96.0 * dpi),
                    DestinationHeight = (uint)Math.Round(size.Height / 96.0 * dpi),
                });
            pages.Add((file.Path, size));
        }
        return (temp, pages);
    }

    /// A small picture of one page, for the sheet's preview.
    internal static async Task<BitmapSource> PreviewAsync(PdfDocument doc, int pageIndex, uint width)
    {
        using var page = doc.GetPage((uint)pageIndex);
        using var mem = new InMemoryRandomAccessStream();
        await page.RenderToStreamAsync(mem, new PdfPageRenderOptions { DestinationWidth = width });
        var ms = new MemoryStream();
        await mem.AsStreamForRead().CopyToAsync(ms);
        ms.Position = 0;
        var bmp = new BitmapImage();
        bmp.BeginInit();
        bmp.StreamSource = ms;
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.EndInit();
        bmp.Freeze();
        return bmp;
    }

    /// Spools staged pages to a queue with a ticket, without a dialog.
    internal static Task SpoolAsync(PrintQueue queue, PrintTicket ticket, List<(string Path, Size Size)> pages, string jobName)
    {
        queue.CurrentJobSettings.Description = jobName;
        var writer = PrintQueue.CreateXpsDocumentWriter(queue);
        var done = new TaskCompletionSource();
        writer.WritingCompleted += (_, e) =>
        {
            if (e.Error != null) done.TrySetException(e.Error);
            else if (e.Cancelled) done.TrySetCanceled();
            else done.TrySetResult();
        };
        writer.WriteAsync(new StagedPages(pages), ticket);
        return done.Task;
    }

    /// The plain Windows print dialog, for anyone who wants it.
    public static async Task<string?> PrintWithSystemDialogAsync(string pdfPath, int buildDpi, PaperSize paper, Action<string> status)
    {
        var doc = await OpenAsync(pdfPath);
        var count = (int)doc.PageCount;
        var dlg = new PrintDialog { UserPageRangeEnabled = true, MinPage = 1, MaxPage = (uint)count, PageRange = new PageRange(1, count) };
        var ticket = dlg.PrintTicket ?? new PrintTicket();
        ticket.PageMediaSize = PrinterFit.MediaSize(paper);
        ticket.PageOrientation = PageOrientation.Portrait;
        dlg.PrintTicket = ticket;
        if (dlg.ShowDialog() != true) return null;
        int from = 1, to = count;
        if (dlg.PageRangeSelection == PageRangeSelection.UserPages)
        {
            from = Math.Clamp(dlg.PageRange.PageFrom, 1, count);
            to = Math.Clamp(dlg.PageRange.PageTo, from, count);
        }
        var dpi = Math.Clamp(Math.Min(buildDpi, dlg.PrintTicket.PageResolution?.X ?? 600), 300, 1200);
        var (temp, pages) = await StageAsync(doc, from, to, dpi, status);
        try
        {
            status($"Sending {pages.Count} pages to {dlg.PrintQueue.FullName}…");
            await SpoolAsync(dlg.PrintQueue, dlg.PrintTicket, pages, Path.GetFileNameWithoutExtension(pdfPath));
            return $"Sent {pages.Count} page{(pages.Count == 1 ? "" : "s")} to {dlg.PrintQueue.FullName} at {dpi} dpi, actual size.";
        }
        finally { try { temp.Delete(true); } catch { } }
    }

    /// Harness check: renders a PDF through the same path and writes it as
    /// an XPS document (what the spooler receives) instead of printing.
    internal static async Task<int> WriteXpsAsync(string pdfPath, string xpsPath, int dpi)
    {
        var doc = await OpenAsync(pdfPath);
        var (temp, pages) = await StageAsync(doc, 1, (int)doc.PageCount, dpi, _ => { });
        using (var xps = new System.Windows.Xps.Packaging.XpsDocument(xpsPath, FileAccess.ReadWrite))
            System.Windows.Xps.Packaging.XpsDocument.CreateXpsDocumentWriter(xps).Write(new StagedPages(pages));
        temp.Delete(true);
        return pages.Count;
    }

    /// Hands the staged page images to the print system one at a time,
    /// each drawn edge to edge at the page's true size.
    private sealed class StagedPages(List<(string Path, Size Size)> pages) : DocumentPaginator
    {
        public override DocumentPage GetPage(int pageNumber)
        {
            var (path, size) = pages[pageNumber];
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.UriSource = new Uri(path);
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.EndInit();
            bmp.Freeze();
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen()) dc.DrawImage(bmp, new Rect(size));
            return new DocumentPage(visual, size, new Rect(size), new Rect(size));
        }

        public override bool IsPageCountValid => true;
        public override int PageCount => pages.Count;
        public override Size PageSize { get => pages.Count > 0 ? pages[0].Size : new Size(816, 1056); set { } }
        public override IDocumentPaginatorSource? Source => null;
    }

    // MARK: - The driver's own settings window

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool OpenPrinter(string name, out IntPtr handle, IntPtr defaults);
    [DllImport("winspool.drv")]
    private static extern bool ClosePrinter(IntPtr handle);
    [DllImport("winspool.drv", CharSet = CharSet.Unicode)]
    private static extern int DocumentProperties(IntPtr hwnd, IntPtr printer, string device, IntPtr outDevMode, IntPtr inDevMode, int mode);

    /// Opens the printer driver's Printing Preferences seeded with the
    /// ticket, and returns the ticket the user left it with (or null).
    internal static PrintTicket? ShowDriverPreferences(Window owner, PrintQueue queue, PrintTicket ticket)
    {
        const int DM_OUT_BUFFER = 2, DM_IN_PROMPT = 4, DM_IN_BUFFER = 8, IDOK = 1;
        using var converter = new PrintTicketConverter(queue.FullName, PrintTicketConverter.MaxPrintSchemaVersion);
        var devIn = converter.ConvertPrintTicketToDevMode(ticket, BaseDevModeType.UserDefault);
        if (!OpenPrinter(queue.FullName, out var h, IntPtr.Zero)) return null;
        var inPtr = Marshal.AllocHGlobal(devIn.Length);
        IntPtr outPtr = IntPtr.Zero;
        try
        {
            Marshal.Copy(devIn, 0, inPtr, devIn.Length);
            var size = DocumentProperties(IntPtr.Zero, h, queue.FullName, IntPtr.Zero, IntPtr.Zero, 0);
            if (size <= 0) return null;
            outPtr = Marshal.AllocHGlobal(Math.Max(size, devIn.Length));
            var hwnd = new WindowInteropHelper(owner).Handle;
            var result = DocumentProperties(hwnd, h, queue.FullName, outPtr, inPtr, DM_IN_BUFFER | DM_IN_PROMPT | DM_OUT_BUFFER);
            if (result != IDOK) return null;
            // dmSize + dmDriverExtra give the true length of what came back.
            var dmSize = Marshal.ReadInt16(outPtr, 68);
            var dmExtra = Marshal.ReadInt16(outPtr, 70);
            var devOut = new byte[dmSize + dmExtra];
            Marshal.Copy(outPtr, devOut, 0, devOut.Length);
            var chosen = converter.ConvertDevModeToPrintTicket(devOut);
            return queue.MergeAndValidatePrintTicket(ticket, chosen).ValidatedPrintTicket;
        }
        finally
        {
            Marshal.FreeHGlobal(inPtr);
            if (outPtr != IntPtr.Zero) Marshal.FreeHGlobal(outPtr);
            ClosePrinter(h);
        }
    }
}

/// The app's own print menu.
public static class PrintSheet
{
    public static async void Show(PrintJobModel job)
    {
        if (job.Result is not { } result) return;
        PdfDocument doc;
        try { doc = await PdfPrinter.OpenAsync(result.OutputPath); }
        catch (Exception e) { job.PrintStatus = $"Could not open the PDF to print: {e.Message}"; return; }
        var count = (int)doc.PageCount;
        var owner = MainWindow.Instance;

        // Printers.
        var server = new LocalPrintServer();
        var queues = server.GetPrintQueues([EnumeratedPrintQueueTypes.Local, EnumeratedPrintQueueTypes.Connections])
            .OrderBy(q => q.FullName).ToList();
        if (queues.Count == 0) { job.PrintStatus = "No printers are installed."; return; }
        string? defaultName = null;
        try { defaultName = LocalPrintServer.GetDefaultPrintQueue().FullName; } catch { }
        var remembered = PrintMemory.Load();
        // The printer the cards were fitted to, else the last one used.
        var queue = queues.FirstOrDefault(q => job.FitToPrinter && q.FullName == job.FitPrinter)
                    ?? queues.FirstOrDefault(q => q.FullName == remembered.Printer)
                    ?? queues.FirstOrDefault(q => q.FullName == defaultName) ?? queues[0];
        PrintTicket ticket = null!;
        List<PaperPreset> presets = [];

        // Controls.
        static OutlinedText Label(string t) => new() { Text = t, Size = 20, VerticalAlignment = VerticalAlignment.Center };
        ComboBox Combo() => new() { FontSize = 16, FontFamily = Theme.Fell, MinWidth = 260, Padding = new Thickness(8, 5, 8, 5), VerticalAlignment = VerticalAlignment.Center };
        var printerBox = Combo();
        foreach (var q in queues) printerBox.Items.Add(q.FullName);
        printerBox.SelectedItem = queue.FullName;
        var qualityBox = Combo();
        var mediaBox = Combo();
        var sourceBox = Combo();
        sourceBox.ToolTip = "Which tray or cassette the paper comes from.";
        var colorBox = Combo();
        qualityBox.DisplayMemberPath = mediaBox.DisplayMemberPath = sourceBox.DisplayMemberPath = colorBox.DisplayMemberPath = nameof(DriverOption.Display);
        // Drivers name the paper source feature one of three ways.
        string? sourceFeature = null;
        string? SourceFeature() => new[] { "psk:JobInputBin", "psk:DocumentInputBin", "psk:PageInputBin" }
            .FirstOrDefault(f => DriverTicket.Options(queue, ticket, f).Count > 0);
        var paperBox = new ListBox { FontSize = 13.5 };
        paperBox.SetResourceReference(FrameworkElement.StyleProperty, "Segmented");
        paperBox.ToolTip = $"One click paper setup: the paper type, High quality, {result.Paper.ShortLabel}, and the printer's top resolution.";
        var paperHint = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 14.5, FontFamily = Theme.Fell, Foreground = Theme.Brush(Theme.Ink, 0.75) };
        var copies = 1;
        var copiesText = Label("1");
        var allPages = new RadioButton { Content = $"All {count} pages", IsChecked = true, FontSize = 17, FontFamily = Theme.Fell, Foreground = Theme.Brush(Theme.Ink), VerticalAlignment = VerticalAlignment.Center };
        var somePages = new RadioButton { Content = "Pages", FontSize = 17, FontFamily = Theme.Fell, Foreground = Theme.Brush(Theme.Ink), Margin = new Thickness(18, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
        var fromBox = new TextBox { Text = "1", Width = 56, TextAlignment = TextAlignment.Center };
        var toBox = new TextBox { Text = count.ToString(), Width = 56, TextAlignment = TextAlignment.Center };
        fromBox.SetResourceReference(FrameworkElement.StyleProperty, "FieldBox");
        toBox.SetResourceReference(FrameworkElement.StyleProperty, "FieldBox");
        fromBox.GotFocus += (_, _) => somePages.IsChecked = true;
        toBox.GotFocus += (_, _) => somePages.IsChecked = true;
        var summary = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 15, FontFamily = Theme.Fell, Foreground = Theme.Brush(Theme.Ink, 0.85), Margin = new Thickness(0, 8, 0, 0) };
        var warning = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 15.5, FontFamily = Theme.Fell, Foreground = Theme.Brush(Color.FromRgb(150, 40, 10)), Margin = new Thickness(0, 6, 0, 0) };
        var prefs = SheetParts.Leather("Printer preferences…");
        prefs.ToolTip = "Opens your printer's own settings window: paper type, quality, color, borderless and every other option the driver has.";
        var systemDialog = SheetParts.Leather("Windows print dialog…", 15);
        var printButton = SheetParts.Gold("Print", 22);
        var status = new OutlinedText { Size = 18, Wrap = true, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };

        // Back to back builds: pages from duplexFirst (1-based) on are
        // front/back pairs. They go out as their own double sided job,
        // after the one sided pages, either flipped by the printer or by
        // hand (fronts first, then the stack goes back in for the backs).
        var duplexFirst = result.DuplexStartPage >= 0 ? result.DuplexStartPage + 1 : 0;
        var hasDuplex = duplexFirst > 0;
        const string AutoFlip = "auto", HandFlip = "hand";
        var flipBox = new ListBox { FontSize = 13.5 };
        flipBox.SetResourceReference(FrameworkElement.StyleProperty, "Segmented");
        var flipHint = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 14.5, FontFamily = Theme.Fell, Foreground = Theme.Brush(Theme.Ink, 0.75) };
        var flipChoice = AutoFlip;
        var canAutoDuplex = false;
        List<int>? pendingBacks = null;

        // Options grid.
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        void Row(string label, UIElement control)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var l = Label(label); l.Margin = new Thickness(0, 6, 0, 6);
            Grid.SetRow(l, grid.RowDefinitions.Count - 1);
            Grid.SetRow(control, grid.RowDefinitions.Count - 1); Grid.SetColumn(control, 1);
            if (control is FrameworkElement fe) { fe.Margin = new Thickness(0, 5, 0, 5); fe.HorizontalAlignment = HorizontalAlignment.Left; }
            grid.Children.Add(l); grid.Children.Add(control);
        }
        var copiesRow = new StackPanel { Orientation = Orientation.Horizontal };
        var minus = SheetParts.Leather("−"); minus.Width = 38;
        var plus = SheetParts.Leather("+"); plus.Width = 38; plus.Margin = new Thickness(4, 0, 0, 0);
        copiesText.Margin = new Thickness(0, 0, 12, 0); copiesText.MinWidth = 30;
        copiesRow.Children.Add(copiesText); copiesRow.Children.Add(minus); copiesRow.Children.Add(plus);
        var pagesRow = new StackPanel { Orientation = Orientation.Horizontal };
        pagesRow.Children.Add(allPages); pagesRow.Children.Add(somePages); pagesRow.Children.Add(fromBox);
        pagesRow.Children.Add(new TextBlock { Text = " to ", FontSize = 17, VerticalAlignment = VerticalAlignment.Center, Foreground = Theme.Brush(Theme.Ink) });
        pagesRow.Children.Add(toBox);
        Row("Printer", printerBox);
        var paperStack = new StackPanel();
        paperStack.Children.Add(paperBox);
        paperStack.Children.Add(paperHint);
        Row("Paper", paperStack);
        Row("Paper source", sourceBox);
        paperStack.HorizontalAlignment = HorizontalAlignment.Stretch;
        Row("Copies", copiesRow);
        Row("Pages", pagesRow);
        if (hasDuplex)
        {
            var flipStack = new StackPanel();
            flipStack.Children.Add(flipBox);
            flipStack.Children.Add(flipHint);
            Row("Two sided", flipStack);
            flipStack.HorizontalAlignment = HorizontalAlignment.Stretch;
        }
        Row("Print quality", qualityBox);
        Row("Paper type", mediaBox);
        Row("Color", colorBox);
        Row("More", prefs);

        var options = new StackPanel();
        options.Children.Add(grid);
        options.Children.Add(summary);
        options.Children.Add(warning);
        var optionsPanel = new Border { CornerRadius = new CornerRadius(14), Padding = new Thickness(18, 12, 18, 14), Child = options };
        optionsPanel.SetResourceReference(Border.BackgroundProperty, "SuedeBrush");

        // Preview.
        var previewImage = new Image { Stretch = Stretch.Uniform, Width = 300, Height = 388 };
        var previewPage = 0;
        var pageLabel = new OutlinedText { Size = 18, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 10, 0) };
        var prev = SheetParts.Leather("‹"); prev.Width = 40;
        var next = SheetParts.Leather("›"); next.Width = 40;
        async Task ShowPreview()
        {
            pageLabel.Text = $"Page {previewPage + 1} of {count}" + (hasDuplex && previewPage + 1 >= duplexFirst
                ? $" · sheet {(previewPage + 1 - duplexFirst) / 2 + 1} {((previewPage + 1 - duplexFirst) % 2 == 0 ? "front" : "back")}"
                : "");
            prev.IsEnabled = previewPage > 0; next.IsEnabled = previewPage < count - 1;
            try { previewImage.Source = await PdfPrinter.PreviewAsync(doc, previewPage, 600); } catch { }
        }
        prev.Click += async (_, _) => { if (previewPage > 0) { previewPage--; await ShowPreview(); } };
        next.Click += async (_, _) => { if (previewPage < count - 1) { previewPage++; await ShowPreview(); } };
        var nav = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0) };
        nav.Children.Add(prev); nav.Children.Add(pageLabel); nav.Children.Add(next);
        var previewStack = new StackPanel { Margin = new Thickness(0, 0, 22, 0) };
        previewStack.Children.Add(new Border
        {
            Background = Brushes.White, Child = previewImage, HorizontalAlignment = HorizontalAlignment.Center,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 4, Opacity = 0.55 },
        });
        previewStack.Children.Add(nav);

        var right = new DockPanel();
        var actions = new StackPanel();
        actions.Children.Add(printButton);
        actions.Children.Add(status);
        var alt = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 0) };
        alt.Children.Add(systemDialog);
        actions.Children.Add(alt);
        DockPanel.SetDock(actions, Dock.Bottom);
        actions.Margin = new Thickness(0, 14, 0, 0);
        right.Children.Add(actions);
        right.Children.Add(SheetParts.Scroll(optionsPanel));

        var body = new DockPanel();
        DockPanel.SetDock(previewStack, Dock.Left);
        body.Children.Add(previewStack);
        body.Children.Add(right);

        // Ticket handling.
        var refreshing = false;
        void LoadQueue()
        {
            ticket = queue.UserPrintTicket?.Clone() ?? queue.DefaultPrintTicket?.Clone() ?? new PrintTicket();
            ticket.PageMediaSize = PrinterFit.MediaSize(result.Paper);
            ticket.PageOrientation = PageOrientation.Portrait;
            ticket.CopyCount = copies;
            ticket = queue.MergeAndValidatePrintTicket(queue.DefaultPrintTicket ?? ticket, ticket).ValidatedPrintTicket;

            // The paper presets this printer's driver actually offers.
            presets = PaperPreset.For(queue, ticket);
            refreshing = true;
            paperBox.ItemsSource = presets.Select(p => new Choice(p.Label, p.Label)).Prepend(new Choice("", "Default")).ToList();
            refreshing = false;
            var again = remembered.Printer == queue.FullName ? presets.FirstOrDefault(p => p.Label == remembered.Paper) : null;
            sourceFeature = SourceFeature();
            if (remembered.Printer == queue.FullName && sourceFeature != null && remembered.Source is { Length: > 0 } bin
                && DriverTicket.Options(queue, ticket, sourceFeature).Any(o => o.Name == bin))
            {
                try { ticket = DriverTicket.With(queue, ticket, sourceFeature, bin); } catch { }
            }
            if (again != null) ApplyPreset(again);
            else Refresh();
        }

        void ApplyPreset(PaperPreset preset)
        {
            try { ticket = preset.Apply(queue, ticket, PrinterFit.MediaSize(result.Paper)); }
            catch (Exception e) { status.Text = $"That paper setting did not take: {e.Message}"; }
            Refresh();
        }

        void Refresh()
        {
            refreshing = true;
            try
            {
                var caps = queue.GetPrintCapabilities(ticket);
                // The driver's own option lists, with its own names.
                Fill(qualityBox, DriverTicket.Options(queue, ticket, "psk:PageOutputQuality"), DriverTicket.Current(ticket, "psk:PageOutputQuality"));
                if (sourceFeature != null) Fill(sourceBox, DriverTicket.Options(queue, ticket, sourceFeature), DriverTicket.Current(ticket, sourceFeature));
                else Fill(sourceBox, [], null);
                Fill(colorBox, DriverTicket.Options(queue, ticket, "psk:PageOutputColor"), DriverTicket.Current(ticket, "psk:PageOutputColor"));
                Fill(mediaBox, DriverTicket.Options(queue, ticket, "psk:PageMediaType"), DriverTicket.Current(ticket, "psk:PageMediaType"));
                var media = DriverTicket.Current(ticket, "psk:PageMediaType");
                var match = presets.FirstOrDefault(p => p.MediaOption == media && DriverTicket.Current(ticket, "psk:PageOutputQuality") == p.QualityOption);
                paperBox.SelectedValue = match?.Label ?? "";
                paperHint.Text = match?.Hint ?? "";
                paperHint.Visibility = match == null ? Visibility.Collapsed : Visibility.Visible;
                var dpi = Math.Clamp(Math.Min(job.ResultDpi, ticket.PageResolution?.X ?? 600), 300, 1200);
                summary.Text = $"{result.Paper.ShortLabel}, {ticket.PageOrientation?.ToString().ToLowerInvariant() ?? "portrait"}, actual size (100%). " +
                               $"Pages go out at {dpi} dpi" + (job.ResultDpi > dpi ? $" (the most this printer takes; the PDF holds {job.ResultDpi})." : ".");
                // The driver swaps in a paper it has when it doesn't list ours.
                var onPaper = PrinterFit.FromMedia(ticket.PageMediaSize);
                warning.Text = onPaper != null && !onPaper.SameSheet(result.Paper)
                    ? $"Heads up: this printer doesn't list {result.Paper.ShortLabel} paper, the size these pages were built for, so it would print them " +
                      $"on {onPaper.ShortLabel}. Pick a paper size it lists under Paper and printer and build again, or choose another printer."
                    : ReachWarning(job, result.Paper, caps.PageImageableArea);
                if (hasDuplex)
                {
                    canAutoDuplex = caps.DuplexingCapability.Contains(Duplexing.TwoSidedLongEdge);
                    var choices = new List<Choice>();
                    if (canAutoDuplex) choices.Add(new Choice(AutoFlip, "Printer flips"));
                    choices.Add(new Choice(HandFlip, "Flip by hand"));
                    flipBox.ItemsSource = choices;
                    if (!canAutoDuplex) flipChoice = HandFlip;
                    flipBox.SelectedValue = flipChoice;
                    FlipHint();
                }
            }
            catch (Exception e) { summary.Text = $"This printer did not report its options ({e.Message}). Printer preferences still works."; warning.Text = ""; }
            finally { refreshing = false; }
        }

        void FlipHint()
        {
            var sheets = result.DuplexSheets;
            var range = $"pages {duplexFirst}–{count}";
            flipHint.Text = flipChoice == AutoFlip
                ? $"The one sided pages print first, then {range} print double sided ({sheets} sheet{(sheets == 1 ? "" : "s")}, flipped on the long edge)."
                : (canAutoDuplex ? "" : "This printer can't print both sides by itself. ") +
                  $"The one sided pages print first, then the fronts of {range}. Put that stack back in the tray to print the backs on the other side, then press Print backs.";
        }

        static void Fill(ComboBox box, List<DriverOption> items, string? current)
        {
            box.ItemsSource = items;
            box.IsEnabled = items.Count > 0;
            box.SelectedItem = items.FirstOrDefault(i => i.Name == current) ?? items.FirstOrDefault();
        }

        paperBox.SelectionChanged += (_, _) =>
        {
            if (refreshing || paperBox.SelectedValue is not string label) return;
            var preset = presets.FirstOrDefault(p => p.Label == label);
            if (preset != null) ApplyPreset(preset);
            else { LoadQueueDefaults(); }
            Remember();
        };

        void LoadQueueDefaults()
        {
            // "Printer default": back to the queue's own media and quality.
            var basis = queue.UserPrintTicket ?? queue.DefaultPrintTicket;
            foreach (var feature in new[] { "psk:PageMediaType", "psk:PageOutputQuality" })
                if (basis != null && DriverTicket.Current(basis, feature) is { } opt) ticket = DriverTicket.With(queue, ticket, feature, opt);
            Refresh();
        }

        flipBox.SelectionChanged += (_, _) =>
        {
            if (refreshing || flipBox.SelectedValue is not string choice) return;
            flipChoice = choice;
            FlipHint();
        };

        printerBox.SelectionChanged += (_, _) =>
        {
            var q = queues.FirstOrDefault(x => x.FullName == printerBox.SelectedItem as string);
            if (q == null || q == queue) return;
            queue = q;
            LoadQueue();
        };
        void Remember() => PrintMemory.Save(new PrintMemory(queue.FullName, paperBox.SelectedValue as string ?? "",
            sourceFeature != null ? DriverTicket.Current(ticket, sourceFeature) : null));
        sourceBox.SelectionChanged += (_, _) =>
        {
            if (refreshing || sourceFeature == null || sourceBox.SelectedItem is not DriverOption o) return;
            ticket = DriverTicket.With(queue, ticket, sourceFeature, o.Name);
            Refresh();
            Remember();
        };
        colorBox.SelectionChanged += (_, _) =>
        {
            if (refreshing || colorBox.SelectedItem is not DriverOption o) return;
            ticket = DriverTicket.With(queue, ticket, "psk:PageOutputColor", o.Name);
            Refresh();
        };
        qualityBox.SelectionChanged += (_, _) =>
        {
            if (refreshing || qualityBox.SelectedItem is not DriverOption o) return;
            ticket = DriverTicket.With(queue, ticket, "psk:PageOutputQuality", o.Name);
            Refresh();
        };
        mediaBox.SelectionChanged += (_, _) =>
        {
            if (refreshing || mediaBox.SelectedItem is not DriverOption o) return;
            ticket = DriverTicket.With(queue, ticket, "psk:PageMediaType", o.Name);
            Refresh();
        };
        minus.Click += (_, _) => { copies = Math.Max(1, copies - 1); copiesText.Text = copies.ToString(); ticket.CopyCount = copies; };
        plus.Click += (_, _) => { copies = Math.Min(99, copies + 1); copiesText.Text = copies.ToString(); ticket.CopyCount = copies; };
        prefs.Click += (_, _) =>
        {
            try
            {
                var chosen = PdfPrinter.ShowDriverPreferences(owner, queue, ticket);
                if (chosen != null) { ticket = chosen; copies = ticket.CopyCount ?? copies; copiesText.Text = copies.ToString(); Refresh(); }
            }
            catch (Exception e) { status.Text = $"The printer's preferences window did not open: {e.Message}"; }
        };

        var close = owner.ShowSheet($"Print {Path.GetFileName(result.OutputPath)}", body, 1080);

        systemDialog.Click += async (_, _) =>
        {
            close();
            job.IsPrinting = true;
            try { job.PrintStatus = await PdfPrinter.PrintWithSystemDialogAsync(result.OutputPath, job.ResultDpi, result.Paper, s => job.PrintStatus = s); }
            catch (Exception e) { job.PrintStatus = $"Printing failed: {e.Message}"; }
            finally { job.IsPrinting = false; }
        };

        PrintTicket Sided(Duplexing sides)
        {
            var t = ticket.Clone();
            t.Duplexing = sides;
            return queue.MergeAndValidatePrintTicket(ticket, t).ValidatedPrintTicket;
        }

        int Dpi() => Math.Clamp(Math.Min(job.ResultDpi, ticket.PageResolution?.X ?? 600), 300, 1200);

        /// Stages and spools one job; returns the pages sent.
        async Task<int> Send(IList<int> pageNumbers, PrintTicket t, string jobName)
        {
            if (pageNumbers.Count == 0) return 0;
            var staged = await PdfPrinter.StageAsync(doc, pageNumbers, Dpi(), s => status.Text = job.PrintStatus = s);
            try
            {
                status.Text = job.PrintStatus = $"Sending {staged.Pages.Count} pages to {queue.FullName}…";
                await PdfPrinter.SpoolAsync(queue, t, staged.Pages, jobName);
                return staged.Pages.Count;
            }
            finally { try { staged.Folder.Delete(true); } catch { } }
        }

        string Sent(int pages, string what) => $"Sent {pages} page{(pages == 1 ? "" : "s")}" + what +
                                               (copies > 1 ? $" × {copies} copies" : "") + $" to {queue.FullName} at {Dpi()} dpi, actual size.";

        printButton.Click += async (_, _) =>
        {
            ticket.CopyCount = copies;
            var name = Path.GetFileNameWithoutExtension(result.OutputPath);

            // Second half of a flip by hand: the backs.
            if (pendingBacks is { } backs)
            {
                printButton.IsEnabled = false;
                job.IsPrinting = true;
                try
                {
                    var n = await Send(backs, Sided(Duplexing.OneSided), name + " (backs)");
                    job.PrintStatus = Sent(n, " of backs");
                    pendingBacks = null;
                    close();
                }
                catch (Exception e) { status.Text = job.PrintStatus = $"Printing failed: {e.Message}"; printButton.IsEnabled = true; }
                finally { job.IsPrinting = false; }
                return;
            }

            int from = 1, to = count;
            if (somePages.IsChecked == true)
            {
                if (!int.TryParse(fromBox.Text, out from) || !int.TryParse(toBox.Text, out to) || from < 1 || to > count || from > to)
                { status.Text = $"Pages must run from 1 to {count}."; return; }
            }

            // Split the range into its one sided part and its front/back pairs.
            var single = Enumerable.Range(from, to - from + 1).Where(p => !hasDuplex || p < duplexFirst).ToList();
            var pairs = hasDuplex ? Enumerable.Range(from, to - from + 1).Where(p => p >= duplexFirst).ToList() : [];
            if (pairs.Count > 0 && ((pairs[0] - duplexFirst) % 2 != 0 || pairs.Count % 2 != 0))
            {
                status.Text = $"Pages {duplexFirst}–{count} print in front/back pairs: start on a front ({duplexFirst}, {duplexFirst + 2}, …) and end on a back.";
                return;
            }

            printButton.IsEnabled = false;
            job.IsPrinting = true;
            try
            {
                var parts = new List<string>();
                var sentSingle = await Send(single, hasDuplex ? Sided(Duplexing.OneSided) : ticket, hasDuplex ? name + " (one sided)" : name);
                if (sentSingle > 0) parts.Add(Sent(sentSingle, hasDuplex ? " one sided" : ""));

                if (pairs.Count > 0 && flipChoice == AutoFlip)
                {
                    var both = Sided(Duplexing.TwoSidedLongEdge);
                    if (both.Duplexing != Duplexing.TwoSidedLongEdge)
                        throw new InvalidOperationException("this printer turned down double sided printing. Choose Flip by hand and print again.");
                    var n = await Send(pairs, both, name + " (double sided)");
                    parts.Add(Sent(n, " double sided"));
                }
                else if (pairs.Count > 0)
                {
                    var fronts = pairs.Where((_, i) => i % 2 == 0).ToList();
                    var n = await Send(fronts, Sided(Duplexing.OneSided), name + " (fronts)");
                    parts.Add(Sent(n, " of fronts"));
                    pendingBacks = pairs.Where((_, i) => i % 2 == 1).ToList();
                    Remember();
                    job.PrintStatus = string.Join(" ", parts);
                    status.Text = "Fronts sent. When they finish, put that stack back in the tray so the backs print on the blank side " +
                                  "(your printer's manual shows which way up), then press Print backs.";
                    printButton.Content = "Print backs";
                    printButton.IsEnabled = true;
                    return;
                }

                Remember();
                job.PrintStatus = string.Join(" ", parts);
                close();
            }
            catch (Exception e) { status.Text = job.PrintStatus = $"Printing failed: {e.Message}"; printButton.IsEnabled = true; }
            finally { job.IsPrinting = false; }
        };

        LoadQueue();
        await ShowPreview();
    }

    /// Compares where the cards sit against what the printer can reach,
    /// and says so plainly if a card edge would be cut off.
    private static string ReachWarning(PrintJobModel job, PaperSize paper, PageImageableArea? area)
    {
        if (area == null) return "";
        const double mmPerDip = 25.4 / 96.0;
        var settings = job.LayoutSettings();
        settings.Paper = paper;
        var paperW = paper.WidthMM;
        var paperH = paper.HeightMM;
        var left = settings.ResolvedLeftMarginMM();
        var top = settings.ResolvedTopMarginMM();
        var gridW = settings.GridWidthMM;
        var gridH = settings.GridHeightMM;
        var reachLeft = area.OriginWidth * mmPerDip;
        var reachTop = area.OriginHeight * mmPerDip;
        var reachRight = paperW - reachLeft - area.ExtentWidth * mmPerDip;
        var reachBottom = paperH - reachTop - area.ExtentHeight * mmPerDip;
        var problems = new List<string>();
        if (top < reachTop - 0.05) problems.Add($"top ({reachTop:0.0} mm unreachable, cards start at {top:0.0} mm)");
        if (paperH - top - gridH < reachBottom - 0.05) problems.Add($"bottom ({reachBottom:0.0} mm unreachable, cards end {paperH - top - gridH:0.0} mm from the edge)");
        if (left < reachLeft - 0.05) problems.Add($"left ({reachLeft:0.0} mm unreachable)");
        if (paperW - left - gridW < reachRight - 0.05) problems.Add($"right ({reachRight:0.0} mm unreachable)");
        return problems.Count == 0 ? ""
            : "Heads up: this printer can't print all the way to the " + string.Join(", ", problems) +
              ", so card edges there would be cut off. Turn on Fit to my printer (under Paper and printer) and build again, " +
              "or pick borderless in Printer preferences.";
    }
}
