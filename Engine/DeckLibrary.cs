// DeckLibrary.cs
// Saved decks in one JSON file under %APPDATA%, ported from
// DeckLibrary.swift. Each line keeps the printing chosen plus the one it
// was imported with (for the ALT badge and reset), and the card it held
// before a replace (so the replace can be undone).

using System.IO;
using System.Text.Json;

namespace ProxyPrintGenerator.Engine;

public sealed class SavedCardLine
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public int Quantity { get; set; }
    public string Name { get; set; } = "";
    public string? SetCode { get; set; }
    public string? CollectorNumber { get; set; }
    /// "main", "sideboard", or "maybeboard".
    public string Board { get; set; } = "main";
    public string? OriginalSetCode { get; set; }
    public string? OriginalCollectorNumber { get; set; }
    public string? PreviousName { get; set; }
    public string? PreviousSetCode { get; set; }
    public string? PreviousCollectorNumber { get; set; }

    public bool CanRevertReplacement => PreviousName != null;
    public bool IsAltPrinting => OriginalSetCode != null
        && (SetCode != OriginalSetCode || CollectorNumber != OriginalCollectorNumber);

    public string PrintingLabel => SetCode == null ? "any printing"
        : CollectorNumber != null ? $"({SetCode}) {CollectorNumber}" : $"({SetCode})";

    public SavedCardLine Clone() => (SavedCardLine)MemberwiseClone();
}

public sealed class SavedDeck
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Source { get; set; } = "";
    public List<SavedCardLine> Entries { get; set; } = [];
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public DateTime UpdatedAt { get; set; } = DateTime.UtcNow;

    public int CardCount => Entries.Where(e => e.Board == "main").Sum(e => e.Quantity);
    public int SideboardCount => Entries.Where(e => e.Board != "main").Sum(e => e.Quantity);
}

public sealed class DeckStore
{
    public static DeckStore Shared { get; } = new();

    public List<SavedDeck> Decks { get; private set; } = [];
    public event Action? Changed;

    private readonly string _file;

    private DeckStore()
    {
        // PPG_DATA_DIR points the library somewhere else (handy for testing).
        var folder = Environment.GetEnvironmentVariable("PPG_DATA_DIR") is { Length: > 0 } custom ? custom
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ProxyPrintGenerator");
        Directory.CreateDirectory(folder);
        _file = Path.Combine(folder, "decks.json");
        try
        {
            if (File.Exists(_file)) Decks = JsonSerializer.Deserialize<List<SavedDeck>>(File.ReadAllText(_file)) ?? [];
        }
        catch { Decks = []; }
        if (RepairBracketLines()) Persist();
    }

    /// Lines saved before the parser understood "[TRK] 35" set codes kept
    /// that text inside the card name ("Shields Up! [TRK] 35"), so the card
    /// never matched. Re-reads such names with the current parser and
    /// gives them their printing. Returns true when anything changed.
    private bool RepairBracketLines()
    {
        var changed = false;
        foreach (var line in Decks.SelectMany(d => d.Entries))
        {
            if (line.SetCode != null || !line.Name.Contains('[')) continue;
            var reread = DeckList.Parse("1 " + line.Name).Entries.FirstOrDefault();
            if (reread?.SetCode == null || reread.Name.Length == 0) continue;
            line.Name = reread.Name;
            line.SetCode = line.OriginalSetCode = reread.SetCode;
            line.CollectorNumber = line.OriginalCollectorNumber = reread.CollectorNumber;
            changed = true;
        }
        return changed;
    }

