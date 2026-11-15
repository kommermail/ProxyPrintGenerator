//
//  DeckList.swift
//  Version 4
//  Proxy Printer (native port) — Phase 1 engine
//
//  Forgiving deck list parser. Canonical line format:
//
//      <qty> <Card Name> (<set>) <collector_number>
//
//  Also accepted, mirroring the web selector's paste parser:
//    - blank lines and comment lines starting with // or #
//    - section headers ("Deck", "Sideboard:", "Commander", ...), which set
//      the board for the lines that follow; unrecognized lines ending in
//      ":" are treated as headers and skipped
//    - quantities written as "4x" as well as "4" (a missing quantity means 1)
//    - "SB:" prefixes marking a line as sideboard
//    - foil markers "*F*" anywhere on the line
//    - trailing bracketed tags, e.g. "[Ramp]" (Archidekt exports)
//    - set codes in square brackets, as several exporters write
//      them: "Shields Up! [TRK] 35", "Talon Gates of Madara [SDS]",
//      "Forest (0316) [TRK] 316" (the "(0316)" is a variant number
//      and is dropped), and the old "[M10] Lightning Bolt" prefix.
//      A bracket only counts as a set code when it is 2 to 6
//      capitals or digits and the line names no "(set)" already;
//      anything else ("[Ramp]", "[Card Draw]") is a tag, ignored.
//    - lines with no printing at all ("4 Lightning Bolt"), and lines with a
//      set but no collector number ("Lightning Bolt (m10)"); both are
//      resolved later by name lookup in ScryfallClient
//
//  Lines that cannot be understood at all are collected as warnings rather
//  than aborting the whole deck.
//

import Foundation

public enum DeckBoard: Equatable {
    case main
    case sideboard
    case maybeboard
}

public struct DeckEntry: Equatable {
    public var quantity: Int
    public var name: String
    /// Lowercase Scryfall set code, when the line named a printing.
    public var setCode: String?
    /// Collector number exactly as written, when present.
    public var collectorNumber: String?
    public var board: DeckBoard
    public var isFoil: Bool

    public init(quantity: Int, name: String, setCode: String?,
                collectorNumber: String?, board: DeckBoard, isFoil: Bool) {
        self.quantity = quantity
        self.name = name
        self.setCode = setCode
        self.collectorNumber = collectorNumber
        self.board = board
        self.isFoil = isFoil
    }

    /// True when the line fully identifies a printing.
    public var hasPrinting: Bool { setCode != nil && collectorNumber != nil }
}

public struct DeckParseResult {
    public var entries: [DeckEntry]
    public var warnings: [String]
}

public enum DeckList {

    public static func parseFile(at url: URL) throws -> DeckParseResult {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parse(text)
    }

