// DeckTextEditor.cs
// "Edit this deck": the deck as list text, like a bulk editor. Lines cut,
// copy and paste like any text, on the suede of the paste sheet, with
// gold rules between the cards. Ctrl+F finds lines; the box beside a line
// or Ctrl+click checks it, and checked lines can be deleted together or
// replaced by pasted lines or a card from the search. As you type, every
// card is checked against Scryfall: one it can't find gets a red jagged
// underline and an arrow with a note at the end of its line. Nothing in
// the deck changes until Save.

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using ProxyPrintGenerator.Controls;
using ProxyPrintGenerator.Engine;

namespace ProxyPrintGenerator.Views;

public static class DeckEditorSheet
{
    public static void Show(Guid deckId)
    {
        if (DeckStore.Shared.Deck(deckId) is { } deck) new DeckTextEditor(deck).Open();
    }
}

internal enum LineKind { Blank, Header, Card, Unreadable }

/// What's wrong with a line: the span to underline, the note, and
/// whether it is an error (red) or a heads up (amber).
internal sealed record LineIssue(int Start, int Length, string Message, bool Severe);

internal sealed class DeckTextEditor
{
    private readonly Guid _deckId;
    private readonly string _deckName;
    private string _saved;

    private readonly TextBox _box = new() { IsInactiveSelectionHighlightEnabled = true, Padding = new Thickness(10, 6, 10, 6) };
    private TextBox _find = null!;
    private readonly TextBlock _findCount = new() { FontFamily = Theme.Fell, FontSize = 16, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0), MinWidth = 70 };
    private readonly TextBlock _status = new() { FontFamily = Theme.Fell, FontSize = 16, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
    private readonly Button _checkMatches = SheetParts.Leather("Check matches", 15);
    private readonly Button _replace = SheetParts.Leather("Replace checked ▾", 15);
    private readonly Button _delete = SheetParts.Leather("Delete checked", 15);
    private readonly Button _clear = SheetParts.Leather("Uncheck all", 15);
    private readonly LineLayer _back, _front;
    private readonly CheckGutter _gutter;

    private string[] _lines = [];
    private LineKind[] _kinds = [];
    private DeckEntry?[] _entries = [];
    private List<bool> _checked = [];
    private HashSet<int> _matches = [];
    private readonly Dictionary<int, LineIssue> _issues = [];

    // What Scryfall said, kept across edits so only new names are asked.
    private readonly Dictionary<string, bool> _knownNames = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<PrintingKey, string?> _printings = [];
    private readonly DispatcherTimer _debounce = new() { Interval = TimeSpan.FromMilliseconds(700) };
    private CancellationTokenSource? _checkCts;
    private bool _checking;
    private string? _checkError;
    private Action _close = () => { };

    public DeckTextEditor(SavedDeck deck)
    {
        _deckId = deck.Id;
        _deckName = deck.Name;
        _saved = Normalize(DeckStore.EditorText(deck));
        _back = new LineLayer(this, front: false);
        _front = new LineLayer(this, front: true);
        _gutter = new CheckGutter(this);
    }

    private static string Normalize(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n').Replace("\n", "\r\n");
    private bool IsDirty => Normalize(_box.Text) != _saved;

    // MARK: - Layout

    public void Open()
    {
        // Find, and what to do with checked lines.
        _find = SheetParts.Field("Find (Ctrl+F)", out var findHost);
        System.Windows.Automation.AutomationProperties.SetName(_find, "Find lines");
        System.Windows.Automation.AutomationProperties.SetName(_box, "Deck list");
        findHost.Width = 250;
        findHost.Margin = new Thickness(0);
        var findRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        findRow.Children.Add(findHost);
        findRow.Children.Add(_findCount);
        _checkMatches.Margin = new Thickness(6, 0, 0, 0);
        _checkMatches.ToolTip = "Tick every line that matches the search";
        findRow.Children.Add(_checkMatches);

        var add = SheetParts.Leather("＋ Add a card", 15);
        add.ToolTip = "Search Scryfall and add a line for the card";
        var tools = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, 0, 8) };
        foreach (var b in new[] { _replace, _delete, _clear, add }) { b.Margin = new Thickness(6, 0, 0, 0); tools.Children.Add(b); }
        _replace.ToolTip = "Swap the checked lines for pasted lines or a card from the search";

        var toolbar = new DockPanel();
        DockPanel.SetDock(findRow, Dock.Left);
        toolbar.Children.Add(findRow);
        toolbar.Children.Add(tools);

        var hint = SheetParts.Note("One card per line, like 4 Llanowar Elves (M19) 314. Cut, copy and paste lines like any text. " +
                                   "Tick the box beside a line, or Ctrl+click it, to check it.", 15, 0.75);
        hint.Margin = new Thickness(0, 0, 0, 8);

        // The list: suede behind, the row bands, the text, then the notes.
        _box.SetResourceReference(FrameworkElement.StyleProperty, "SuedeEditor");
        var suede = new Border { CornerRadius = new CornerRadius(8), Background = _box.Background };
        _box.Background = Brushes.Transparent;
        var editor = new Grid();
        editor.Children.Add(suede);
        editor.Children.Add(_back);
        editor.Children.Add(_box);
        editor.Children.Add(_front);
        var listArea = new Grid();
        listArea.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        listArea.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(editor, 1);
        listArea.Children.Add(_gutter);
        listArea.Children.Add(editor);

        var save = SheetParts.Gold("Save changes", 19);
        var cancel = SheetParts.Leather("Cancel", 17);
        cancel.Padding = new Thickness(18, 8, 18, 8);
        cancel.Margin = new Thickness(0, 0, 10, 0);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(cancel);
        buttons.Children.Add(save);
        var footer = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(buttons, Dock.Right);
        footer.Children.Add(buttons);
        footer.Children.Add(_status);

        var body = new DockPanel();
        DockPanel.SetDock(toolbar, Dock.Top);
        DockPanel.SetDock(hint, Dock.Top);
        DockPanel.SetDock(footer, Dock.Bottom);
        body.Children.Add(toolbar);
        body.Children.Add(hint);
        body.Children.Add(footer);
        body.Children.Add(listArea);

        // Wiring.
        _box.TextChanged += (_, _) => OnTextChanged();
        _box.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler((_, _) => Redraw()));
        _box.SizeChanged += (_, _) => Redraw();
        _box.PreviewMouseLeftButtonDown += (_, e) =>
        {
            if (!Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) return;
            var at = _box.GetCharacterIndexFromPoint(e.GetPosition(_box), true);
            if (at < 0) return;
            ToggleCheck(_box.GetLineIndexFromCharacterIndex(at));
            e.Handled = true;
        };
        _find.TextChanged += (_, _) => { FindMatches(); Redraw(); };
        _find.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            NextMatch(Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? -1 : 1);
            e.Handled = true;
        };
        body.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.F && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { _find.Focus(); _find.SelectAll(); e.Handled = true; }
            else if (e.Key == Key.F3) { NextMatch(Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? -1 : 1); e.Handled = true; }
        };
        _checkMatches.Click += (_, _) => { foreach (var i in _matches) _checked[i] = true; Refresh(); };
        _delete.Click += (_, _) => DeleteChecked();
        _clear.Click += (_, _) => { for (var i = 0; i < _checked.Count; i++) _checked[i] = false; Refresh(); };
        _replace.Click += (_, _) => ReplaceMenu().IsOpen = true;
        add.Click += (_, _) => CardSearchSheet.ShowAddPick((card, qty) => InsertCardLine($"{qty} {CardLine(card)}"));
        _debounce.Tick += (_, _) => { _debounce.Stop(); _ = CheckCardsAsync(); };
        save.Click += (_, _) => { if (TrySave()) { _close(); } };
        cancel.Click += (_, _) => _close();
        body.Unloaded += (_, _) => { _debounce.Stop(); _checkCts?.Cancel(); };

        _box.Text = _saved;
        _close = MainWindow.Instance.ShowSheet($"Edit {_deckName}", body, 1060, canClose: CanClose);
        _box.Focus();
        _box.CaretIndex = 0;
        _debounce.Stop();
        _ = CheckCardsAsync();
    }

    private static string CardLine(ScryfallCard card) => $"{card.Name} ({card.Set.ToUpperInvariant()}) {card.CollectorNumber}";

    // MARK: - Lines

    private void OnTextChanged()
    {
        var fresh = _box.Text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        _checked = CarryChecks(_lines, _checked, fresh);
        _lines = fresh;
        _kinds = new LineKind[fresh.Length];
        _entries = new DeckEntry?[fresh.Length];
        for (var i = 0; i < fresh.Length; i++) _kinds[i] = Classify(fresh[i], out _entries[i]);
        FindMatches();
        ComputeIssues();
        _debounce.Stop();
        _debounce.Start();
        Refresh();
    }

    /// Checks follow their lines: an edit inside lines keeps every check;
    /// added or removed lines keep the checks above and below them.
    private static List<bool> CarryChecks(string[] old, List<bool> checks, string[] fresh)
    {
        if (old.Length == fresh.Length) return [.. checks];
        var prefix = 0;
        while (prefix < old.Length && prefix < fresh.Length && old[prefix] == fresh[prefix]) prefix++;
        var suffix = 0;
        while (suffix < old.Length - prefix && suffix < fresh.Length - prefix && old[^(suffix + 1)] == fresh[^(suffix + 1)]) suffix++;
        var result = new List<bool>(fresh.Length);
        for (var i = 0; i < fresh.Length; i++)
            result.Add(i < prefix ? checks[i] : i >= fresh.Length - suffix && checks.Count > 0 ? checks[old.Length - (fresh.Length - i)] : false);
        return result;
    }

    internal static LineKind Classify(string line, out DeckEntry? entry)
    {
        entry = null;
        var t = line.Trim();
        if (t.Length == 0 || t.StartsWith("//") || t.StartsWith('#')) return LineKind.Blank;
        if (DeckList.IsHeader(t, out _)) return LineKind.Header;
        var parsed = DeckList.Parse(t);
        if (parsed.Entries.Count == 1) { entry = parsed.Entries[0]; return LineKind.Card; }
        return parsed.Warnings.Count > 0 ? LineKind.Unreadable : LineKind.Blank;
    }

    /// Replaces the whole text in one undoable step, then sets the checks.
    private void SetLines(List<string> lines, List<bool> checks, int caretLine)
    {
        _box.BeginChange();
        _box.SelectAll();
        _box.SelectedText = string.Join("\r\n", lines);
        _box.EndChange();
        _box.UpdateLayout();
        _checked = checks;
        var line = Math.Clamp(caretLine, 0, Math.Max(0, lines.Count - 1));
        _box.Select(StartOf(lines, line), 0);
        _box.ScrollToLine(line);
        Refresh();
    }

    /// Where a line starts in text joined with "\r\n".
    private static int StartOf(List<string> lines, int line) => lines.Take(line).Sum(l => l.Length + 2);

    private void InsertCardLine(string text)
    {
        // Into the main deck: above the first Sideboard or Maybeboard heading.
        var lines = _lines.ToList();
        var at = lines.FindIndex(l => DeckList.IsHeader(l, out var b) && b is DeckBoard.Sideboard or DeckBoard.Maybeboard);
        if (at < 0)
        {
            while (lines.Count > 0 && lines[^1].Trim().Length == 0) lines.RemoveAt(lines.Count - 1);
            at = lines.Count;
        }
        else while (at > 0 && lines[at - 1].Trim().Length == 0) at--;
        lines.Insert(at, text);
        var checks = _checked.ToList();
        checks.Insert(Math.Min(at, checks.Count), false);
        while (checks.Count < lines.Count) checks.Add(false);
        SetLines(lines, checks, at);
        _box.Select(StartOf(lines, at), text.Length);
        _box.Focus();
    }

    // MARK: - Checks

    internal void ToggleCheck(int line)
    {
        if (line < 0 || line >= _kinds.Length || _kinds[line] != LineKind.Card) return;
        _checked[line] = !_checked[line];
        Refresh();
    }

    private List<int> CheckedLines() => Enumerable.Range(0, _lines.Length).Where(i => _checked[i] && _kinds[i] == LineKind.Card).ToList();

    private void DeleteChecked()
    {
        var gone = CheckedLines();
        if (gone.Count == 0) return;
        var keep = Enumerable.Range(0, _lines.Length).Where(i => !gone.Contains(i)).ToList();
        SetLines(keep.Select(i => _lines[i]).ToList(), keep.Select(_ => false).ToList(), gone[0]);
    }

    private ContextMenu ReplaceMenu()
    {
        var menu = new ContextMenu { PlacementTarget = _replace, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        var count = CheckedLines().Count;
        void Item(string header, Action act)
        {
            var mi = new MenuItem { Header = header, IsEnabled = count > 0 };
            mi.Click += (_, _) => act();
            menu.Items.Add(mi);
        }
        Item("With a card from the search…", ReplaceWithCard);
        Item("With lines I paste…", ReplaceWithPaste);
        return menu;
    }

    /// Each checked line becomes the picked card, keeping its quantity.
    private void ReplaceWithCard()
    {
        var targets = CheckedLines();
        if (targets.Count == 0) return;
        CardSearchSheet.ShowPick($"Replace {targets.Count} checked line{(targets.Count == 1 ? "" : "s")}", card =>
        {
            var lines = _lines.ToList();
            foreach (var i in targets)
            {
                var sideboardPrefix = lines[i].TrimStart().StartsWith("SB:", StringComparison.OrdinalIgnoreCase) ? "SB: " : "";
                lines[i] = $"{sideboardPrefix}{_entries[i]?.Quantity ?? 1} {CardLine(card)}";
            }
            SetLines(lines, lines.Select(_ => false).ToList(), targets[0]);
        });
    }

    /// The checked lines go, and the pasted lines take the first one's place.
    private void ReplaceWithPaste()
    {
        var targets = CheckedLines();
        if (targets.Count == 0) return;
        var input = new TextBox { MinHeight = 220, Margin = new Thickness(0, 4, 0, 10) };
        input.SetResourceReference(FrameworkElement.StyleProperty, "SuedeEditor");
        var go = SheetParts.Gold("Replace");
        var body = new StackPanel();
        body.Children.Add(SheetParts.Note($"Paste or type the new lines. They go where the first checked line is, and the {targets.Count} checked " +
                                          $"line{(targets.Count == 1 ? " is" : "s are")} removed.", 16));
        body.Children.Add(input);
        body.Children.Add(go);
        var close = MainWindow.Instance.ShowSheet($"Replace {targets.Count} checked line{(targets.Count == 1 ? "" : "s")}", body, 760, compact: true);
        input.Focus();
        go.Click += (_, _) =>
        {
            var pasted = input.Text.Replace("\r\n", "\n").Split('\n').Select(l => l.TrimEnd()).Where(l => l.Trim().Length > 0).ToList();
            var lines = new List<string>();
            for (var i = 0; i < _lines.Length; i++)
            {
                if (i == targets[0]) lines.AddRange(pasted);
                if (!targets.Contains(i)) lines.Add(_lines[i]);
            }
            close();
            SetLines(lines, lines.Select(_ => false).ToList(), targets[0]);
        };
    }

    // MARK: - Find

    private void FindMatches()
    {
        var q = _find?.Text.Trim() ?? "";
        _matches = q.Length == 0 ? []
            : Enumerable.Range(0, _lines.Length).Where(i => _kinds[i] == LineKind.Card && _lines[i].Contains(q, StringComparison.OrdinalIgnoreCase)).ToHashSet();
        _findCount.Text = q.Length == 0 ? "" : _matches.Count == 0 ? "no match" : $"{_matches.Count} line{(_matches.Count == 1 ? "" : "s")}";
        _findCount.Foreground = Theme.Brush(_matches.Count == 0 && q.Length > 0 ? Color.FromRgb(255, 138, 122) : Theme.Parchment);
        _checkMatches.IsEnabled = _matches.Count > 0;
        _checkMatches.Content = _matches.Count > 1 ? $"Check all {_matches.Count}" : "Check matches";
    }

    /// Selects the next (or previous) matching line, wrapping around.
    private void NextMatch(int step)
    {
        if (_matches.Count == 0) return;
        var ordered = _matches.Order().ToList();
        var current = _box.GetLineIndexFromCharacterIndex(_box.SelectionStart);
        var next = step > 0
            ? ordered.FirstOrDefault(i => i > current, ordered[0])
            : ordered.LastOrDefault(i => i < current, ordered[^1]);
        _box.Select(_box.GetCharacterIndexFromLineIndex(next), _lines[next].Length);
        _box.ScrollToLine(next);
    }

    // MARK: - Checking cards with Scryfall

    private async Task CheckCardsAsync()
    {
        _checkCts?.Cancel();
        var cts = _checkCts = new CancellationTokenSource();
        var names = _entries.OfType<DeckEntry>().Select(e => e.Name).Distinct(StringComparer.OrdinalIgnoreCase)
            .Where(n => !_knownNames.ContainsKey(n)).ToList();
        var keys = _entries.OfType<DeckEntry>().Where(e => e.HasPrinting).Select(e => new PrintingKey(e.SetCode!, e.CollectorNumber!))
            .Distinct().Where(k => !_printings.ContainsKey(k)).ToList();
        if (names.Count == 0 && keys.Count == 0) return;
        _checking = true;
        _checkError = null;
        UpdateStatus();
        try
        {
            if (names.Count > 0)
            {
                var unknown = await ScryfallClient.UnknownNamesAsync(names, cts.Token);
                foreach (var n in names) _knownNames[n] = !unknown.Contains(n);
            }
            if (keys.Count > 0)
            {
                var found = await ScryfallClient.LookupPrintingsAsync(keys, false, cts.Token);
                foreach (var k in keys) _printings[k] = found.TryGetValue(k, out var card) ? card.Name : null;
            }
        }
        catch (OperationCanceledException) { return; }
        catch (Exception ex) { _checkError = ex.Message; }
        finally { if (_checkCts == cts) _checking = false; }
        ComputeIssues();
        Refresh();
    }

    private void ComputeIssues()
    {
        _issues.Clear();
        for (var i = 0; i < _lines.Length; i++)
        {
            var line = _lines[i];
            if (_kinds[i] == LineKind.Unreadable)
            {
                var lead = line.Length - line.TrimStart().Length;
                _issues[i] = new LineIssue(lead, line.Trim().Length, "can't read this line", true);
                continue;
            }
            if (_kinds[i] != LineKind.Card || _entries[i] is not { } e) continue;
            var (nameAt, nameLength) = NameSpan(line, e.Name);
            if (_knownNames.TryGetValue(e.Name, out var known) && !known)
            {
                _issues[i] = new LineIssue(nameAt, nameLength, "card can't be found", true);
                continue;
            }
            if (!e.HasPrinting || !_printings.TryGetValue(new PrintingKey(e.SetCode!, e.CollectorNumber!), out var printed)) continue;
            var label = $"({e.SetCode!.ToUpperInvariant()}) {e.CollectorNumber}";
            var (at, length) = PrintingSpan(line, nameAt + nameLength);
            if (printed == null)
                _issues[i] = new LineIssue(at, length, $"printing {label} not found, so another printing will print", false);
            else if (!SameCard(printed, e.Name))
                _issues[i] = new LineIssue(at, length, $"{label} is {printed}", false);
        }
    }

    private static bool SameCard(string printed, string name)
        => printed.Equals(name, StringComparison.OrdinalIgnoreCase)
           || printed.Split(" // ").Any(face => face.Equals(name, StringComparison.OrdinalIgnoreCase));

    /// Where the card name sits in its line.
    private static (int Start, int Length) NameSpan(string line, string name)
    {
        var at = line.IndexOf(name, StringComparison.OrdinalIgnoreCase);
        if (at >= 0) return (at, name.Length);
        var first = line.TakeWhile(c => !char.IsLetter(c)).Count();
        return (first, Math.Max(1, line.TrimEnd().Length - first));
    }

    /// Where the "(SET) 123" or "[SET] 123" part sits after the name.
    private static (int Start, int Length) PrintingSpan(string line, int after)
    {
        var at = line.IndexOfAny(['(', '['], Math.Min(after, line.Length));
        if (at < 0) at = Math.Min(after, line.Length);
        return (at, Math.Max(1, line.TrimEnd().Length - at));
    }

    // MARK: - Status, redraw, save

    private void Refresh()
    {
        var any = CheckedLines().Count;
        _replace.IsEnabled = _delete.IsEnabled = _clear.IsEnabled = any > 0;
        _replace.Content = any > 0 ? $"Replace {any} checked ▾" : "Replace checked ▾";
        _delete.Content = any > 0 ? $"Delete {any} checked" : "Delete checked";
        UpdateStatus();
        Redraw();
    }

    private void UpdateStatus()
    {
        var main = 0; var side = 0;
        foreach (var e in DeckList.Parse(_box.Text).Entries)
            if (e.Board == DeckBoard.Main) main += e.Quantity; else side += e.Quantity;
        var text = $"{main} card{(main == 1 ? "" : "s")}" + (side > 0 ? $" and {side} in the sideboard" : "");
        var errors = _issues.Values.Count(x => x.Severe);
        var warnings = _issues.Count - errors;
        Color color = Theme.Parchment;
        if (_checkError != null) { text += $" · couldn't check cards with Scryfall ({_checkError})"; color = Color.FromRgb(255, 190, 120); }
        else if (_checking) text += " · checking cards with Scryfall…";
        else if (errors > 0) { text += $" · {errors} line{(errors == 1 ? "" : "s")} need{(errors == 1 ? "s" : "")} fixing"; color = Color.FromRgb(255, 138, 122); }
        else if (warnings > 0) { text += $" · {warnings} printing{(warnings == 1 ? "" : "s")} to look at"; color = Color.FromRgb(255, 200, 110); }
        else text += " · every card found";
        if (IsDirty) text += " · not saved yet";
        _status.Text = text;
        _status.Foreground = Theme.Brush(color);
    }

    private void Redraw()
    {
        // After layout, so the text's own positions are current.
        _box.Dispatcher.BeginInvoke(() => { _back.InvalidateVisual(); _front.InvalidateVisual(); _gutter.InvalidateVisual(); }, DispatcherPriority.Loaded);
    }

    private bool TrySave()
    {
        var parsed = DeckList.Parse(_box.Text);
        if (parsed.Entries.Count == 0)
        {
            MessageBox.Show(MainWindow.Instance, "A deck needs at least one card. Add a line, or use Delete this deck on the deck page instead.", "Save the deck");
            return false;
        }
        var errors = _issues.Values.Count(x => x.Severe);
        if (errors > 0 && MessageBox.Show(MainWindow.Instance,
                $"{errors} line{(errors == 1 ? " has a card that can't be found or a line that can't be read" : "s have cards that can't be found or can't be read")}. " +
                "Cards that can't be found won't print, and lines that can't be read are left out.\n\nSave anyway?",
                "Save the deck?", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            return false;
        DeckStore.Shared.ReplaceEntries(_deckId, _box.Text);
        _saved = Normalize(_box.Text);
        return true;
    }

    private bool CanClose()
    {
        if (!IsDirty) return true;
        return MessageBox.Show(MainWindow.Instance, $"Save your changes to {_deckName}?", "Unsaved changes",
                MessageBoxButton.YesNoCancel, MessageBoxImage.Question) switch
        {
            MessageBoxResult.Yes => TrySave(),
            MessageBoxResult.No => true,
            _ => false,
        };
    }

    // MARK: - What the layers draw from

    internal TextBox Box => _box;
    internal LineKind KindOf(int i) => i >= 0 && i < _kinds.Length ? _kinds[i] : LineKind.Blank;
    internal bool IsChecked(int i) => i >= 0 && i < _checked.Count && _checked[i];
    internal bool IsMatch(int i) => _matches.Contains(i);
    internal LineIssue? IssueAt(int i) => _issues.GetValueOrDefault(i);
    internal int LineLength(int i) => i >= 0 && i < _lines.Length ? _lines[i].TrimEnd().Length : 0;

    /// The lines on screen, with their top and height in the text box.
    internal IEnumerable<(int Index, double Top, double Height)> VisibleLines()
    {
        var first = _box.GetFirstVisibleLineIndex();
        var last = Math.Min(_box.GetLastVisibleLineIndex(), _box.LineCount - 1);
        if (first < 0 || last < first) yield break;
        for (var i = first; i <= last; i++)
        {
            var start = _box.GetCharacterIndexFromLineIndex(i);
            if (start < 0) continue;
            var r = _box.GetRectFromCharacterIndex(start);
            if (r.IsEmpty) continue;
            yield return (i, r.Top, r.Height);
        }
    }

    /// The left edge of a character in a line, in the text box.
    internal double X(int line, int column)
    {
        var start = _box.GetCharacterIndexFromLineIndex(line);
        var r = _box.GetRectFromCharacterIndex(Math.Clamp(start + column, 0, _box.Text.Length));
        return r.IsEmpty ? double.NaN : r.Left;
    }
}

/// One of the two layers around the text: behind it, the bands for
/// checked and found lines and the gold rules between cards; in front,
/// the jagged underlines and notes for lines that need fixing.
internal sealed class LineLayer : FrameworkElement
{
    private static readonly Brush CheckedFill = Theme.Brush(Color.FromRgb(255, 214, 102), 0.45);
    private static readonly Brush MatchFill = Theme.Brush(Color.FromRgb(120, 200, 255), 0.30);
    private static readonly Brush MatchBar = Theme.Brush(Color.FromRgb(40, 120, 200));
    private static readonly Pen Rule = Theme.Freeze(new Pen(Theme.Brush(Theme.Gold, 0.35), 1));
    private static readonly Color Red = Color.FromRgb(196, 22, 12);
    private static readonly Color Amber = Color.FromRgb(168, 96, 0);
    private static readonly Typeface NoteFace = new(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);

    private readonly DeckTextEditor _ed;
    private readonly bool _front;

    public LineLayer(DeckTextEditor ed, bool front)
    {
        _ed = ed;
        _front = front;
        IsHitTestVisible = false;
        ClipToBounds = true;
    }

    protected override void OnRender(DrawingContext dc)
    {
        var right = ActualWidth - 14;
        foreach (var (i, top, height) in _ed.VisibleLines())
        {
            if (!_front)
            {
                var band = new Rect(4, top, Math.Max(0, right - 4), height);
                if (_ed.IsChecked(i)) dc.DrawRoundedRectangle(CheckedFill, null, band, 5, 5);
                else if (_ed.IsMatch(i)) dc.DrawRoundedRectangle(MatchFill, null, band, 5, 5);
                if (_ed.IsMatch(i)) dc.DrawRoundedRectangle(MatchBar, null, new Rect(4, top + 2, 3, Math.Max(0, height - 4)), 1.5, 1.5);
                if (_ed.KindOf(i) == LineKind.Card)
                    dc.DrawLine(Rule, new Point(10, Math.Round(top + height) - 0.5), new Point(right, Math.Round(top + height) - 0.5));
            }
            else if (_ed.IssueAt(i) is { } issue) DrawIssue(dc, i, top, height, issue);
        }
    }

    private void DrawIssue(DrawingContext dc, int line, double top, double height, LineIssue issue)
    {
        var x1 = _ed.X(line, issue.Start);
        var x2 = _ed.X(line, issue.Start + issue.Length);
        var end = _ed.X(line, _ed.LineLength(line));
        if (double.IsNaN(x1) || double.IsNaN(x2) || double.IsNaN(end)) return;
        var color = issue.Severe ? Red : Amber;
        var pen = new Pen(Theme.Brush(color), 1.4) { LineJoin = PenLineJoin.Round };

        // The jagged underline.
        var y = top + height - 3;
        var zig = new StreamGeometry();
        using (var g = zig.Open())
        {
            g.BeginFigure(new Point(x1, y), false, false);
            var up = true;
            for (var x = x1 + 2.5; x <= Math.Max(x2, x1 + 5); x += 2.5, up = !up) g.LineTo(new Point(x, up ? y - 2.5 : y), true, true);
        }
        zig.Freeze();
        dc.DrawGeometry(null, pen, zig);

        // The arrow and its note, past the end of the line.
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var note = new FormattedText(issue.Message, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, NoteFace, 13, Theme.Brush(color), dpi);
        var mid = top + height / 2;
        var ax = end + 14;
        var pill = new Rect(ax - 4, mid - note.Height / 2 - 2, 14 + note.Width + 12, note.Height + 4);
        dc.DrawRoundedRectangle(Theme.Brush(Color.FromRgb(255, 248, 232), 0.92), new Pen(Theme.Brush(color, 0.55), 1), pill, 7, 7);
        var arrow = new StreamGeometry();
        using (var g = arrow.Open())
        {
            g.BeginFigure(new Point(ax + 1, mid), true, true);
            g.LineTo(new Point(ax + 9, mid - 5), true, true);
            g.LineTo(new Point(ax + 9, mid + 5), true, true);
        }
        arrow.Freeze();
        dc.DrawGeometry(Theme.Brush(color), null, arrow);
        dc.DrawText(note, new Point(ax + 14, mid - note.Height / 2));
    }
}

/// The column of tick boxes beside the card lines.
internal sealed class CheckGutter : FrameworkElement
{
    private static readonly Brush Empty = Theme.Brush(Color.FromRgb(246, 238, 218), 0.85);
    private static readonly Brush Filled = Theme.Freeze(new LinearGradientBrush(Color.FromRgb(250, 222, 128), Color.FromRgb(201, 150, 52), 90));
    private static readonly Pen Rim = Theme.Freeze(new Pen(Theme.Brush(Theme.LeatherLight), 1.4));
    private static readonly Pen Tick = Theme.Freeze(new Pen(Theme.Brush(Theme.LeatherDeep), 2.2) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round, LineJoin = PenLineJoin.Round });

    private readonly DeckTextEditor _ed;

    public CheckGutter(DeckTextEditor ed)
    {
        _ed = ed;
        Width = 30;
        ClipToBounds = true;
        Cursor = Cursors.Hand;
        ToolTip = "Check a line to delete or replace it (or Ctrl+click the line)";
    }

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize));
        foreach (var (i, top, height) in _ed.VisibleLines())
        {
            if (_ed.KindOf(i) != LineKind.Card) continue;
            var box = new Rect(6, top + (height - 17) / 2, 17, 17);
            var on = _ed.IsChecked(i);
            dc.DrawRoundedRectangle(on ? Filled : Empty, Rim, box, 4, 4);
            if (!on) continue;
            var tick = new StreamGeometry();
            using (var g = tick.Open())
            {
                g.BeginFigure(new Point(box.Left + 4, box.Top + 9), false, false);
                g.LineTo(new Point(box.Left + 7.5, box.Top + 12.5), true, true);
                g.LineTo(new Point(box.Left + 13, box.Top + 5), true, true);
            }
            tick.Freeze();
            dc.DrawGeometry(null, Tick, tick);
        }
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        var y = e.GetPosition(this).Y;
        foreach (var (i, top, height) in _ed.VisibleLines())
            if (y >= top && y < top + height) { _ed.ToggleCheck(i); break; }
        e.Handled = true;
    }
}
