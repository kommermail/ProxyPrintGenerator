// DeckList.cs
// Forgiving deck list parser, ported from DeckList.swift. Canonical line:
//
//     <qty> <Card Name> (<set>) <collector_number>
//
// Also accepted: blank lines and // or # comments, section headers
// ("Deck", "Sideboard:", "Commander", ...), "4x" quantities, "SB:"
// prefixes, "*F*" foil markers, trailing "[Tag]" brackets, bare names,
// and "(set)" with no collector number. Lines that cannot be
// understood are collected as warnings rather than aborting the deck.

using System.Text.RegularExpressions;

namespace ProxyPrintGenerator.Engine;

public enum DeckBoard { Main, Sideboard, Maybeboard }

public sealed record DeckEntry(int Quantity, string Name, string? SetCode,
    string? CollectorNumber, DeckBoard Board, bool IsFoil)
{
    /// True when the line fully identifies a printing.
    public bool HasPrinting => SetCode != null && CollectorNumber != null;
}

public sealed record DeckParseResult(List<DeckEntry> Entries, List<string> Warnings);

public static partial class DeckList
{
    [GeneratedRegex(@"^(\d{1,3})\s*[xX]\s+(.+)$")] private static partial Regex QtyX();
    [GeneratedRegex(@"^(\d{1,3})\s+(.+)$")] private static partial Regex QtyPlain();
    [GeneratedRegex(@"\(([A-Za-z0-9]+)\)\s+(\S+)$")] private static partial Regex SetAndNumber();
    [GeneratedRegex(@"\(([A-Za-z0-9]+)\)$")] private static partial Regex SetOnly();

    public static DeckParseResult Parse(string text)
    {
        var entries = new List<DeckEntry>();
        var warnings = new List<string>();
        var board = DeckBoard.Main;

        foreach (var rawLine in text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            var line = rawLine.Trim(' ', '\t');
            if (line.Length == 0) continue;
            if (line.StartsWith("//") || line.StartsWith('#')) continue;

            // Section headers switch the board for following lines.
            var headerName = line.EndsWith(':') ? line[..^1].Trim() : line;
            var headerBoard = BoardForHeader(headerName);
            if (headerBoard != null) { board = headerBoard.Value; continue; }
            if (line.EndsWith(':') && !line.Contains('(')) continue; // e.g. "Creatures:"

            var lineBoard = board;
            if (line.ToUpperInvariant().StartsWith("SB:"))
            {
                lineBoard = DeckBoard.Sideboard;
                line = line[3..].Trim();
            }

            var isFoil = false;
            if (line.Contains("*F*"))
            {
                isFoil = true;
                line = line.Replace("*F*", "").Trim();
            }

            // Trailing bracketed tags, e.g. "[Ramp]".
            while (line.EndsWith(']'))
            {
                var open = line.LastIndexOf('[');
                if (open < 0) break;
                line = line[..open].Trim();
            }
            if (line.Length == 0) continue;

            // Quantity: "4 ", "4x ", or none (meaning 1). Three digits at
            // most, so a card name that starts with a year is not eaten.
            var quantity = 1;
            var rest = line;
            var m = QtyX().Match(line);
            if (!m.Success) m = QtyPlain().Match(line);
            if (m.Success)
            {
                quantity = int.TryParse(m.Groups[1].Value, out var q) ? q : 1;
                rest = m.Groups[2].Value.Trim();
            }

            var name = rest;
            string? setCode = null, collector = null;
            var pm = SetAndNumber().Match(rest);
            if (pm.Success)
            {
                setCode = pm.Groups[1].Value.ToLowerInvariant();
                collector = pm.Groups[2].Value;
                name = rest[..pm.Index].Trim();
            }
            else
            {
                var sm = SetOnly().Match(rest);
                if (sm.Success)
                {
                    setCode = sm.Groups[1].Value.ToLowerInvariant();
                    name = rest[..sm.Index].Trim();
                }
            }

            // Some sources write "(teve) #3"; Scryfall numbers carry no '#'.
            if (collector != null && collector.StartsWith('#')) collector = collector[1..];

            if (name.Length == 0)
            {
                warnings.Add($"Skipped unparseable line: {rawLine}");
                continue;
            }
            entries.Add(new DeckEntry(quantity, name, setCode, collector, lineBoard, isFoil));
        }
        return new DeckParseResult(entries, warnings);
    }

    private static DeckBoard? BoardForHeader(string header) => header.ToLowerInvariant() switch
    {
        "deck" or "mainboard" or "main" or "commander" or "commanders" or "companion" => DeckBoard.Main,
        "sideboard" => DeckBoard.Sideboard,
        "maybeboard" => DeckBoard.Maybeboard,
        _ => null,
    };
}
