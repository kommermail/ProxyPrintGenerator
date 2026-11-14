// Sheets.cs
// The deck page's sheets: the printing picker, the zoomed card, the
// replace / add card search. The deck editor is in DeckTextEditor.cs.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using ProxyPrintGenerator.Controls;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator.Views;

internal static class SheetParts
{
    public static TextBlock Note(string text, double size = 16, double opacity = 0.85) => new()
    {
        Text = text, TextWrapping = TextWrapping.Wrap, FontSize = size, Margin = new Thickness(0, 4, 0, 8),
        Foreground = Theme.Brush(Theme.Parchment, opacity), FontFamily = Theme.Fell,
    };

    public static Button Leather(string text, double size = 17)
    {
        var b = new Button { Content = text, FontSize = size };
        b.SetResourceReference(FrameworkElement.StyleProperty, "LeatherButton");
        return b;
    }

    public static Button Gold(string text, double size = 20)
    {
        var b = new Button { Content = text, FontSize = size };
        b.SetResourceReference(FrameworkElement.StyleProperty, "FantasyButton");
        return b;
    }

    /// A text field with a quiet placeholder laid over it while empty.
    public static TextBox Field(string placeholder, out FrameworkElement host)
    {
        var t = new TextBox();
        t.SetResourceReference(FrameworkElement.StyleProperty, "FieldBox");
        var hint = new TextBlock
        {
            Text = placeholder, FontFamily = Theme.Fell, FontSize = 19, Foreground = Theme.Brush(Theme.Ink, 0.45),
            Margin = new Thickness(11, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false,
        };
        t.TextChanged += (_, _) => hint.Visibility = t.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        var g = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        g.Children.Add(t); g.Children.Add(hint);
        host = g;
        return t;
    }

    /// A card image cell: picture, caption lines, click handler.
    public static FrameworkElement Cell(ScryfallCard option, string caption, string? sub, bool current, Action onClick, double width = 180)
    {
        var img = new Image { Stretch = Stretch.Uniform, Height = width * 88 / 63, Width = width };
        img.Clip = new RectangleGeometry(new Rect(0, 0, width, width * 88 / 63), 8, 8);
        var loading = new TextBlock { Text = "Loading…", FontFamily = Theme.Fell, FontSize = 14, Foreground = Theme.Brush(Theme.Parchment, 0.85),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        _ = Load(img, option.DisplayImageUrl, loading);
        var stack = new StackPanel { Width = width, Margin = new Thickness(7) };
        var frame = new Grid();
        frame.Children.Add(new Border { CornerRadius = new CornerRadius(8), Background = Theme.Brush(Colors.Black, 0.25), Height = width * 88 / 63 });
        frame.Children.Add(img);
        frame.Children.Add(loading);
        if (current) frame.Children.Add(new Border { CornerRadius = new CornerRadius(8), BorderBrush = Theme.Brush(Theme.Gold), BorderThickness = new Thickness(3) });
        stack.Children.Add(frame);
        stack.Children.Add(new TextBlock { Text = caption, Foreground = Theme.Brush(Theme.Parchment), FontSize = 14.5, TextAlignment = TextAlignment.Center,
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0), FontFamily = Theme.Fell });
        if (sub != null)
            stack.Children.Add(new TextBlock { Text = sub, Foreground = Theme.Brush(Theme.Parchment, 0.6), FontSize = 12.5, TextAlignment = TextAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis, FontFamily = Theme.Fell });
        if (current)
            stack.Children.Add(new TextBlock { Text = "Current", Foreground = Theme.Brush(Theme.Gold), FontSize = 13, FontWeight = FontWeights.Bold, TextAlignment = TextAlignment.Center });
        var btn = new Button { Content = stack };
        btn.SetResourceReference(FrameworkElement.StyleProperty, "PlainButton");
        btn.Click += (_, _) => onClick();
        return btn;
    }

    private static async Task Load(Image img, string? url, TextBlock? loading = null)
    {
        img.Source = await CardImages.GetAsync(url, 360);
        if (loading != null) loading.Visibility = Visibility.Collapsed;
    }

    public static ScrollViewer Scroll(UIElement content) => new()
    {
        Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
    };

    public static FrameworkElement Busy(string text)
    {
        var bar = new ProgressBar { IsIndeterminate = true, Width = 260, Margin = new Thickness(0, 10, 0, 0) };
        var s = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 30, 0, 30) };
        s.Children.Add(new OutlinedText { Text = text, Size = 22, HorizontalAlignment = HorizontalAlignment.Center });
        s.Children.Add(bar);
        return s;
    }
}

