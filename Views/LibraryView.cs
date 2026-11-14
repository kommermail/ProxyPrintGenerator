// LibraryView.cs
// The deck library home: every saved deck, add by paste or .txt file.
// A deck opens into its page (DeckDetailView).

using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using ProxyPrintGenerator.Controls;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator.Views;

public sealed class LibraryView : UserControl
{
    private readonly StackPanel _list = new() { Margin = new Thickness(20, 0, 20, 10) };

    public LibraryView()
    {
        var stack = new StackPanel();
        stack.Children.Add(new AppMasthead { Section = "Deck Library" });
        stack.Children.Add(TutorialSheet.Sticker());

        var add = new Button { Margin = new Thickness(20, 10, 20, 10) };
        add.SetResourceReference(StyleProperty, "PlaqueButton");
        var addContent = new StackPanel { Orientation = Orientation.Horizontal };
        addContent.Children.Add(new System.Windows.Shapes.Path
        {
            Data = Geometry.Parse("M12,1 A11,11 0 1 1 11.99,1 Z M10.5,6 V10.5 H6 V13.5 H10.5 V18 H13.5 V13.5 H18 V10.5 H13.5 V6 Z"),
            Fill = Theme.Brush(Theme.Ink), Width = 24, Height = 24, Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 9, 0),
        });
        addContent.Children.Add(new OutlinedText { Text = "ADD A DECK", Size = 27, PlaqueStyle = true, VerticalAlignment = VerticalAlignment.Center });
        add.Content = addContent;
        System.Windows.Automation.AutomationProperties.SetName(add, "Add a deck");
        var menu = new ContextMenu();
        var paste = new MenuItem { Header = "Paste a deck list" };
        paste.Click += (_, _) => PasteDeckSheet.Show(Refresh);
        var open = new MenuItem { Header = "Open a .txt file" };
        open.Click += (_, _) => ImportFile();
        menu.Items.Add(paste); menu.Items.Add(open);
        add.ContextMenu = menu;
        add.Click += (_, _) => { menu.PlacementTarget = add; menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom; menu.IsOpen = true; };
        stack.Children.Add(add);

