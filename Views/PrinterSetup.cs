// PrinterSetup.cs
// Getting a printer onto its maker's own driver, from the print sheet:
//   - Get the driver for me: the maker's installer, downloaded and
//     checked (DriverDownloads), then run after Windows' own prompt.
//   - Set it up for me: the printer added again with that driver
//     (PrinterDrivers.SetUpAsync), after Windows' own prompt.
//   - The printer setup guide: everything done outside the app, one
//     short step at a time, every step skippable, and the whole guide
//     too. Mirrored from the Mac app, Nov 15, 2026.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using ProxyPrintGenerator.Controls;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator.Views;

public static class PrinterSetup
{
    // MARK: - Get the driver for me

    /// Looks the model up in the driver list, asks, downloads and checks
    /// the installer, and runs it. Returns a line for the print sheet,
    /// or null when the person cancelled. Throws on a failure.
    public static async Task<string?> GetDriverAsync(PrinterStatus p, Action<string> say)
    {
        say("Looking for the driver on the app's driver list (GitHub)…");
        var pkg = await DriverDownloads.FindAsync(p.Model, CancellationToken.None);
        if (pkg == null)
        {
            var page = PrinterDrivers.MakerDriverPage(p.Maker);
            return $"{p.Model} isn't on the app's driver list yet. Show me how walks you through getting it from {p.Maker}"
                   + (page != null ? "'s website." : ".");
        }
        var publisher = DriverDownloads.Makers[pkg.Maker].Publisher;
        var mb = pkg.Size / 1048576.0;
        if (!await ConfirmAsync("Get the driver?",
                $"Download {(pkg.Title.Length > 0 ? pkg.Title : pkg.Driver)} ({mb:0} MB) from {pkg.Maker}'s server ({pkg.Host}) and run its installer?",
                $"Before anything runs, the app checks the file is exactly the one on its driver list and is signed by {publisher}. " +
                "Windows then asks for permission to install it. Follow the installer's steps; if it offers to connect your printer, say yes.",
                "Download and install"))
            return null;

        say("Downloading…");
        var progress = new Progress<(long Done, long Total)>(x =>
            say($"Downloading {pkg.Maker}'s driver: {x.Done / 1048576.0:0} of {x.Total / 1048576.0:0} MB"));
        var path = await DriverDownloads.DownloadAsync(pkg, progress, CancellationToken.None);
        say($"Checked: signed by {publisher}. Running the installer; Windows will ask for permission…");
        try { await DriverDownloads.RunInstallerAsync(path, publisher); }
        finally { DriverDownloads.CleanUp(); }
        return $"{pkg.Maker}'s installer finished.";
    }

    // MARK: - Set it up for me

    public static async Task<string?> SetUpAsync(PrinterStatus p, Action<string> say)
    {
        if (p.UnusedMakerDriver is not { } driver) return null;
        if (!await ConfirmAsync($"Set up {driver}?",
                $"The app will add {driver} as a new printer, using {p.Maker}'s own driver, on the same connection your printer uses now.",
                "Your current printer stays as it is, and your default printer doesn't change. Windows asks for permission first.",
                "Add printer"))
            return null;
        say($"Adding {driver}; Windows will ask for permission…");
        return await PrinterDrivers.SetUpAsync(p);
    }

    /// A small yes/no sheet.
    public static Task<bool> ConfirmAsync(string title, string question, string detail, string yesLabel)
    {
        var done = new TaskCompletionSource<bool>();
        var body = new StackPanel();
        body.Children.Add(SheetParts.Note(question, 19, 1));
        body.Children.Add(SheetParts.Note(detail, 16));
        var yes = SheetParts.Gold(yesLabel);
        var no = SheetParts.Leather("Cancel", 18);
        no.Margin = new Thickness(12, 0, 0, 0);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        buttons.Children.Add(yes);
        buttons.Children.Add(no);
        body.Children.Add(buttons);
        Action? close = null;
        close = MainWindow.Instance.ShowSheet(title, body, 640, compact: true, canClose: () => { done.TrySetResult(false); return true; });
        yes.Click += (_, _) => { done.TrySetResult(true); close(); };
        no.Click += (_, _) => close();
        return done.Task;
    }

    // MARK: - The guide