/// Every Scryfall printing of a card; click to swap.
public static class PrintingPickerSheet
{
    public static void Show(Guid deckId, int index, Action? afterPick = null)
    {
        var deck = DeckStore.Shared.Deck(deckId);
        if (deck == null || index >= deck.Entries.Count) return;
        var entry = deck.Entries[index];
        var body = new ContentControl { Content = SheetParts.Busy("Loading printings…") };
        Button? reset = null;
        if (entry.IsAltPrinting) reset = SheetParts.Leather("Reset to imported");
        var close = MainWindow.Instance.ShowSheet(entry.Name, body, 1100, reset);
        if (reset != null) reset.Click += (_, _) => { DeckStore.Shared.ResetPrinting(deckId, index); close(); afterPick?.Invoke(); };
        _ = LoadAsync();

        async Task LoadAsync()
        {
            try
            {
                var options = await ScryfallClient.AllPrintingsAsync(entry.Name);
                if (options.Count == 0) { body.Content = SheetParts.Note("Scryfall lists no printings for this card."); return; }
                var wrap = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center };
                foreach (var o in options)
                {
                    var current = o.Set == entry.SetCode && o.CollectorNumber == entry.CollectorNumber;
                    wrap.Children.Add(SheetParts.Cell(o, o.SetAndNumber, null, current, () =>
                    {
                        DeckStore.Shared.SetPrinting(deckId, index, o.Set, o.CollectorNumber);
                        close();
                        afterPick?.Invoke();
                    }));
                }
                body.Content = SheetParts.Scroll(wrap);
            }
            catch (Exception e) { body.Content = SheetParts.Note(e.Message); }
        }
    }
}

/// The card, large, with a flip and the printing actions.
public static class CardZoomSheet
{
    public static void Show(Guid deckId, int index, Func<ScryfallCard?> option)
    {
        var deck = DeckStore.Shared.Deck(deckId);
        if (deck == null || index >= deck.Entries.Count) return;
        var entry = deck.Entries[index];
        var card = option();
        var flipped = false;
        var image = new Image { Stretch = Stretch.Uniform, MaxWidth = 440, MaxHeight = 615 };
        var scale = new ScaleTransform(1, 1);
        image.RenderTransform = scale; image.RenderTransformOrigin = new Point(0.5, 0.5);
        image.SizeChanged += (_, e) => image.Clip = new RectangleGeometry(new Rect(e.NewSize), e.NewSize.Width * 0.045, e.NewSize.Width * 0.045);
        var loading = new OutlinedText { Text = "Loading…", Size = 20, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
        var imageHost = new Grid { HorizontalAlignment = HorizontalAlignment.Center };
        imageHost.Children.Add(image);
        imageHost.Children.Add(loading);

        async Task ShowFace()
        {
            var url = flipped ? (card?.HasBackFace == true ? card.FaceImageUrl(1) : ScryfallClient.CardBackImageUrl) : card?.FaceImageUrl(0);
            loading.Visibility = url != null ? Visibility.Visible : Visibility.Collapsed;
            image.Source = await CardImages.GetAsync(url);
            loading.Visibility = Visibility.Collapsed;
        }

        var flip = SheetParts.Leather("⟲  Flip card", 18);
        flip.HorizontalAlignment = HorizontalAlignment.Center;
        flip.Margin = new Thickness(0, 12, 0, 8);
        flip.Click += (_, _) =>
        {
            var a = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(170));
            a.Completed += async (_, _) =>
            {
                flipped = !flipped;
                await ShowFace();
                scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(170)));
            };
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, a);
        };

        var info = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        info.Children.Add(new OutlinedText { Text = entry.Name, Size = 26, HorizontalAlignment = HorizontalAlignment.Center });
        info.Children.Add(new OutlinedText { Text = entry.PrintingLabel, Size = 19, HorizontalAlignment = HorizontalAlignment.Center });
        if (entry.IsAltPrinting)
            info.Children.Add(new Border { CornerRadius = new CornerRadius(999), Background = Theme.Brush(Color.FromArgb(200, 255, 140, 0)), Padding = new Thickness(8, 2, 8, 2),
                HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0),
                Child = new TextBlock { Text = "ALT PRINTING", FontWeight = FontWeights.Bold, FontSize = 12, FontFamily = new FontFamily("Segoe UI") } });

        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(imageHost);
        stack.Children.Add(flip);
        stack.Children.Add(info);
        var change = SheetParts.Gold("Change printing");
        change.Margin = new Thickness(0, 14, 0, 0);
        change.Width = 360;
        stack.Children.Add(change);
        Button? revert = null;
        if (entry.CanRevertReplacement)
        {
            revert = SheetParts.Leather($"Change back to original: {entry.PreviousName}");
            revert.Margin = new Thickness(0, 10, 0, 0);
            stack.Children.Add(revert);
        }
        var close = MainWindow.Instance.ShowSheet(entry.Name, SheetParts.Scroll(stack), 700);
        change.Click += (_, _) => PrintingPickerSheet.Show(deckId, index, close);
        if (revert != null) revert.Click += (_, _) => { DeckStore.Shared.RevertReplacement(deckId, index); close(); };
        _ = ShowFace();
    }
}