        stack.Children.Add(_list);
        stack.Children.Add(new OutlinedText
        {
            Text = $"Version {Updater.Label(Updater.CurrentVersion)}", Size = 17, HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 10, 0, 2),
        });
        stack.Children.Add(UpdateControls());
        // A quiet tip jar, never in the way.
        var kofi = new Button { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 16), ToolTip = "ko-fi.com/kommermail" };
        kofi.SetResourceReference(StyleProperty, "PlainButton");
        kofi.Content = new OutlinedText { Text = "Enjoying it? Support on Ko-fi", Size = 17 };
        System.Windows.Automation.AutomationProperties.SetName(kofi, "Support on Ko-fi");
        kofi.Click += (_, _) => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://ko-fi.com/kommermail") { UseShellExecute = true });
        stack.Children.Add(kofi);

        Content = new PanelScaffold { Content = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 0, 6, 0) } };
        DeckStore.Shared.Changed += Refresh;
        Refresh();
    }

    /// Under the version: check GitHub now, and the launch check switch.
    private static FrameworkElement UpdateControls()
    {
        var panel = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 8) };
        var check = new Button { HorizontalAlignment = HorizontalAlignment.Center, ToolTip = "Ask GitHub whether a newer version is out" };
        check.SetResourceReference(StyleProperty, "LeatherButton");
        check.Content = "Check for updates";
        System.Windows.Automation.AutomationProperties.SetName(check, "Check for updates");
        var result = new OutlinedText { Size = 16, Wrap = true, TextAlignment = TextAlignment.Center, MaxWidth = 620, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0), Visibility = Visibility.Collapsed };
        check.Click += async (_, _) =>
        {
            check.IsEnabled = false;
            result.Text = "Checking GitHub...";
            result.Visibility = Visibility.Visible;
            var line = await UpdatePrompts.CheckAsync(manual: true);
            check.IsEnabled = true;
            if (line != null) result.Text = line;
        };

        var auto = new CheckBox { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) };
        auto.SetResourceReference(StyleProperty, "Switch");
        auto.Content = new OutlinedText { Text = "Check for updates when the app opens", Size = 16, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
        System.Windows.Automation.AutomationProperties.SetName(auto, "Check for updates when the app opens");
        var syncing = false;
        void Sync() { syncing = true; auto.IsChecked = UpdateSettings.Load().CheckAtStartup == true; syncing = false; }
        Sync();
        auto.Checked += (_, _) => { if (!syncing) UpdatePrompts.SetCheckAtStartup(true); };
        auto.Unchecked += (_, _) => { if (!syncing) UpdatePrompts.SetCheckAtStartup(false); };
        UpdatePrompts.SettingsChanged += Sync;

        panel.Children.Add(check);
        panel.Children.Add(result);
        panel.Children.Add(auto);
        return panel;
    }

    public void Refresh()
    {
        _list.Children.Clear();
        var decks = DeckStore.Shared.Decks;
        if (decks.Count == 0)
        {
            _list.Children.Add(new OutlinedText
            {
                Text = "No decks yet. Use the Add a deck button above: paste a list or open a .txt file.",
                Size = 21, Wrap = true, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, 10, 0, 0),
            });
            return;
        }
        foreach (var deck in decks)
        {
            var id = deck.Id;
            var text = new StackPanel { Margin = new Thickness(6, 14, 6, 14) };
            text.Children.Add(new OutlinedText { Text = deck.Name, Size = 28 });
            text.Children.Add(new OutlinedText { Text = $"{deck.CardCount} cards · {deck.Source}", Size = 20 });
            var chevron = new TextBlock { Text = "›", FontSize = 34, Foreground = Theme.Brush(Theme.Ink, 0.6), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
            var row = new DockPanel();
            DockPanel.SetDock(chevron, Dock.Right);
            row.Children.Add(chevron); row.Children.Add(text);
            var border = new Border
            {
                Child = row, Background = Brushes.Transparent, Cursor = Cursors.Hand, CornerRadius = new CornerRadius(10),
                BorderBrush = Theme.Brush(Theme.Ink, 0.18), BorderThickness = new Thickness(0, 0, 0, 1),
            };
            border.MouseEnter += (_, _) => border.Background = Theme.Brush(Colors.White, 0.12);
            border.MouseLeave += (_, _) => border.Background = Brushes.Transparent;
            border.MouseLeftButtonUp += (_, _) => MainWindow.Instance.ShowDeck(id);
            var cm = new ContextMenu();
            var openItem = new MenuItem { Header = "Open deck" };
            openItem.Click += (_, _) => MainWindow.Instance.ShowDeck(id);
            var del = new MenuItem { Header = "Delete deck" };
            del.Click += (_, _) => ConfirmDelete(deck);
            cm.Items.Add(openItem); cm.Items.Add(new Separator()); cm.Items.Add(del);
            border.ContextMenu = cm;
            _list.Children.Add(border);
        }
    }

    public static void ConfirmDelete(SavedDeck deck, Action? after = null)
    {
        if (MessageBox.Show(MainWindow.Instance, $"Delete \"{deck.Name}\"?\n\nThe deck is removed from your library. This cannot be undone.",
                "Delete this deck?", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        DeckStore.Shared.DeleteDeck(deck.Id);
        after?.Invoke();
    }

    private void ImportFile()
    {
        var dlg = new OpenFileDialog { Filter = "Deck lists (*.txt)|*.txt|All files (*.*)|*.*" };
        if (dlg.ShowDialog(MainWindow.Instance) != true) return;
        string text;
        try { text = File.ReadAllText(dlg.FileName); }
        catch { MessageBox.Show(MainWindow.Instance, "Could not read that file.", "Import failed"); return; }
        if (DeckStore.Shared.Add(Path.GetFileNameWithoutExtension(dlg.FileName), "File", text) == null)
            MessageBox.Show(MainWindow.Instance, "No cards were found in that file.", "Import failed");
    }
}

/// Paste a deck: a name and a list.
public static class PasteDeckSheet
{
    public static void Show(Action onAdded)
    {
        var body = new DockPanel();
        var nameLabel = new OutlinedText { Text = "Deck name", Size = 21 };
        var name = new TextBox { Margin = new Thickness(0, 4, 0, 12) };
        name.SetResourceReference(FrameworkElement.StyleProperty, "FieldBox");
        var listLabel = new OutlinedText { Text = "Deck list", Size = 21 };
        var list = new TextBox { Margin = new Thickness(0, 4, 0, 12), MinHeight = 260 };
        list.SetResourceReference(FrameworkElement.StyleProperty, "SuedeEditor");
        var error = new TextBlock { Foreground = Theme.Brush(Color.FromRgb(255, 138, 122)), FontSize = 16, Margin = new Thickness(0, 0, 0, 8) };
        var add = new Button { Content = "Add deck", HorizontalAlignment = HorizontalAlignment.Stretch };
        add.SetResourceReference(FrameworkElement.StyleProperty, "FantasyButton");
        var top = new StackPanel();
        top.Children.Add(nameLabel); top.Children.Add(name); top.Children.Add(listLabel);
        DockPanel.SetDock(top, Dock.Top);
        var bottom = new StackPanel();
        bottom.Children.Add(error); bottom.Children.Add(add);
        DockPanel.SetDock(bottom, Dock.Bottom);
        body.Children.Add(top); body.Children.Add(bottom); body.Children.Add(list);

        var close = MainWindow.Instance.ShowSheet("Add a deck", body, 760);
        add.Click += (_, _) =>
        {
            var n = name.Text.Trim();
            if (DeckStore.Shared.Add(n.Length == 0 ? "Untitled deck" : n, "Paste", list.Text) != null) { close(); onAdded(); }
            else error.Text = "That list did not parse into any cards.";
        };
        name.Focus();
    }
}
