// DeckDetailView.cs
// One deck's page, ported from LibraryView.swift's DeckDetailView: the
// foil nameplate, the card faces grid (click to flip, double click to
// zoom, right click for printing / replace / save / remove), copy
// decklist buttons above and below the grid, the print settings, and the
// build bar that prints the deck as arranged.

using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using ProxyPrintGenerator.Controls;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator.Views;

public sealed class DeckDetailView : UserControl
{
    private readonly Guid _deckId;
    private readonly PrintJobModel _job = new();
    private readonly Dictionary<Guid, ScryfallCard> _faces = [];
    private readonly HashSet<Guid> _flipped = [];
    private bool _facesSettled;
    private CancellationTokenSource? _loadCts;

    private readonly FoilNameplate _nameplate = new();
    private readonly OutlinedText _sideboardNote = new() { Size = 19, Wrap = true, Margin = new Thickness(10, 0, 10, 6) };
    private readonly UniformGrid _grid = new() { Columns = 4, Margin = new Thickness(0, 4, 0, 4) };
    private readonly OrnamentCaption _footer = new() { Size = 19.5, Margin = new Thickness(0, 6, 0, 0) };
    /// The holographic notice above the grid naming every two sided card.
    private readonly ContentControl _twoSidedBanner = new() { Margin = new Thickness(0, 12, 0, 0), Visibility = Visibility.Collapsed };
    private readonly Dictionary<Guid, FaceTile> _tiles = [];
    private readonly Button _tryAgain = new() { Content = "Try again", HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) };
    private string _lastEntriesSignature = "";

    private SavedDeck? Deck => DeckStore.Shared.Deck(_deckId);

    public DeckDetailView(Guid deckId)
    {
        _deckId = deckId;
        var deck = Deck;

        var back = new Button { Content = "‹  Deck Library", HorizontalAlignment = HorizontalAlignment.Left, FontSize = 17, Margin = new Thickness(16, 6, 0, 0) };
        back.SetResourceReference(StyleProperty, "LeatherButton");
        back.Click += (_, _) => MainWindow.Instance.ShowLibrary();

        _nameplate.DeckName = deck?.Name ?? "";
        _nameplate.Committed += name =>
        {
            var t = name.Trim();
            if (t.Length > 0 && Deck != null && t != Deck.Name) DeckStore.Shared.Rename(_deckId, t);
        };

        var edit = EditButton();
        edit.Click += (_, _) => DeckEditorSheet.Show(_deckId);
        edit.Margin = new Thickness(8, 4, 8, 4);
        var copyTop = CopyDecklistButton();
        copyTop.Margin = new Thickness(8, 4, 8, 4);
        var tools = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center };
        tools.Children.Add(edit);
        tools.Children.Add(copyTop);

        // One bubble for the deck's tools: the edit and copy decklist
        // buttons and, when the deck has any, the two sided cards, on the
        // holographic plaque in the masthead's tooled leather.
        var bubbleStack = new StackPanel { Margin = new Thickness(14, 14, 14, 14) };
        bubbleStack.Children.Add(tools);
        bubbleStack.Children.Add(_twoSidedBanner);
        var plaque = new Grid();
        plaque.Children.Add(new WashPlaque(18));
        plaque.Children.Add(bubbleStack);
        var bubble = new TooledLeatherFrame { Child = plaque, Margin = new Thickness(16, 6, 16, 14) };

        _tryAgain.SetResourceReference(StyleProperty, "LeatherButton");
        _tryAgain.Click += (_, _) => _ = LoadFacesAsync();

        var settings = new PrintSettingsPanel { DataContext = _job, Margin = new Thickness(22, 0, 22, 0) };

        var delete = new Button { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 22, 0, 18) };
        delete.SetResourceReference(StyleProperty, "PlainButton");
        delete.Content = new OutlinedText { Text = "DELETE THIS DECK", Size = 20 };
        System.Windows.Automation.AutomationProperties.SetName(delete, "Delete this deck");
        delete.Click += (_, _) => { if (Deck is { } d) LibraryView.ConfirmDelete(d, MainWindow.Instance.ShowLibrary); };

        var stack = new StackPanel();
        stack.Children.Add(back);
        stack.Children.Add(_nameplate);
        stack.Children.Add(_sideboardNote);
        stack.Children.Add(bubble);
        var gridHost = new Border { Margin = new Thickness(14, 0, 14, 0), Child = _grid };
        gridHost.SizeChanged += (_, e) => _grid.Columns = Math.Min(6, Math.Max(2, (int)(e.NewSize.Width / 245)));
        stack.Children.Add(gridHost);
        stack.Children.Add(_footer);
        stack.Children.Add(_tryAgain);
        // The same copy button again under the cards, so a long deck does
        // not need scrolling back up.
        var copyBottom = CopyDecklistButton();
        copyBottom.Margin = new Thickness(0, 16, 0, 22);
        stack.Children.Add(copyBottom);
        stack.Children.Add(settings);
        stack.Children.Add(delete);

        var bar = new BuildBar { DataContext = _job, HasOptionsDrawer = true };
        bar.BeforeBuild += SyncJob;
        Content = new PanelScaffold
        {
            Bar = bar,
            Content = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(0, 0, 6, 0) },
        };

        if (deck != null) _job.OutputName = deck.Name.Replace(' ', '-').ToLowerInvariant();
        _job.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(PrintJobModel.BackToBack) && Deck is { } d) RebuildTwoSidedBanner(d); };
        DeckStore.Shared.Changed += OnStoreChanged;
        Unloaded += (_, _) => { DeckStore.Shared.Changed -= OnStoreChanged; _loadCts?.Cancel(); };
        Loaded += (_, _) => { DeckStore.Shared.Changed -= OnStoreChanged; DeckStore.Shared.Changed += OnStoreChanged; };
        SyncJob();
        RefreshHeader();
        RebuildGrid();
        _ = LoadFacesAsync();
    }

    private void OnStoreChanged()
    {
        if (Deck == null) return;
        SyncJob();
        RefreshHeader();
        var sig = Signature(Deck);
        if (sig != _lastEntriesSignature) _ = LoadFacesAsync();
        else RebuildGrid();
    }

    private static string Signature(SavedDeck d)
        => string.Join(";", d.Entries.Where(e => e.Board == "main").Select(e => $"{e.Id}|{e.Name}|{e.SetCode}|{e.CollectorNumber}"));

    private void SyncJob()
    {
        if (Deck is not { } deck) return;
        _job.DeckText = DeckStore.DeckText(deck);
        _job.TwoSidedHint = deck.Entries.Count(e => _faces.TryGetValue(e.Id, out var f) && f.HasBackFace);
    }

    private void RefreshHeader()
    {
        if (Deck is not { } deck) return;
        _nameplate.Subtitle = $"{deck.CardCount} cards · from {deck.Source}";
        if (!_nameplate.IsKeyboardFocusWithin) _nameplate.DeckName = deck.Name;
        _sideboardNote.Text = deck.SideboardCount > 0
            ? $"{deck.SideboardCount} sideboard and maybeboard cards ride along in the list; printing swaps below cover the mainboard."
            : "";
        _sideboardNote.Visibility = deck.SideboardCount > 0 ? Visibility.Visible : Visibility.Collapsed;
        var total = deck.Entries.Count(e => e.Board == "main");
        var loaded = deck.Entries.Count(e => e.Board == "main" && _faces.ContainsKey(e.Id));
        const string hint = "Click any card to flip it. Two sided cards glow gold and show their real back. Double click to zoom, right click for more.";
        _footer.Text = loaded < total
            ? (_facesSettled ? $"{total - loaded} cards could not be matched to a printing. {hint}" : $"Loading card faces: {loaded} of {total} so far. {hint}")
            : hint;
        _tryAgain.Visibility = _facesSettled && loaded < total ? Visibility.Visible : Visibility.Collapsed;
    }

    // MARK: - Faces grid

    private void RebuildGrid()
    {
        _grid.Children.Clear();
        _tiles.Clear();
        if (Deck is not { } deck) { _twoSidedBanner.Visibility = Visibility.Collapsed; return; }
        for (var i = 0; i < deck.Entries.Count; i++)
        {
            var entry = deck.Entries[i];
            if (entry.Board != "main") continue;
            _faces.TryGetValue(entry.Id, out var option);
            _grid.Children.Add(BuildTile(i, entry, option));
        }
        RebuildTwoSidedBanner(deck);
    }

    private const string PencilIcon = "M3,17.25 V21 H6.75 L17.81,9.94 L14.06,6.19 Z M20.71,7.04 C21.1,6.65 21.1,6.02 20.71,5.63 L18.37,3.29 C17.98,2.9 17.35,2.9 16.96,3.29 L15.13,5.12 L18.88,8.87 Z";
    private const string CopyIcon = "M16,1 H4 C2.9,1 2,1.9 2,3 V17 H4 V3 H16 Z M19,5 H8 C6.9,5 6,5.9 6,7 V21 C6,22.1 6.9,23 8,23 H19 C20.1,23 21,22.1 21,21 V7 C21,5.9 20.1,5 19,5 Z M19,21 H8 V7 H19 Z";
    private const string CheckIcon = "M9,16.17 L4.83,12 L3.41,13.41 L9,19 L21,7 L19.59,5.59 Z";

    private static Button EditButton() => PillButton(PencilIcon, "EDIT THIS DECK", "Add, remove or change the cards in this deck", "Edit this deck", out _, out _);

    /// Copies the whole list, sideboard and all, as "4 Plains (TRK) 361"
    /// lines, then says so on the button for a moment.
    private Button CopyDecklistButton()
    {
        var button = PillButton(CopyIcon, "COPY DECKLIST",
            "Copy every card with its printing, like \"1 Plains (TRK) 361\", ready to paste anywhere",
            "Copy decklist", out var label, out var icon);
        DispatcherTimer? reset = null;
        button.Click += (_, _) =>
        {
            if (Deck is not { } deck) return;
            var text = DeckStore.ExportText(deck, _faces);
            try { Clipboard.SetText(text); }
            catch (Exception ex)
            {
                MessageBox.Show(MainWindow.Instance, $"Could not copy to the clipboard: {ex.Message}", "Copy decklist");
                return;
            }
            // Hold the pill's width so the shorter confirmation does not
            // make the row jump.
            if (button.Content is FrameworkElement pill) pill.MinWidth = pill.ActualWidth;
            var count = deck.Entries.Sum(e => e.Quantity);
            label.Text = $"COPIED {count} CARD{(count == 1 ? "" : "S")}";
            icon.Data = Geometry.Parse(CheckIcon);
            reset?.Stop();
            var timer = reset = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                label.Text = "COPY DECKLIST";
                icon.Data = Geometry.Parse(CopyIcon);
            };
            timer.Start();
        };
        return button;
    }

    /// A plain, unmistakable button: a dark leather pill with a gold rim,
    /// an icon and gold lettering, that lights up under the pointer.
    private static Button PillButton(string iconData, string text, string tooltip, string automationName,
        out OutlinedText label, out System.Windows.Shapes.Path icon)
    {
        var gold = Color.FromRgb(0xF6, 0xE0, 0xA4);
        var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        icon = new System.Windows.Shapes.Path
        {
            Data = Geometry.Parse(iconData),
            Fill = Theme.Brush(gold), Stroke = Brushes.Black, StrokeThickness = 0.8,
            Width = 24, Height = 24, Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0),
        };
        row.Children.Add(icon);
        label = new OutlinedText { Text = text, Size = 27, Readable = true, BlackOutline = true, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(label);

        var rim = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1) };
        rim.GradientStops.Add(new GradientStop(Color.FromRgb(250, 222, 128), 0));
        rim.GradientStops.Add(new GradientStop(Color.FromRgb(140, 97, 31), 1));
        var restShadow = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 6, ShadowDepth = 2, Opacity = 0.6 };
        var hoverGlow = new System.Windows.Media.Effects.DropShadowEffect { Color = Color.FromRgb(255, 240, 192), BlurRadius = 20, ShadowDepth = 0, Opacity = 0.95 };
        var pill = new Border
        {
            CornerRadius = new CornerRadius(999), Padding = new Thickness(30, 9, 34, 11), BorderBrush = rim, BorderThickness = new Thickness(2.5),
            Background = new LinearGradientBrush(Theme.LeatherLight, Theme.LeatherDeep, 90), Child = row, Effect = restShadow,
        };
        var button = new Button
        {
            Content = pill, HorizontalAlignment = HorizontalAlignment.Center, Cursor = Cursors.Hand,
            ToolTip = tooltip,
        };
        button.SetResourceReference(StyleProperty, "PlainButton");
        System.Windows.Automation.AutomationProperties.SetName(button, automationName);
        button.MouseEnter += (_, _) => { pill.BorderBrush = Theme.Brush(Color.FromRgb(255, 240, 192)); pill.Effect = hoverGlow; };
        button.MouseLeave += (_, _) => { pill.BorderBrush = rim; pill.Effect = restShadow; };
        button.PreviewMouseLeftButtonDown += (_, _) => pill.Opacity = 0.8;
        button.PreviewMouseLeftButtonUp += (_, _) => pill.Opacity = 1;
        return button;
    }

    /// The two sided part of the bubble: how many, each by name (a name
    /// jumps to its card and flips it), and how to print them as one piece.
    private void RebuildTwoSidedBanner(SavedDeck deck)
    {
        var twoSided = deck.Entries.Where(e => e.Board == "main" && _faces.TryGetValue(e.Id, out var f) && f.HasBackFace).ToList();
        if (twoSided.Count == 0) { _twoSidedBanner.Visibility = Visibility.Collapsed; _twoSidedBanner.Content = null; return; }

        var copies = twoSided.Sum(e => e.Quantity);
        var content = new StackPanel();
        // A thin gold rule between the edit button and the two sided cards.
        content.Children.Add(new Border { Height = 2, Margin = new Thickness(40, 0, 40, 10), Background = Theme.Brush(Theme.Gold, 0.85) });
        content.Children.Add(new OutlinedText
        {
            Text = copies == twoSided.Count
                ? $"{copies} TWO SIDED CARD{(copies == 1 ? "" : "S")} IN THIS DECK"
                : $"{copies} TWO SIDED CARDS IN THIS DECK ({twoSided.Count} DIFFERENT)",
            Size = 20, Readable = true, BlackOutline = true, Wrap = true, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Stretch,
        });
        var names = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 4, 0, 0) };
        foreach (var entry in twoSided)
        {
            var label = entry.Quantity > 1 ? $"{entry.Name} ×{entry.Quantity}" : entry.Name;
            var chip = new Button { Margin = new Thickness(4, 3, 4, 3), Cursor = Cursors.Hand, ToolTip = $"Show {entry.Name} and flip it over" };
            chip.SetResourceReference(StyleProperty, "PlainButton");
            chip.Content = new Border
            {
                CornerRadius = new CornerRadius(999), Background = Theme.Brush(Colors.Black, 0.55), Padding = new Thickness(10, 2, 10, 3),
                BorderBrush = Theme.Brush(Theme.Gold), BorderThickness = new Thickness(1.2),
                Child = new OutlinedText { Text = label, Size = 15, Readable = true, BlackOutline = true },
            };
            System.Windows.Automation.AutomationProperties.SetName(chip, $"Show {entry.Name}");
            chip.Click += (_, _) =>
            {
                if (!_tiles.TryGetValue(entry.Id, out var tile)) return;
                tile.BringIntoView();
                if (!tile.IsFlipped) tile.Flip();
                tile.Pulse();
            };
            names.Children.Add(chip);
        }
        content.Children.Add(names);
        if (!_job.BackToBack)
            content.Children.Add(new OutlinedText
            {
                Text = "Turn on \"Two sided cards back to back\" below to print each one as a single piece.",
                Size = 16, Readable = true, BlackOutline = true, Wrap = true, TextAlignment = TextAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 6, 0, 0),
            });

        _twoSidedBanner.Content = content;
        _twoSidedBanner.Visibility = Visibility.Visible;
    }

    private FrameworkElement BuildTile(int index, SavedCardLine entry, ScryfallCard? option)
    {
        var tile = new FaceTile(entry, option, _flipped.Contains(entry.Id));
        _tiles[entry.Id] = tile;
        tile.Flipped += f => { if (f) _flipped.Add(entry.Id); else _flipped.Remove(entry.Id); };
        tile.ZoomRequested += () => CardZoomSheet.Show(_deckId, index, () => _faces.GetValueOrDefault(entry.Id));

        var cm = new ContextMenu();
        void Item(string header, Action act)
        {
            var mi = new MenuItem { Header = header };
            mi.Click += (_, _) => act();
            cm.Items.Add(mi);
        }
        Item("Change printing", () => PrintingPickerSheet.Show(_deckId, index));
        Item("Flip card", tile.Flip);
        Item("Save card as JPEG…", () => _ = SaveJpegAsync(entry, tile.DisplayedImageUrl));
        Item("Replace card…", () => CardSearchSheet.ShowReplace(_deckId, index, entry.Name));
        if (entry.CanRevertReplacement)
            Item($"Change back to {entry.PreviousName}", () => DeckStore.Shared.RevertReplacement(_deckId, index));
        cm.Items.Add(new Separator());
        Item("View larger", () => CardZoomSheet.Show(_deckId, index, () => _faces.GetValueOrDefault(entry.Id)));
        cm.Items.Add(new Separator());
        Item("Remove from deck", () => DeckStore.Shared.RemoveCard(_deckId, index));
        tile.ContextMenu = cm;
        return tile;
    }

    private static async Task SaveJpegAsync(SavedCardLine entry, string? url)
    {
        if (url == null) { MessageBox.Show(MainWindow.Instance, "That card has no image loaded yet.", "Save card"); return; }
        var data = await CardImages.GetBytesAsync(url);
        if (data == null) { MessageBox.Show(MainWindow.Instance, "Could not fetch that card image.", "Save card"); return; }
        var dlg = new SaveFileDialog
        {
            FileName = string.Concat(entry.Name.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '-' : c)) + ".jpg",
            Filter = "JPEG image (*.jpg)|*.jpg",
        };
        if (dlg.ShowDialog(MainWindow.Instance) != true) return;
        using var ms = new MemoryStream(data);
        var frame = BitmapFrame.Create(ms, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        var enc = new JpegBitmapEncoder { QualityLevel = 92 };
        enc.Frames.Add(BitmapFrame.Create(new FormatConvertedBitmap(frame, PixelFormats.Bgr24, null, 0)));
        using var fs = File.Create(dlg.FileName);
        enc.Save(fs);
    }

    // MARK: - Loading faces

    /// Exact printings resolve in batched collection requests; everything
    /// else (bare names, unmatched identifiers) resolves by name, the same
    /// way the print engine does, so what shows is what will print.
    private async Task LoadFacesAsync()
    {
        _loadCts?.Cancel();
        var cts = _loadCts = new CancellationTokenSource();
        var ct = cts.Token;
        _facesSettled = false;
        if (Deck is not { } deck) return;
        _lastEntriesSignature = Signature(deck);
        var main = deck.Entries.Where(e => e.Board == "main").ToList();
        var loaded = new Dictionary<Guid, ScryfallCard>();
        void Publish()
        {
            if (ct.IsCancellationRequested) return;
            _faces.Clear();
            foreach (var (k, v) in loaded) _faces[k] = v;
            SyncJob();
            RefreshHeader();
            RebuildGrid();
        }
        Publish();

        try
        {
            // Pass 1: exact printings, batched.
            var exact = main.Where(e => e.SetCode != null && e.CollectorNumber != null)
                .Select(e => new PrintingKey(e.SetCode!, e.CollectorNumber!)).Distinct().ToList();
            if (exact.Count > 0)
            {
                var fetched = await ScryfallClient.LookupPrintingsAsync(exact, false, ct);
                foreach (var e in main)
                    if (e.SetCode != null && e.CollectorNumber != null && fetched.TryGetValue(new PrintingKey(e.SetCode, e.CollectorNumber), out var o))
                        loaded[e.Id] = o;
                Publish();
            }

            // Pass 2: bare names, in a few OR searches. Lines that name a set
            // ("Flare of Fortitude [SDS]") skip this set-blind batch and go
            // to the per card lookup below, which asks for that set first,
            // the same way the print engine does, so preview and print agree.
            var missing = main.Where(e => !loaded.ContainsKey(e.Id) && e.SetCode == null).ToList();
            if (missing.Count > 0)
            {
                try
                {
                    var byName = await ScryfallClient.ResolveByNamesAsync(missing.Select(m => m.Name).Distinct().ToList(), ct);
                    foreach (var e in missing)
                        if (byName.TryGetValue(e.Name, out var o)) loaded[e.Id] = o;
                    Publish();
                }
                catch (OperationCanceledException) { throw; }
                catch { /* fall through to the per card backstop */ }
            }

            // Backstop: per card named lookup, then the printing search.
            foreach (var e in main.Where(e => !loaded.ContainsKey(e.Id)).ToList())
            {
                ct.ThrowIfCancellationRequested();
                ScryfallCard? card = null;
                try { card = await ScryfallClient.LookupNamedAsync(e.Name, e.SetCode, ct, 2); } catch (OperationCanceledException) { throw; } catch { }
                if (card == null && e.SetCode != null)
                    try { card = await ScryfallClient.LookupNamedAsync(e.Name, null, ct, 2); } catch (OperationCanceledException) { throw; } catch { }
                if (card == null)
                    try
                    {
                        var prints = await ScryfallClient.AllPrintingsAsync(e.Name, ct);
                        card = prints.FirstOrDefault(p => p.Set == e.SetCode) ?? prints.FirstOrDefault();
                    }
                    catch (OperationCanceledException) { throw; }
                    catch { }
                if (card != null) { loaded[e.Id] = card; Publish(); }
            }
        }
        catch (OperationCanceledException) { return; }
        catch { /* settle with what loaded */ }

        if (ct.IsCancellationRequested) return;
        _facesSettled = true;
        Publish();
    }
}

