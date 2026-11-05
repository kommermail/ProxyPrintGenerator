// DeckDetailView.cs
// One deck's page, ported from LibraryView.swift's DeckDetailView: the
// foil nameplate, the card faces grid (click to flip, double click to
// zoom, right click for printing / replace / save / remove), the print
// settings, and the build bar that prints the deck as arranged.

using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
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

        var edit = new Button { Margin = new Thickness(20, 6, 20, 6) };
        edit.SetResourceReference(StyleProperty, "PlaqueButton");
        var editContent = new StackPanel { Orientation = Orientation.Horizontal };
        editContent.Children.Add(new System.Windows.Shapes.Path
        {
            Data = Geometry.Parse("M3,17.25 V21 H6.75 L17.81,9.94 L14.06,6.19 Z M20.71,7.04 C21.1,6.65 21.1,6.02 20.71,5.63 L18.37,3.29 C17.98,2.9 17.35,2.9 16.96,3.29 L15.13,5.12 L18.88,8.87 Z"),
            Fill = Theme.Brush(Theme.Ink), Width = 22, Height = 22, Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 9, 0),
        });
        editContent.Children.Add(new OutlinedText { Text = "EDIT THIS DECK", Size = 26, PlaqueStyle = true, VerticalAlignment = VerticalAlignment.Center });
        edit.Content = editContent;
        System.Windows.Automation.AutomationProperties.SetName(edit, "Edit this deck");
        edit.Click += (_, _) => DeckEditorSheet.Show(_deckId);

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
        stack.Children.Add(edit);
        stack.Children.Add(new SpectacularHeader { Title = "Cards" });
        var gridHost = new Border { Margin = new Thickness(14, 0, 14, 0), Child = _grid };
        gridHost.SizeChanged += (_, e) => _grid.Columns = Math.Min(6, Math.Max(2, (int)(e.NewSize.Width / 245)));
        stack.Children.Add(gridHost);
        stack.Children.Add(_footer);
        stack.Children.Add(_tryAgain);
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
        const string hint = "Click any card to flip it: two sided cards show their real back. Double click to zoom, right click for more.";
        _footer.Text = loaded < total
            ? (_facesSettled ? $"{total - loaded} cards could not be matched to a printing. {hint}" : $"Loading card faces: {loaded} of {total} so far. {hint}")
            : hint;
        _tryAgain.Visibility = _facesSettled && loaded < total ? Visibility.Visible : Visibility.Collapsed;
    }

    // MARK: - Faces grid

    private void RebuildGrid()
    {
        _grid.Children.Clear();
        if (Deck is not { } deck) return;
        for (var i = 0; i < deck.Entries.Count; i++)
        {
            var entry = deck.Entries[i];
            if (entry.Board != "main") continue;
            _faces.TryGetValue(entry.Id, out var option);
            _grid.Children.Add(BuildTile(i, entry, option));
        }
    }

    private FrameworkElement BuildTile(int index, SavedCardLine entry, ScryfallCard? option)
    {
        var tile = new FaceTile(entry, option, _flipped.Contains(entry.Id));
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

            // Pass 2: everything missing, by name, in a few OR searches.
            var missing = main.Where(e => !loaded.ContainsKey(e.Id)).ToList();
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
        if (option?.HasBackFace == true) Children.Add(Badge("⟲ Tap to flip!", Color.FromArgb(140, 0, 0, 0), Colors.White, HorizontalAlignment.Center, VerticalAlignment.Bottom));

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