    private void Persist()
    {
        try
        {
            var tmp = _file + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(Decks, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(tmp, _file, true);
        }
        catch { /* best effort */ }
        Changed?.Invoke();
    }

    public SavedDeck? Deck(Guid id) => Decks.FirstOrDefault(d => d.Id == id);

    public SavedDeck? Add(string name, string source, string text)
    {
        var parsed = DeckList.Parse(text);
        if (parsed.Entries.Count == 0) return null;
        var deck = new SavedDeck
        {
            Name = name,
            Source = source,
            Entries = parsed.Entries.Select(e => new SavedCardLine
            {
                Quantity = e.Quantity, Name = e.Name, SetCode = e.SetCode, CollectorNumber = e.CollectorNumber,
                Board = BoardName(e.Board), OriginalSetCode = e.SetCode, OriginalCollectorNumber = e.CollectorNumber,
            }).ToList(),
        };
        Decks.Add(deck);
        Persist();
        return deck;
    }

    public void DeleteDeck(Guid id) { Decks.RemoveAll(d => d.Id == id); Persist(); }

    private void Mutate(Guid deckId, Action<SavedDeck> change)
    {
        var deck = Deck(deckId);
        if (deck == null) return;
        change(deck);
        deck.UpdatedAt = DateTime.UtcNow;
        Persist();
    }

    public void SetQuantity(Guid deckId, int index, int quantity) => Mutate(deckId, d =>
    {
        if (index >= 0 && index < d.Entries.Count) d.Entries[index].Quantity = Math.Max(1, quantity);
    });

    public void RemoveCard(Guid deckId, int index) => Mutate(deckId, d =>
    {
        if (index >= 0 && index < d.Entries.Count) d.Entries.RemoveAt(index);
    });

    /// A card already in the deck in the same printing gains quantity.
    public void AddCard(Guid deckId, string name, string setCode, string collectorNumber, int quantity) => Mutate(deckId, d =>
    {
        var existing = d.Entries.FirstOrDefault(e => e.Board == "main" && e.Name == name
                                                     && e.SetCode == setCode && e.CollectorNumber == collectorNumber);
        if (existing != null) existing.Quantity += quantity;
        else d.Entries.Add(new SavedCardLine
        {
            Quantity = quantity, Name = name, SetCode = setCode, CollectorNumber = collectorNumber, Board = "main",
            OriginalSetCode = setCode, OriginalCollectorNumber = collectorNumber,
        });
    });

    public void Rename(Guid deckId, string newName) => Mutate(deckId, d => d.Name = newName);

    public void SetPrinting(Guid deckId, int index, string? setCode, string? collectorNumber) => Mutate(deckId, d =>
    {
        if (index < 0 || index >= d.Entries.Count) return;
        d.Entries[index].SetCode = setCode;
        d.Entries[index].CollectorNumber = collectorNumber;
    });

    public void ResetPrinting(Guid deckId, int index) => Mutate(deckId, d =>
    {
        if (index < 0 || index >= d.Entries.Count) return;
        var e = d.Entries[index];
        e.SetCode = e.OriginalSetCode;
        e.CollectorNumber = e.OriginalCollectorNumber;
    });

    /// Replaces a line with a different card, keeping quantity and board.
    public void ReplaceCard(Guid deckId, int index, string name, string setCode, string collectorNumber) => Mutate(deckId, d =>
    {
        if (index < 0 || index >= d.Entries.Count) return;
        var old = d.Entries[index];
        d.Entries[index] = new SavedCardLine
        {
            Id = old.Id, Quantity = old.Quantity, Name = name, SetCode = setCode, CollectorNumber = collectorNumber,
            Board = old.Board, OriginalSetCode = setCode, OriginalCollectorNumber = collectorNumber,
            PreviousName = old.Name, PreviousSetCode = old.SetCode, PreviousCollectorNumber = old.CollectorNumber,
        };
    });

    public void RevertReplacement(Guid deckId, int index) => Mutate(deckId, d =>
    {
        if (index < 0 || index >= d.Entries.Count) return;
        var line = d.Entries[index];
        if (line.PreviousName == null) return;
        line.Name = line.PreviousName;
        line.SetCode = line.PreviousSetCode;
        line.CollectorNumber = line.PreviousCollectorNumber;
        line.OriginalSetCode = line.PreviousSetCode;
        line.OriginalCollectorNumber = line.PreviousCollectorNumber;
        line.PreviousName = line.PreviousSetCode = line.PreviousCollectorNumber = null;
    });

    private static string BoardName(DeckBoard b) => b switch
    {
        DeckBoard.Sideboard => "sideboard",
        DeckBoard.Maybeboard => "maybeboard",
        _ => "main",
    };

    /// The deck as `qty Name (set) number` lines with current printings.
    public static string DeckText(SavedDeck deck)
    {
        static string Line(SavedCardLine e)
        {
            var t = $"{e.Quantity} {e.Name}";
            if (e.SetCode != null)
            {
                t += $" ({e.SetCode})";
                if (e.CollectorNumber != null) t += $" {e.CollectorNumber}";
            }
            return t;
        }
        var lines = deck.Entries.Where(e => e.Board == "main").Select(Line).ToList();
        var side = deck.Entries.Where(e => e.Board == "sideboard").ToList();
        if (side.Count > 0) { lines.Add("Sideboard:"); lines.AddRange(side.Select(Line)); }
        var maybe = deck.Entries.Where(e => e.Board == "maybeboard").ToList();
        if (maybe.Count > 0) { lines.Add("Maybeboard:"); lines.AddRange(maybe.Select(Line)); }
        return string.Join("\n", lines);
    }
}
