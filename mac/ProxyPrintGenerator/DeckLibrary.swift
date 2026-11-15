//
//  DeckLibrary.swift
//  Version 8
//  Proxy Printer (native port) — Phase 4 selector: deck library model
//
//  Saved decks live in one JSON file in Application Support. Each deck
//  keeps its lines with the printing chosen for every card plus the
//  printing it was imported with, so a swapped card can wear an
//  ALT PRINTING badge and can be reset, exactly like the web
//  Printing Selector.
//
//  App target only (DeckStore is an ObservableObject for SwiftUI).
//

import Foundation
import Combine

public struct SavedCardLine: Codable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var quantity: Int
    public var name: String
    public var setCode: String?
    public var collectorNumber: String?
    /// "main", "sideboard", or "maybeboard".
    public var board: String
    /// The printing this line arrived with; nil when it arrived as a
    /// bare name.
    public var originalSetCode: String?
    public var originalCollectorNumber: String?
    /// The card this line held just before a replace, so a
    /// replacement can be undone. Nil when the line was never
    /// replaced, or after the replacement was already undone.
    /// Older saved decks decode these as nil.
    public var previousName: String? = nil
    public var previousSetCode: String? = nil
    public var previousCollectorNumber: String? = nil

    public var canRevertReplacement: Bool { previousName != nil }

    public var isAltPrinting: Bool {
        guard originalSetCode != nil else { return false }
        return setCode != originalSetCode
            || collectorNumber != originalCollectorNumber
    }

    public var printingLabel: String {
        guard let set = setCode else { return "any printing" }
        if let num = collectorNumber { return "(\(set)) \(num)" }
        return "(\(set))"
    }
}

public struct SavedDeck: Codable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var name: String
    /// Where the deck came from: "Paste", "File", "Moxfield", "Archidekt".
    public var source: String
    public var entries: [SavedCardLine]
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public var cardCount: Int {
        entries.filter { $0.board == "main" }
            .reduce(0) { $0 + $1.quantity }
    }
    public var sideboardCount: Int {
        entries.filter { $0.board != "main" }
            .reduce(0) { $0 + $1.quantity }
    }
}

public final class DeckStore: ObservableObject {

    @Published public private(set) var decks: [SavedDeck] = []

    private let fileURL: URL

