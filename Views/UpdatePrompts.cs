// UpdatePrompts.cs
// The update sheets: the one time question about checking GitHub for new
// versions, and the "new version" sheet that installs one when asked.
// Updater.cs does the network and the install.

using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using ProxyPrintGenerator.Controls;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator.Views;

public static class UpdatePrompts
{
    private static bool _checking;

    /// Raised when the launch check is turned on or off from a sheet, so
    /// the library's switch can follow.
    public static event Action? SettingsChanged;

    /// At launch: tidy up after an update, ask once, then check if allowed.
    public static async void OnStartup()
    {
        Updater.CleanUpAfterUpdate();
        var settings = UpdateSettings.Load();
        if (settings.CheckAtStartup == null)
        {
            await Task.Delay(700); // let the window settle first
            AskPermission();
        }
        else if (settings.CheckAtStartup == true)
            await CheckAsync(manual: false);
    }

    public static void SetCheckAtStartup(bool on)
    {
        var s = UpdateSettings.Load();
        s.CheckAtStartup = on;
        s.Save();
        SettingsChanged?.Invoke();
    }

    private static void AskPermission()
    {
        var body = new StackPanel();
        body.Children.Add(SheetParts.Note(
            "ProxyPrintGenerator can check its GitHub page for a newer version each time it opens.", 19, 1));
        body.Children.Add(SheetParts.Note(
            "It only asks GitHub for the newest version number. Nothing about you or your decks is sent. " +
            "If you already have the newest version, you won't see anything. If there's a newer one, the app shows what's new " +
            "and asks you before it downloads or installs anything.", 17));
        body.Children.Add(SheetParts.Note(
            "You can change this anytime, or check by hand, at the bottom of the Deck Library.", 16, 0.7));

        var yes = SheetParts.Gold("Yes, check for updates");
        var no = SheetParts.Leather("No thanks", 18);
        no.Margin = new Thickness(12, 0, 0, 0);
        no.Padding = new Thickness(18, 8, 18, 8);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        buttons.Children.Add(yes);
        buttons.Children.Add(no);
        body.Children.Add(buttons);

        var close = MainWindow.Instance.ShowSheet("Check for updates?", body, 660, compact: true);
        yes.Click += (_, _) => { close(); SetCheckAtStartup(true); _ = CheckAsync(manual: false); };
        no.Click += (_, _) => { close(); SetCheckAtStartup(false); };
    }

    /// Checks GitHub and shows the update sheet when a newer version is
    /// out. A launch check stays silent otherwise and passes over a
    /// skipped version; a manual check returns a line to show.
    public static async Task<string?> CheckAsync(bool manual)
    {
        if (_checking) return null;
        _checking = true;
        try
        {
            UpdateInfo? info;
            try { info = await Updater.CheckAsync(CancellationToken.None); }
            catch (Exception ex) { return manual ? $"Couldn't check for updates. {ex.Message}" : null; }
            var current = Updater.Label(Updater.CurrentVersion);
            if (info == null) return manual ? $"You have the newest version ({current})." : null;
            var latest = Updater.Label(info.Version);
            if (!manual && UpdateSettings.Load().SkippedVersion == latest) return null;
            ShowUpdate(info);
            return manual ? $"Version {latest} is available." : null;
        }
        finally { _checking = false; }
    }

    private static void ShowUpdate(UpdateInfo info)
    {
        var latest = Updater.Label(info.Version);
        var body = new StackPanel();
        body.Children.Add(new OutlinedText { Text = $"Version {latest} is ready", Size = 28, Readable = true, BlackOutline = true });
        body.Children.Add(SheetParts.Note($"You have version {Updater.Label(Updater.CurrentVersion)}.", 17, 0.75));
        if (info.Summary.Length > 0) body.Children.Add(SheetParts.Note(info.Summary, 19, 1));
        foreach (var line in info.Highlights)
        {
            var note = SheetParts.Note("•  " + line, 17);
            note.Margin = new Thickness(10, 1, 0, 1);
            body.Children.Add(note);
        }
        var notes = new Button { HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 0), ToolTip = info.PageUrl };
        notes.SetResourceReference(FrameworkElement.StyleProperty, "PlainButton");
        notes.Content = new TextBlock
        {
            Text = "Full release notes on GitHub", FontFamily = Theme.Fell, FontSize = 16,
            Foreground = Theme.Brush(Theme.Gold), TextDecorations = TextDecorations.Underline,
        };
        notes.Click += (_, _) => Open(info.PageUrl);
        body.Children.Add(notes);