/// Card search for replacing a card or adding new ones, in Scryfall's
/// own search grammar: name words, types, colors, mana value.
public static class CardSearchSheet
{
    public static void ShowReplace(Guid deckId, int index, string currentName)
        => Show($"Replace {currentName}", true, (o, _) => DeckStore.Shared.ReplaceCard(deckId, index, o.Name, o.Set, o.CollectorNumber), currentName);

    public static void ShowAdd(Guid deckId)
        => Show("Add a card", false, (o, qty) => DeckStore.Shared.AddCard(deckId, o.Name, o.Set, o.CollectorNumber, qty), null);

    /// The search with the color and mana value filters, handing back the
    /// card picked (the deck editor's "replace checked lines").
    public static void ShowPick(string title, Action<ScryfallCard> onPick)
        => Show(title, true, (o, _) => onPick(o), null);

    /// The add search with its copies stepper, handing back the card and
    /// how many (the deck editor's "Add a card").
    public static void ShowAddPick(Action<ScryfallCard, int> onPick) => Show("Add a card", false, onPick, null);

    private static void Show(string title, bool replace, Action<ScryfallCard, int> onPick, string? currentName)
    {
        var name = SheetParts.Field("Card name", out var nameHost);
        var type = SheetParts.Field("Card type (creature, instant, legendary…)", out var typeHost);
        var colors = new HashSet<string>();
        var manaValue = new ComboBox { Width = 90, FontSize = 16, Margin = new Thickness(10, 0, 0, 0) };
        manaValue.Items.Add("Any");
        for (var i = 0; i < 8; i++) manaValue.Items.Add(i.ToString());
        manaValue.Items.Add("8+");
        manaValue.SelectedIndex = 0;
        var quantity = 1;

        var filters = new StackPanel();
        filters.Children.Add(nameHost);
        filters.Children.Add(typeHost);
        if (replace)
        {
            var colorRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 8) };
            colorRow.Children.Add(new OutlinedText { Text = "Colors", Size = 20, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
            var paints = new Dictionary<string, Color>
            {
                ["w"] = Color.FromRgb(250, 242, 217), ["u"] = Color.FromRgb(89, 140, 242), ["b"] = Color.FromRgb(115, 102, 128),
                ["r"] = Color.FromRgb(242, 115, 89), ["g"] = Color.FromRgb(89, 191, 115), ["c"] = Color.FromRgb(191, 184, 173),
            };
            var rings = new Dictionary<string, Border>();
            void Paint() { foreach (var (k, b) in rings) b.BorderBrush = colors.Contains(k) ? Theme.Brush(Theme.Gold) : Brushes.Transparent; }
            foreach (var letter in new[] { "w", "u", "b", "r", "g", "c" })
            {
                var dark = letter is "w" or "c";
                var b = new Border
                {
                    Width = 36, Height = 36, CornerRadius = new CornerRadius(18), Background = Theme.Brush(paints[letter]), BorderThickness = new Thickness(3),
                    Margin = new Thickness(3, 0, 3, 0), Cursor = Cursors.Hand,
                    Child = new TextBlock { Text = letter.ToUpperInvariant(), FontWeight = FontWeights.Bold, FontSize = 16, FontFamily = new FontFamily("Segoe UI"),
                        Foreground = dark ? Theme.Brush(Theme.Ink) : Brushes.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
                };
                b.MouseLeftButtonUp += (_, _) =>
                {
                    // Colorless is exclusive.
                    if (letter == "c") { var had = colors.Contains("c"); colors.Clear(); if (!had) colors.Add("c"); }
                    else { colors.Remove("c"); if (!colors.Remove(letter)) colors.Add(letter); }
                    Paint();
                };
                rings[letter] = b;
                colorRow.Children.Add(b);
            }
            colorRow.Children.Add(new OutlinedText { Text = "Mana value", Size = 20, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(22, 0, 0, 0) });
            colorRow.Children.Add(manaValue);
            filters.Children.Add(colorRow);
            Paint();
        }
        else
        {
            var qtyRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 8) };
            var qtyText = new OutlinedText { Text = "Copies: 1", Size = 20, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) };
            var minus = SheetParts.Leather("−"); minus.Width = 38;
            var plus = SheetParts.Leather("+"); plus.Width = 38; plus.Margin = new Thickness(4, 0, 0, 0);
            minus.Click += (_, _) => { quantity = Math.Max(1, quantity - 1); qtyText.Text = $"Copies: {quantity}"; };
            plus.Click += (_, _) => { quantity = Math.Min(40, quantity + 1); qtyText.Text = $"Copies: {quantity}"; };
            qtyRow.Children.Add(qtyText); qtyRow.Children.Add(minus); qtyRow.Children.Add(plus);
            filters.Children.Add(qtyRow);
        }
        var search = SheetParts.Gold("Search");
        filters.Children.Add(search);

        var filterPanel = new Border
        {
            CornerRadius = new CornerRadius(12), Padding = new Thickness(14), Child = filters, Margin = new Thickness(0, 0, 0, 12),
        };
        filterPanel.SetResourceReference(Border.BackgroundProperty, "SuedeBrush");
        var results = new ContentControl
        {
            Content = SheetParts.Note(replace
                ? "Search by name, or filter by type, color, and mana value. The replacement keeps the same quantity."
                : "Search by name or card type, set how many copies, then click a card to add it to the deck."),
        };
        var body = new DockPanel();
        DockPanel.SetDock(filterPanel, Dock.Top);
        body.Children.Add(filterPanel);
        body.Children.Add(results);
        var close = MainWindow.Instance.ShowSheet(title, body, 1100);

        string Query()
        {
            var parts = new List<string>();
            if (name.Text.Trim().Length > 0) parts.Add(name.Text.Trim());
            parts.AddRange(type.Text.Trim().ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries).Select(w => $"t:{w}"));
            if (replace)
            {
                if (colors.SetEquals(["c"])) parts.Add("c=c");
                else
                {
                    var letters = string.Concat(new[] { "w", "u", "b", "r", "g" }.Where(colors.Contains));
                    if (letters.Length > 0) parts.Add("c>=" + letters);
                }
                if (manaValue.SelectedIndex == 9) parts.Add("mv>=8");
                else if (manaValue.SelectedIndex >= 1) parts.Add($"mv={manaValue.SelectedIndex - 1}");
            }
            return string.Join(" ", parts);
        }

        async void Run()
        {
            var q = Query();
            if (q.Length == 0) { results.Content = SheetParts.Note(replace ? "Type a name or set at least one filter first." : "Type a name or a type first."); return; }
            search.IsEnabled = false;
            results.Content = SheetParts.Busy("Searching Scryfall…");
            try
            {
                var found = await ScryfallClient.SearchCardsAsync(q);
                if (found.Count == 0) { results.Content = SheetParts.Note("No cards match. Loosen a filter and try again."); return; }
                var stack = new StackPanel();
                stack.Children.Add(SheetParts.Note(replace
                    ? (currentName != null ? $"Click a card to replace {currentName} with it." : "Click a card to put it in place of the checked lines.")
                      + " One printing per card; you can change the printing afterwards."
                    : $"Click a card to add {quantity} {(quantity == 1 ? "copy" : "copies")} to the deck. One printing per card; you can change the printing afterwards.", 15, 0.75));
                var wrap = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center };
                foreach (var o in found)
                    wrap.Children.Add(SheetParts.Cell(o, o.Name, o.TypeLine, false, () => { onPick(o, quantity); close(); }, 160));
                stack.Children.Add(wrap);
                if (found.Count >= 150) stack.Children.Add(SheetParts.Note("Showing the first 150 matches. Add filters to narrow it down.", 14, 0.6));
                results.Content = SheetParts.Scroll(stack);
            }
            catch (Exception e) { results.Content = SheetParts.Note($"Search failed: {e.Message}"); }
            finally { search.IsEnabled = true; }
        }
        search.Click += (_, _) => Run();
        name.KeyDown += (_, e) => { if (e.Key == Key.Enter) Run(); };
        type.KeyDown += (_, e) => { if (e.Key == Key.Enter) Run(); };
        name.Focus();
    }
}
