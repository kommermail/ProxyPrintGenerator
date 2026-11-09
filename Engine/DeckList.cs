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
//
// Set codes in square brackets work too, as several exporters write
// them: "Shields Up! [TRK] 35", "Talon Gates of Madara [SDS]",
// "Forest (0316) [TRK] 316" (the "(0316)" is a variant number and is
// dropped), and the old "[M10] Lightning Bolt" prefix. A bracket only
// counts as a set code when it is 2 to 6 capitals or digits and the line
// names no "(set)" already; anything else ("[Ramp]", "[Card Draw]") is a
// tag and is ignored, as before.

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
    [GeneratedRegex(@"^(.*\S)\s*\[([A-Za-z0-9]{2,6})\]\s+#?([A-Za-z0-9][^\s\[\]]*)$")] private static partial Regex BracketSetAndNumber();
    [GeneratedRegex(@"^\[([A-Z0-9]{2,6})\]\s+(.+)$")] private static partial Regex BracketSetPrefix();
    [GeneratedRegex(@"\s*\(\d+\)$")] private static partial Regex VariantNumber();
    [GeneratedRegex(@"\((?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]+\)(\s+\S+)?$")] private static partial Regex ParenPrinting();

    /// "TRK", "SDS", "M10", "2X2": capitals and digits with a letter.
    private static bool LooksLikeSetCode(string s)
        => s.Length is >= 2 and <= 6 && s.All(c => c is >= 'A' and <= 'Z' or >= '0' and <= '9') && s.Any(char.IsLetter);

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

            // Trailing brackets: a set code ("... [SDS]") when the line has
            // no "(set)" of its own, otherwise a tag ("[Ramp]") to drop.
            string? bracketSet = null, bracketNumber = null;
            while (line.EndsWith(']'))
            {
                var open = line.LastIndexOf('[');
                if (open < 0) break;
                var inner = line[(open + 1)..^1].Trim();
                var head = line[..open].Trim();
                line = head;
                if (LooksLikeSetCode(inner) && !ParenPrinting().IsMatch(head))
                {
                    bracketSet = inner;
                    break;
                }
            }
            // "... [TRK] 35": a bracketed set code with its collector number.
            if (bracketSet == null)
            {
                var bm = BracketSetAndNumber().Match(line);
                if (bm.Success && !ParenPrinting().IsMatch(bm.Groups[1].Value))
                {
                    bracketSet = bm.Groups[2].Value;
                    bracketNumber = bm.Groups[3].Value;
                    line = bm.Groups[1].Value.Trim();
                }
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

            // The old "[M10] Lightning Bolt" style: set code first.
            if (bracketSet == null && BracketSetPrefix().Match(rest) is { Success: true } pre)
            {
                bracketSet = pre.Groups[1].Value;
                rest = pre.Groups[2].Value.Trim();
            }

            var name = rest;
            string? setCode = null, collector = null;
            if (bracketSet != null)
            {
                setCode = bracketSet.ToLowerInvariant();
                collector = bracketNumber;
                // "Forest (0316)": the bracket style's variant number.
                name = VariantNumber().Replace(rest, "").Trim();
            }
            else if (SetAndNumber().Match(rest) is { Success: true } pm)
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