        var bar = new ProgressBar { Maximum = 1, Margin = new Thickness(0, 16, 0, 4), Visibility = Visibility.Collapsed };
        var status = SheetParts.Note("", 16, 0.85);
        status.Visibility = Visibility.Collapsed;
        var error = SheetParts.Note("", 16, 1);
        error.Foreground = Theme.Brush(Color.FromRgb(255, 138, 122));
        error.Visibility = Visibility.Collapsed;
        body.Children.Add(bar);
        body.Children.Add(status);
        body.Children.Add(error);

        var canInstall = Updater.CanInstall && info.ZipUrl != null && info.Sha256 != null;
        var update = SheetParts.Gold(canInstall ? "Update now" : "Get it on GitHub");
        var later = SheetParts.Leather("Not now", 18);
        later.Margin = new Thickness(12, 0, 0, 0);
        later.Padding = new Thickness(18, 8, 18, 8);
        var skip = new Button { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 18, 0), ToolTip = "Don't remind me about this version" };
        skip.SetResourceReference(FrameworkElement.StyleProperty, "PlainButton");
        skip.Content = new TextBlock { Text = "Skip this version", FontFamily = Theme.Fell, FontSize = 16, Foreground = Theme.Brush(Theme.Parchment, 0.75), TextDecorations = TextDecorations.Underline };
        var buttons = new DockPanel { Margin = new Thickness(0, 14, 0, 0), LastChildFill = false };
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        right.Children.Add(update);
        right.Children.Add(later);
        DockPanel.SetDock(right, Dock.Right);
        DockPanel.SetDock(skip, Dock.Left);
        buttons.Children.Add(right);
        buttons.Children.Add(skip);
        body.Children.Add(buttons);
        if (canInstall)
            body.Children.Add(SheetParts.Note("Your decks and settings stay as they are. The app restarts when the update is in.", 15, 0.65));

        var close = MainWindow.Instance.ShowSheet("Update available", SheetParts.Scroll(body), 700, compact: true);
        // Closing the sheet (Escape, Close) mid download cancels it.
        var cts = new CancellationTokenSource();
        body.Unloaded += (_, _) => cts.Cancel();

        later.Click += (_, _) => close();
        skip.Click += (_, _) =>
        {
            var s = UpdateSettings.Load();
            s.SkippedVersion = latest;
            s.Save();
            close();
        };
        update.Click += async (_, _) =>
        {
            if (!canInstall) { Open(info.PageUrl); close(); return; }
            update.IsEnabled = skip.IsEnabled = false;
            later.Content = "Cancel";
            error.Visibility = Visibility.Collapsed;
            bar.Visibility = status.Visibility = Visibility.Visible;
            bar.Value = 0;
            status.Text = "Starting the download…";
            var progress = new Progress<(long Done, long Total)>(p =>
            {
                bar.Value = (double)p.Done / p.Total;
                status.Text = $"Downloading version {latest}: {p.Done / 1048576.0:0} of {p.Total / 1048576.0:0} MB";
            });
            try
            {
                var exe = await Updater.InstallAsync(info, progress, cts.Token);
                if (cts.IsCancellationRequested) return; // installed; the next launch opens the new version
                status.Text = $"Version {latest} is in. Restarting…";
                await Task.Delay(500);
                Process.Start(new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = System.IO.Path.GetDirectoryName(exe)! });
                Application.Current.Shutdown();
            }
            catch (OperationCanceledException) { /* sheet closed */ }
            catch (Exception ex)
            {
                bar.Visibility = status.Visibility = Visibility.Collapsed;
                error.Text = $"The update didn't install, and nothing was changed. {ex.Message}";
                error.Visibility = Visibility.Visible;
                update.Content = "Get it on GitHub";
                update.IsEnabled = skip.IsEnabled = true;
                later.Content = "Not now";
                canInstall = false;
            }
        };
    }

    private static void Open(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }
}