    /// The printer setup guide. Actions run back in the print sheet, which
    /// refreshes; recheck re-reads the printer so steps tick themselves.
    public static void ShowGuide(PrinterStatus? start, Func<Task<PrinterStatus?>> recheck,
                                 Func<Task> getDriver, Func<Task> setUp)
    {
        var p = start;
        var step = 0;
        var skipped = new HashSet<int>();
        string[] titles = ["Connect", "Get driver", "Install", "Use driver", "Print"];
        var maker = p?.Maker is { Length: > 0 } m ? m : "your printer maker";
        var model = p?.Model ?? "your printer";

        bool Done(int s) => p != null && s switch
        {
            0 => true,
            1 or 2 => p.Kind == DriverKind.Maker || p.UnusedMakerDriver != null,
            3 => p.Kind == DriverKind.Maker || p.MakerDriverTwin != null,
            _ => false,
        };

        var dots = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 10) };
        var content = new StackPanel();
        var back = SheetParts.Leather("Back", 16);
        var skip = SheetParts.Leather("Skip this step", 16);
        var next = SheetParts.Gold("Next", 18);
        skip.Margin = new Thickness(0, 0, 10, 0);
        var nav = new DockPanel { Margin = new Thickness(0, 14, 0, 0), LastChildFill = false };
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        right.Children.Add(skip);
        right.Children.Add(next);
        DockPanel.SetDock(back, Dock.Left);
        DockPanel.SetDock(right, Dock.Right);
        nav.Children.Add(back);
        nav.Children.Add(right);

        var body = new StackPanel();
        var skipAll = SheetParts.Leather("Skip, print with what I have", 15);
        skipAll.HorizontalAlignment = HorizontalAlignment.Right;
        skipAll.ToolTip = "Close the guide. Everything prints fine without it; the maker's driver just adds exact paper types and finer quality.";
        body.Children.Add(skipAll);
        body.Children.Add(SheetParts.Note($"About five minutes, once. It gets you {maker}'s own driver, with the exact paper types (like matte photo paper) and its finest quality. Skip any step you've already done.", 16));
        body.Children.Add(dots);
        body.Children.Add(SheetParts.Scroll(content));
        body.Children.Add(nav);

        var close = MainWindow.Instance.ShowSheet("Printer setup guide", body, 760);
        skipAll.Click += (_, _) => close();

        Button Action(string label, Func<Task> run, bool gold = false)
        {
            var b = gold ? SheetParts.Gold(label, 17) : SheetParts.Leather(label, 16);
            b.HorizontalAlignment = HorizontalAlignment.Left;
            b.Margin = new Thickness(0, 6, 10, 4);
            b.Click += async (_, _) => { b.IsEnabled = false; try { await run(); } finally { b.IsEnabled = true; } };
            return b;
        }

        async Task Recheck()
        {
            p = await recheck();
            if (Done(2) && step <= 2) step = 3;
            Render();
        }

        void Render()
        {
            dots.Children.Clear();
            for (var i = 0; i < titles.Length; i++)
            {
                var mark = Done(i) ? "✓" : skipped.Contains(i) ? "→" : i == step ? "●" : "○";
                var t = new TextBlock
                {
                    Text = $"{mark} {titles[i]}", FontFamily = Theme.Fell, FontSize = 15, Margin = new Thickness(0, 0, 14, 0),
                    Foreground = Done(i) ? Brushes.LightGreen : Theme.Brush(Theme.Parchment, i == step ? 1 : 0.7),
                    Cursor = System.Windows.Input.Cursors.Hand,
                };
                var index = i;
                t.MouseLeftButtonUp += (_, _) => { step = index; Render(); };
                dots.Children.Add(t);
            }

            content.Children.Clear();
            var heading = step switch
            {
                0 => "Connect your printer", 1 => $"Get {maker}'s driver", 2 => "Install it",
                3 => "Use the driver with your printer", _ => "Print",
            };
            content.Children.Add(new OutlinedText { Text = $"Step {step + 1}. {heading}" + (Done(step) ? "   ✓ already done" : ""), Size = 23, Margin = new Thickness(0, 0, 0, 6) });
            void Bullet(string text) => content.Children.Add(Line("•  " + text));
            switch (step)
            {
                case 0:
                    Bullet("Turn the printer on and connect it to the same Wi-Fi as this PC, or plug it in with a USB cable.");
                    Bullet("If it isn't in the print window's printer list, add it: open **Printers & scanners** in Windows Settings, click **Add device**, and pick it.");
                    content.Children.Add(Action("Open Printers & scanners", () => { PrinterDrivers.OpenPrinterSettings(); return Task.CompletedTask; }));
                    break;
                case 1:
                    Bullet($"**Get the driver for me** downloads {maker}'s own installer, checks it's the exact file on the app's list and signed by {maker}, and runs it. Windows asks for permission first.");
                    content.Children.Add(Action("Get the driver for me", async () => { await getDriver(); await Recheck(); }, gold: true));
                    Bullet($"Rather get it yourself? On {maker}'s support site, search **{SearchName(model, maker)}**, pick **Windows**, and download the printer driver (Canon calls it the **MP Drivers** or **Printer Driver**).");
                    if (PrinterDrivers.MakerDriverPage(maker) is { } page)
                        content.Children.Add(Action($"Open {maker}'s driver page", () => { PrinterDrivers.OpenUrl(page); return Task.CompletedTask; }));
                    break;
                case 2:
                    Bullet("If you downloaded it yourself, open your **Downloads** folder and double-click the installer.");
                    Bullet("Click through it. When Windows asks whether to allow changes, that's for the installer, not this app. If it offers to connect your printer over the network, say yes.");
                    Bullet("When it finishes, click **Check again**.");
                    content.Children.Add(Action("Check again", Recheck));
                    break;
                case 3:
                    if (p?.MakerDriverTwin is { } twin)
                        Bullet($"You already have **{twin}** using {maker}'s driver. Pick it in the print window and you're set.");
                    else
                    {
                        Bullet($"Your printer needs to be added again with {maker}'s driver. Installing a driver doesn't change printers already set up; Windows keeps its own generic driver unless told otherwise.");
                        Bullet($"**Set it up for me** adds it with {maker}'s driver on the same connection. Your current printer stays as it is. Windows asks for permission first.");
                        var row = new StackPanel { Orientation = Orientation.Horizontal };
                        var setUpButton = Action("Set it up for me", async () => { await setUp(); await Recheck(); }, gold: true);
                        setUpButton.IsEnabled = p?.UnusedMakerDriver != null;
                        row.Children.Add(setUpButton);
                        row.Children.Add(Action("Check again", Recheck));
                        content.Children.Add(row);
                        if (p?.UnusedMakerDriver == null)
                            content.Children.Add(SheetParts.Note($"The app doesn't see {maker}'s driver for {model} yet. Install it first, then click Check again.", 15, 1));
                        content.Children.Add(SheetParts.Note("Rather do it yourself? In Printers & scanners, click Add device, then Add manually > Add a local printer or network printer with manual settings > Use an existing port (your printer's) > pick the maker and model.", 15, 0.75));
                    }
                    break;
                default:
                    Bullet($"In the print window, pick the printer that uses {maker}'s driver.");
                    Bullet("Click a paper button, like **Matte photo**, to match the paper in the tray. It sets the best quality too.");
                    Bullet("Click **Print**. Cards always print at actual size.");
                    break;
            }
            back.IsEnabled = step > 0;
            skip.Visibility = step < titles.Length - 1 ? Visibility.Visible : Visibility.Collapsed;
            next.Content = step < titles.Length - 1 ? "Next" : "Done";
        }

        back.Click += (_, _) => { if (step > 0) { step--; Render(); } };
        skip.Click += (_, _) => { skipped.Add(step); step = Math.Min(titles.Length - 1, step + 1); Render(); };
        next.Click += (_, _) => { if (step < titles.Length - 1) { step++; Render(); } else close(); };

        step = Enumerable.Range(0, titles.Length).FirstOrDefault(i => !Done(i), titles.Length - 1);
        Render();
    }

    /// "MB5400" from "Canon MB5400 series".
    private static string SearchName(string model, string maker)
    {
        var words = model.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (words.Count > 0 && words[0].Equals(maker, StringComparison.OrdinalIgnoreCase)) words.RemoveAt(0);
        if (words.Count > 0 && words[^1].Equals("series", StringComparison.OrdinalIgnoreCase)) words.RemoveAt(words.Count - 1);
        return words.Count > 0 ? string.Join(' ', words) : model;
    }

    /// A line of help; **words** are set in bold gold.
    private static TextBlock Line(string text)
    {
        var block = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap, FontFamily = Theme.Fell, FontSize = 17, Margin = new Thickness(0, 3, 0, 3),
            Foreground = Theme.Brush(Theme.Parchment, 0.94),
        };
        var parts = text.Split("**");
        for (var i = 0; i < parts.Length; i++)
            if (parts[i].Length > 0)
                block.Inlines.Add(i % 2 == 1 ? new Run(parts[i]) { FontWeight = FontWeights.Bold, Foreground = Theme.Brush(Theme.Gold) } : new Run(parts[i]));
        return block;
    }
}