    public static func parse(_ text: String) -> DeckParseResult {
        var entries: [DeckEntry] = []
        var warnings: [String] = []
        var board: DeckBoard = .main

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("//") || line.hasPrefix("#") { continue }

            // Section headers switch the board for following lines.
            let headerName = line.hasSuffix(":")
                ? String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                : line
            if let headerBoard = deckBoard(forHeader: headerName) {
                board = headerBoard
                continue
            }
            if line.hasSuffix(":") && !line.contains("(") {
                continue // unrecognized section header, e.g. "Creatures:"
            }

            var lineBoard = board

            // "SB:" prefix pins this one line to the sideboard.
            if line.uppercased().hasPrefix("SB:") {
                lineBoard = .sideboard
                line = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
            }

            // Foil marker.
            var isFoil = false
            if line.contains("*F*") {
                isFoil = true
                line = line.replacingOccurrences(of: "*F*", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }

            // Trailing brackets: a set code ("... [SDS]") when
            // the line names no "(set)" of its own, otherwise a
            // tag ("[Ramp]") to drop, as before.
            var bracketSet: String? = nil
            var bracketNumber: String? = nil
            while line.hasSuffix("]"),
                  let open = line.lastIndex(of: "[") {
                let innerStart = line.index(after: open)
                let innerEnd = line.index(before: line.endIndex)
                let inner = String(line[innerStart..<innerEnd])
                    .trimmingCharacters(in: .whitespaces)
                let head = String(line[..<open])
                    .trimmingCharacters(in: .whitespaces)
                line = head
                if looksLikeSetCode(inner),
                   !hasParenPrinting(head) {
                    bracketSet = inner
                    break
                }
            }

            // "... [TRK] 35": a bracketed set code followed by
            // its collector number.
            if bracketSet == nil,
               let m = firstMatch(
                   #"^(.*\S)\s*\[([A-Za-z0-9]{2,6})\]\s+#?([A-Za-z0-9][^\s\[\]]*)$"#,
                   in: line),
               !hasParenPrinting(m[1]) {
                bracketSet = m[2]
                bracketNumber = m[3]
                line = m[1].trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty { continue }

            // Quantity: "4 ", "4x ", or none (meaning 1). Capped at three
            // digits so a card name that starts with a year is not eaten.
            var quantity = 1
            var rest = line
            if let m = firstMatch(#"^(\d{1,3})\s*[xX]\s+(.+)$"#, in: line)
                ?? firstMatch(#"^(\d{1,3})\s+(.+)$"#, in: line) {
                quantity = Int(m[1]) ?? 1
                rest = m[2].trimmingCharacters(in: .whitespaces)
            }

            // The old "[M10] Lightning Bolt" style: the set
            // code comes first, before the card's name.
            if bracketSet == nil,
               let m = firstMatch(#"^\[([A-Z0-9]{2,6})\]\s+(.+)$"#,
                                  in: rest) {
                bracketSet = m[1]
                rest = m[2].trimmingCharacters(in: .whitespaces)
            }

            // Printing suffix: "(set) collector" or just "(set)",
            // unless a bracketed set code already named it.
            var name = rest
            var setCode: String? = nil
            var collector: String? = nil
            if let bracketSet {
                setCode = bracketSet.lowercased()
                collector = bracketNumber
                // "Forest (0316)": the bracket style's variant
                // number is not part of the card's name.
                if let m = firstMatch(#"\s*\(\d+\)$"#, in: name) {
                    name = String(name.dropLast(m[0].count))
                        .trimmingCharacters(in: .whitespaces)
                }
            } else if let m = firstMatch(#"\(([A-Za-z0-9]+)\)\s+(\S+)$"#, in: rest) {
                setCode = m[1].lowercased()
                collector = m[2]
                name = String(rest[..<rest.range(of: m[0])!.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            } else if let m = firstMatch(#"\(([A-Za-z0-9]+)\)$"#, in: rest) {
                setCode = m[1].lowercased()
                name = String(rest[..<rest.range(of: m[0])!.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }

            // Some sources write the collector number with a
            // leading "#" ("(teve) #3"); Scryfall numbers do
            // not carry it.
            if let rawCollector = collector,
               rawCollector.hasPrefix("#") {
                collector = String(rawCollector.dropFirst())
            }

            if name.isEmpty {
                warnings.append("Skipped unparseable line: \(rawLine)")
                continue
            }
            entries.append(DeckEntry(quantity: quantity, name: name,
                                     setCode: setCode,
                                     collectorNumber: collector,
                                     board: lineBoard, isFoil: isFoil))
        }
        return DeckParseResult(entries: entries, warnings: warnings)
    }

    private static func deckBoard(forHeader header: String) -> DeckBoard? {
        switch header.lowercased() {
        case "deck", "mainboard", "main", "commander", "commanders",
             "companion":
            return .main
        case "sideboard":
            return .sideboard
        case "maybeboard":
            return .maybeboard
        default:
            return nil
        }
    }

    /// "TRK", "SDS", "M10", "2X2": two to six capitals or digits
    /// with at least one letter.
    private static func looksLikeSetCode(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 6 else { return false }
        guard s.allSatisfy({ $0.isASCII
            && ($0.isUppercase || $0.isNumber) }) else { return false }
        return s.contains { $0.isUppercase }
    }

    /// True when the text ends with a "(set)" group, optionally
    /// followed by one token (its collector number): the line
    /// already names its printing in parentheses.
    private static func hasParenPrinting(_ s: String) -> Bool {
        firstMatch(
            #"\((?=[A-Za-z0-9]*[A-Za-z])[A-Za-z0-9]+\)(\s+\S+)?$"#,
            in: s) != nil
    }

    /// Returns the full match at index 0 plus capture groups, or nil.
    private static func firstMatch(_ pattern: String,
                                   in string: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(string.startIndex..., in: string)
        guard let m = re.firstMatch(in: string, range: range) else {
            return nil
        }
        return (0..<m.numberOfRanges).map { i in
            guard let r = Range(m.range(at: i), in: string) else { return "" }
            return String(string[r])
        }
    }
}