/// One card face in the grid: the front at preview size, the back (the
/// real back face, or the classic card back) loaded on first flip.
public sealed class FaceTile : Grid
{
    private readonly SavedCardLine _entry;
    private readonly ScryfallCard? _option;
    private readonly Image _image = new() { Stretch = Stretch.Uniform };
    private readonly ScaleTransform _flipScale = new(1, 1);
    private readonly Border _cardHost;
    private bool _flipped;
    private OutlinedText? _flipLine;

    public bool IsFlipped => _flipped;

    public event Action<bool>? Flipped;
    public event Action? ZoomRequested;

    public string? DisplayedImageUrl => _flipped
        ? (_option?.HasBackFace == true ? _option.FaceImageUrl(1) : ScryfallClient.CardBackImageUrl)
        : _option?.FaceImageUrl(0);

    public FaceTile(SavedCardLine entry, ScryfallCard? option, bool flipped)
    {
        _entry = entry; _option = option; _flipped = flipped;
        Margin = new Thickness(4);
        Cursor = Cursors.Hand;
        ToolTip = $"{entry.Name}\n{entry.PrintingLabel}";

        var placeholder = new Border
        {
            CornerRadius = new CornerRadius(8), Background = Theme.Brush(Colors.Black, 0.15),
            Child = new TextBlock { Text = entry.Name, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, FontSize = 14,
                Foreground = Theme.Brush(Theme.Ink), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6) },
        };
        var faceGrid = new Grid();
        faceGrid.Children.Add(placeholder);
        faceGrid.Children.Add(_image);
        _cardHost = new Border
        {
            Child = faceGrid, RenderTransform = _flipScale, RenderTransformOrigin = new Point(0.5, 0.5),
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 8, ShadowDepth = 2, Opacity = 0.45 },
        };
        _image.SizeChanged += (_, e) => _image.Clip = new RectangleGeometry(new Rect(e.NewSize), e.NewSize.Width * 0.045, e.NewSize.Width * 0.045);
        Children.Add(_cardHost);

        if (entry.IsAltPrinting) Children.Add(Badge("ALT", Color.FromArgb(217, 255, 140, 0), Colors.Black, HorizontalAlignment.Left, VerticalAlignment.Top));
        if (entry.Quantity > 1) Children.Add(Badge($"×{entry.Quantity}", Color.FromArgb(200, 28, 18, 10), Theme.Parchment, HorizontalAlignment.Right, VerticalAlignment.Top));
        if (option?.HasBackFace == true)
        {
            // A gold glow marks the card out from across the grid, and the
            // holographic badge says what it is in letters you can read.
            _cardHost.Effect = new System.Windows.Media.Effects.DropShadowEffect { Color = Color.FromRgb(255, 210, 90), BlurRadius = 26, ShadowDepth = 0, Opacity = 1 };
            // A solid gold frame just outside the card's edge.
            var frameBrush = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
            frameBrush.GradientStops.Add(new GradientStop(Color.FromRgb(255, 236, 160), 0));
            frameBrush.GradientStops.Add(new GradientStop(Theme.Gold, 0.5));
            frameBrush.GradientStops.Add(new GradientStop(Color.FromRgb(255, 226, 130), 1));
            var frame = new Border { BorderBrush = frameBrush, BorderThickness = new Thickness(4), Margin = new Thickness(-4), IsHitTestVisible = false };
            SizeChanged += (_, e) => frame.CornerRadius = new CornerRadius(e.NewSize.Width * 0.05 + 4);
            Children.Add(frame);
            Children.Add(TwoSidedBadge());
            ToolTip = $"{entry.Name}\n{entry.PrintingLabel}\nTwo sided: click to flip it over.";
        }

        SizeChanged += (_, e) => { if (e.WidthChanged) Height = e.NewSize.Width * 88.0 / 63.0; };
        MouseLeftButtonUp += (_, e) => { if (_pendingClick) Flip(); _pendingClick = false; };
        MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2) { _pendingClick = false; ZoomRequested?.Invoke(); e.Handled = true; }
            else _pendingClick = true;
        };
        _ = ShowCurrentAsync();
    }

    private bool _pendingClick;

    private FrameworkElement TwoSidedBadge()
    {
        var text = new StackPanel { Margin = new Thickness(14, 6, 14, 8) };
        text.Children.Add(new OutlinedText { Text = "TWO SIDED", Size = 24, Readable = true, BlackOutline = true, HorizontalAlignment = HorizontalAlignment.Center });
        _flipLine = new OutlinedText { Text = FlipLineText, Size = 19, Readable = true, BlackOutline = true, HorizontalAlignment = HorizontalAlignment.Center };
        text.Children.Add(_flipLine);
        var badge = new Grid
        {
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(6, 0, 6, 10),
            IsHitTestVisible = false,
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 8, ShadowDepth = 2, Opacity = 0.6 },
        };
        badge.Children.Add(new WashPlaque(18));
        badge.Children.Add(text);
        return badge;
    }

    private string FlipLineText => _flipped ? "click to flip back" : "click to flip";

    /// A quick grow and settle, to show which card a banner name points at.
    public void Pulse()
    {
        var scale = new ScaleTransform(1, 1);
        RenderTransformOrigin = new Point(0.5, 0.5);
        RenderTransform = scale;
        var grow = new DoubleAnimation(1, 1.08, TimeSpan.FromMilliseconds(220)) { AutoReverse = true, RepeatBehavior = new RepeatBehavior(2), EasingFunction = new QuadraticEase() };
        scale.BeginAnimation(ScaleTransform.ScaleXProperty, grow);
        scale.BeginAnimation(ScaleTransform.ScaleYProperty, grow);
        Panel.SetZIndex(this, 10);
    }

    private static Border Badge(string text, Color bg, Color fg, HorizontalAlignment h, VerticalAlignment v) => new()
    {
        CornerRadius = new CornerRadius(999), Background = new SolidColorBrush(bg), Padding = new Thickness(7, 2, 7, 3),
        Margin = new Thickness(6), HorizontalAlignment = h, VerticalAlignment = v, IsHitTestVisible = false,
        Child = new TextBlock { Text = text, FontFamily = new FontFamily("Segoe UI"), FontWeight = FontWeights.Bold, FontSize = 12, Foreground = new SolidColorBrush(fg) },
    };

    private async Task ShowCurrentAsync()
    {
        var url = _flipped
            ? (_option?.HasBackFace == true ? _option.FaceImageUrl(1, FaceImageQuality.Normal) : ScryfallClient.CardBackImageUrl)
            : _option?.FaceImageUrl(0, FaceImageQuality.Normal);
        var flippedAtStart = _flipped;
        var img = await CardImages.GetAsync(url, 488);
        if (flippedAtStart == _flipped) _image.Source = img;
    }

    /// The card flip: squash to an edge, swap the face, open back out.
    public void Flip()
    {
        _flipped = !_flipped;
        Flipped?.Invoke(_flipped);
        if (_flipLine != null) _flipLine.Text = FlipLineText;
        var close = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(170)) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn } };
        close.Completed += async (_, _) =>
        {
            _image.Source = null;
            var load = ShowCurrentAsync();
            _flipScale.BeginAnimation(ScaleTransform.ScaleXProperty,
                new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(170)) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } });
            await load;
        };
        _flipScale.BeginAnimation(ScaleTransform.ScaleXProperty, close);
    }
}