    public init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("ProxyPrint")
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("decks.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([SavedDeck].self,
                                                    from: data)
        else { return }
        decks = saved
        repairBracketLines()
    }

    /// Lines saved before the parser understood "[TRK] 35" set
    /// codes kept that text inside the card name ("Shields Up!
    /// [TRK] 35"), so the card never matched anything. Re-reads
    /// such names with the current parser and gives them their
    /// printing, then saves the repaired library.
    private func repairBracketLines() {
        var changed = false
        for deckIndex in decks.indices {
            for lineIndex in decks[deckIndex].entries.indices {
                let line = decks[deckIndex].entries[lineIndex]
                guard line.setCode == nil, line.name.contains("[")
                else { continue }
                guard let reread = DeckList.parse(
                        "1 " + line.name).entries.first,
                      let set = reread.setCode, !reread.name.isEmpty
                else { continue }
                decks[deckIndex].entries[lineIndex].name = reread.name
                decks[deckIndex].entries[lineIndex].setCode = set
                decks[deckIndex].entries[lineIndex]
                    .collectorNumber = reread.collectorNumber
                decks[deckIndex].entries[lineIndex]
                    .originalSetCode = set
                decks[deckIndex].entries[lineIndex]
                    .originalCollectorNumber = reread.collectorNumber
                changed = true
            }
        }
        if changed { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(decks) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    // MARK: - Deck operations

    public func deck(id: UUID) -> SavedDeck? {
        decks.first { $0.id == id }
    }

    @discardableResult
    public func add(name: String, source: String, text: String)
        -> SavedDeck? {
        let parsed = DeckList.parse(text)
        guard !parsed.entries.isEmpty else { return nil }
        let deck = SavedDeck(
            name: name, source: source,
            entries: parsed.entries.map { entry in
                SavedCardLine(
                    quantity: entry.quantity,
                    name: entry.name,
                    setCode: entry.setCode,
                    collectorNumber: entry.collectorNumber,
                    board: boardName(entry.board),
                    originalSetCode: entry.setCode,
                    originalCollectorNumber: entry.collectorNumber)
            })
        decks.append(deck)
        persist()
        return deck
    }

    /// Replaces a deck's entries with a fresh parse of list
    /// text, the text editor's Save. The deck keeps its name
    /// and source; the lines it saves with become the new
    /// originals, like an import.
    public func replaceEntries(deckId: UUID, text: String) {
        let parsed = DeckList.parse(text)
        guard !parsed.entries.isEmpty else { return }
        let lines = parsed.entries.map { entry in
            SavedCardLine(
                quantity: entry.quantity,
                name: entry.name,
                setCode: entry.setCode,
                collectorNumber: entry.collectorNumber,
                board: boardName(entry.board),
                originalSetCode: entry.setCode,
                originalCollectorNumber: entry.collectorNumber)
        }
        mutate(deckId) { $0.entries = lines }
    }

    public func delete(at offsets: IndexSet) {
        // Sorted high to low so earlier removals do not shift the
        // indices of later ones. (remove(atOffsets:) itself lives in
        // SwiftUI, and this model file stays UI free.)
        for index in offsets.sorted(by: >) {
            decks.remove(at: index)
        }
        persist()
    }

    /// Deletes one deck outright, by id. Used from inside
    /// the deck's own page, behind a confirmation there.
    public func deleteDeck(id: UUID) {
        decks.removeAll { $0.id == id }
        persist()
    }

    /// Sets one line's quantity (at least one; removing
    /// the line entirely is removeCard's job).
    public func setQuantity(deckId: UUID, entryIndex: Int,
                            quantity: Int) {
        mutate(deckId) { deck in
            guard deck.entries.indices.contains(entryIndex)
            else { return }
            deck.entries[entryIndex].quantity = max(1, quantity)
        }
    }

    /// Removes one card line from a deck entirely.
    public func removeCard(deckId: UUID, entryIndex: Int) {
        mutate(deckId) { deck in
            guard deck.entries.indices.contains(entryIndex)
            else { return }
            deck.entries.remove(at: entryIndex)
        }
    }

    /// Adds a card to a deck's mainboard. A card already in
    /// the deck in the same printing gains quantity instead
    /// of a second line, the way deck lists behave.
    public func addCard(deckId: UUID, name: String,
                        setCode: String, collectorNumber: String,
                        quantity: Int) {
        mutate(deckId) { deck in
            if let existing = deck.entries.firstIndex(where: {
                $0.board == "main" && $0.name == name
                    && $0.setCode == setCode
                    && $0.collectorNumber == collectorNumber
            }) {
                deck.entries[existing].quantity += quantity
            } else {
                deck.entries.append(SavedCardLine(
                    quantity: quantity,
                    name: name,
                    setCode: setCode,
                    collectorNumber: collectorNumber,
                    board: "main",
                    originalSetCode: setCode,
                    originalCollectorNumber: collectorNumber))
            }
        }
    }

    public func rename(deckId: UUID, to newName: String) {
        mutate(deckId) { $0.name = newName }
    }

    /// Swaps the printing of one line (identified by its position in
    /// the deck's entries array).
    public func setPrinting(deckId: UUID, entryIndex: Int,
                            setCode: String?, collectorNumber: String?) {
        mutate(deckId) { deck in
            guard deck.entries.indices.contains(entryIndex) else { return }
            deck.entries[entryIndex].setCode = setCode
            deck.entries[entryIndex].collectorNumber = collectorNumber
        }
    }

    /// Restores a line to the printing it was imported with.
    public func resetPrinting(deckId: UUID, entryIndex: Int) {
        mutate(deckId) { deck in
            guard deck.entries.indices.contains(entryIndex) else { return }
            deck.entries[entryIndex].setCode =
                deck.entries[entryIndex].originalSetCode
            deck.entries[entryIndex].collectorNumber =
                deck.entries[entryIndex].originalCollectorNumber
        }
    }

    /// Replaces a line with a different card entirely, keeping its
    /// quantity and board. The new card's printing becomes both its
    /// current and its original printing, so it does not wear an
    /// ALT PRINTING badge; from here it behaves exactly like a card
    /// the deck was imported with, in the previews, in the exported
    /// list, and in the next PDF build. The card that was there is
    /// remembered in the line's previous fields, so the swap can be
    /// undone with revertReplacement.
    public func replaceCard(deckId: UUID, entryIndex: Int,
                            name: String, setCode: String,
                            collectorNumber: String) {
        mutate(deckId) { deck in
            guard deck.entries.indices.contains(entryIndex) else { return }
            let old = deck.entries[entryIndex]
            deck.entries[entryIndex] = SavedCardLine(
                id: old.id,
                quantity: old.quantity,
                name: name,
                setCode: setCode,
                collectorNumber: collectorNumber,
                board: old.board,
                originalSetCode: setCode,
                originalCollectorNumber: collectorNumber,
                previousName: old.name,
                previousSetCode: old.setCode,
                previousCollectorNumber: old.collectorNumber)
        }
    }

    /// Undoes the last replace on a line, restoring the card that
    /// was there before it, with the printing it had at the time.
    public func revertReplacement(deckId: UUID, entryIndex: Int) {
        mutate(deckId) { deck in
            guard deck.entries.indices.contains(entryIndex),
                  let previous = deck.entries[entryIndex].previousName
            else { return }
            var line = deck.entries[entryIndex]
            line.name = previous
            line.setCode = line.previousSetCode
            line.collectorNumber = line.previousCollectorNumber
            line.originalSetCode = line.previousSetCode
            line.originalCollectorNumber = line.previousCollectorNumber
            line.previousName = nil
            line.previousSetCode = nil
            line.previousCollectorNumber = nil
            deck.entries[entryIndex] = line
        }
    }

    private func mutate(_ deckId: UUID, _ change: (inout SavedDeck) -> Void) {
        guard let index = decks.firstIndex(where: { $0.id == deckId })
        else { return }
        change(&decks[index])
        decks[index].updatedAt = Date()
        persist()
    }

    private func boardName(_ board: DeckBoard) -> String {
        switch board {
        case .main: return "main"
        case .sideboard: return "sideboard"
        case .maybeboard: return "maybeboard"
        }
    }

    // MARK: - Export

    /// The deck as a list in `qty Name (set) collectorNumber` lines,
    /// carrying the currently chosen printings. This is the same text
    /// the print engine consumes and the .txt other tools accept.
    public static func deckText(for deck: SavedDeck) -> String {
        func line(_ entry: SavedCardLine) -> String {
            var text = "\(entry.quantity) \(entry.name)"
            if let set = entry.setCode {
                text += " (\(set))"
                if let num = entry.collectorNumber { text += " \(num)" }
            }
            return text
        }
        var lines = deck.entries.filter { $0.board == "main" }.map(line)
        let side = deck.entries.filter { $0.board == "sideboard" }
        if !side.isEmpty {
            lines.append("Sideboard:")
            lines += side.map(line)
        }
        let maybe = deck.entries.filter { $0.board == "maybeboard" }
        if !maybe.isEmpty {
            lines.append("Maybeboard:")
            lines += maybe.map(line)
        }
        return lines.joined(separator: "\n")
    }
}
