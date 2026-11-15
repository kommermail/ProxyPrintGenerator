//
//  LibraryView.swift
//  Version 84
//  Proxy Printer (native port) — Phase 4 selector screens
//
//  The deck library home: every saved deck, add by paste or .txt
//  file. A deck opens into its card list; tapping a card opens the
//  printing picker (every Scryfall printing, tap to swap, reset to
//  the imported printing). The bottom bar builds the PDF from the
//  deck exactly as currently arranged.
//
//  App target only (SwiftUI).
//

import SwiftUI
import UniformTypeIdentifiers
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// True on the Mac, where the window is large and sits farther
/// from the eye than a phone. Text and controls sized for iOS
/// read tiny in a full screen Mac window, so the views below bump
/// the small stuff with `isMacUI ? big : small` wherever it
/// matters. iOS sizes are unchanged.
#if os(macOS)
let isMacUI = true
#else
let isMacUI = false
#endif

/// A FileDocument so the save panel can write a card image as a
/// JPEG wherever the user chooses.
struct JPEGFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.jpeg] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws
        -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Re-encodes downloaded card art as a clean JPEG. Returns nil
/// when the bytes are not a readable image at all.
func jpegData(fromImageData data: Data, quality: Double = 0.92)
    -> Data? {
    guard let source = CGImageSourceCreateWithData(
            data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(
            source, 0, nil)
    else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        out, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
        dest, image,
        [kCGImageDestinationLossyCompressionQuality: quality]
            as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

// MARK: - Library home

struct LibraryView: View {
    @StateObject private var store = DeckStore()
    @State private var showTutorial = false
    @State private var showPaste = false
    @State private var showImporter = false
    @State private var importError: String?
    /// Monterey fallback navigation: on macOS 12 there is
    /// no NavigationStack, so the library swaps its panel
    /// for the open deck instead of pushing it.
    @State private var openDeckId: UUID?

    /// The real version, from the app's bundle: the same number
    /// the Windows build and GitHub Releases use (Nov 14, 2026;
    /// it used to count file revisions and read 1.84).
    private var appVersionText: String {
        let v = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        return "Version \(v)"
    }

    var body: some View {
        Group {
            if #available(macOS 13.0, iOS 16.0, *) {
                NavigationStack {
                    libraryPanel
                        .navigationDestination(for: UUID.self) { id in
                            DeckDetailView(deckId: id)
                        }
                }
            } else if let openDeckId {
                DeckDetailView(deckId: openDeckId,
                               onBack: { self.openDeckId = nil })
            } else {
                libraryPanel
            }
        }
        .environmentObject(store)
    }

    /// The deck list panel itself, shared by the modern
    /// navigation stack and the Monterey fallback.
    private var libraryPanel: some View {
        PanelScaffold {
                List {
                    TutorialSticker { showTutorial = true }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .hiddenRowSeparator()
                        .listRowInsets(EdgeInsets(
                            top: 0, leading: 20, bottom: 4,
                            trailing: 20))
                    Menu {
                        Button {
                            showPaste = true
                        } label: {
                            Label("Paste a deck list",
                                  systemImage: "doc.on.clipboard")
                        }
                        Button {
                            showImporter = true
                        } label: {
                            Label("Open a .txt file",
                                  systemImage: "folder")
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 23,
                                              weight: .bold))
                                .foregroundStyle(Theme.ink)
                            PlaqueTitleText(
                                text: "ADD A DECK",
                                size: isMacUI ? 25 : 24)
                        }
                        .padding(.vertical, 13)
                        .frame(width: Theme.plaqueWidth)
                        .background {
                            WashPlaque()
                                .shadow(color: .black.opacity(0.35),
                                        radius: 3, x: 0, y: 2)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .hiddenRowSeparator()
                    .listRowInsets(EdgeInsets(
                        top: 10, leading: 20, bottom: 6,
                        trailing: 20))
                    if store.decks.isEmpty {
                        KingdomText(
                            text: "No decks yet. Use the Add a deck button above: paste a list or open a .txt file.",
                            size: isMacUI ? 20 : 19)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(store.decks) { deck in
                        Group {
                            if #available(macOS 13.0, iOS 16.0, *) {
                                NavigationLink(value: deck.id) {
                                    deckRowLabel(deck: deck)
                                }
                            } else {
                                Button {
                                    openDeckId = deck.id
                                } label: {
                                    deckRowLabel(deck: deck)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .listRowInsets(EdgeInsets(
                            top: 0, leading: 20, bottom: 0,
                            trailing: 20))
                    }
                    .onDelete { store.delete(at: $0) }
                    .listRowBackground(Color.clear)
                    KingdomText(text: appVersionText,
                                size: isMacUI ? 16 : 15)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                        .listRowBackground(Color.clear)
                        .hiddenRowSeparator()
                    #if os(macOS)
                    UpdateControls()
                        .padding(.bottom, 8)
                        .listRowBackground(Color.clear)
                        .hiddenRowSeparator()
                    #endif
                }
                .hiddenScrollBackground()
                .tint(Theme.gold)
                .font(Theme.fellFont(size: isMacUI ? 18 : 16))
                .appMasthead(section: "Deck Library")
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showPaste = true
                        } label: {
                            Label("Paste a deck list",
                                  systemImage: "doc.on.clipboard")
                        }
                        Button {
                            showImporter = true
                        } label: {
                            Label("Open a .txt file",
                                  systemImage: "folder")
                        }
                    } label: {
                        Label("Add deck", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showTutorial) {
                TutorialSheet()
            }
            .sheet(isPresented: $showPaste) {
                PasteDeckSheet { name, text in
                    store.add(name: name, source: "Paste", text: text) != nil
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.plainText]) { outcome in
                if case .success(let url) = outcome {
                    importFile(url)
                }
            }
            .alert("Import failed",
                   isPresented: Binding(
                       get: { importError != nil },
                       set: { if !$0 { importError = nil } })) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
    }

    private func deckRowLabel(deck: SavedDeck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            KingdomText(
                text: deck.name,
                size: isMacUI ? 27 : 23)
            KingdomText(
                text: "\(deck.cardCount) cards · \(deck.source)",
                size: isMacUI ? 20 : 19)
        }
        .frame(maxWidth: .infinity,
               alignment: .leading)
        .padding(.vertical, isMacUI ? 15 : 13)
        .contentShape(Rectangle())
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            importError = "Could not read that file."
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        if store.add(name: name, source: "File", text: text) == nil {
            importError = "No cards were found in that file."
        }
    }
}

// MARK: - Paste a deck

private struct PasteDeckSheet: View {
    /// Returns true when the list parsed into a deck.
    let onAdd: (String, String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var text: String = ""
    @State private var error: String?

    var body: some View {
        NavContainer {
            Form {
                Section("Deck name") {
                    TextField("Name", text: $name)
                }
                Section("Deck list") {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add deck")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = name.trimmingCharacters(
                            in: .whitespaces)
                        if onAdd(trimmed.isEmpty ? "Untitled deck" : trimmed,
                                 text) {
                            dismiss()
                        } else {
                            error = "That list did not parse into any cards."
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Deck detail

private struct PickerTarget: Identifiable {
    let id = UUID()
    let entryIndex: Int
}

private struct ZoomTarget: Identifiable {
    let id = UUID()
    let entryIndex: Int
}

private struct ReplaceTarget: Identifiable {
    let id = UUID()
    let entryIndex: Int
}

/// How one missing face got resolved during loading: an exact
/// printing key to fetch in bulk, or a printing found directly
/// through the search endpoint.
private enum FaceResolution {
    case key(PrintingKey)
    case option(PrintingOption)
}

struct DeckDetailView: View {
    @EnvironmentObject private var store: DeckStore
    let deckId: UUID
    /// Set only by the Monterey fallback navigation, which
    /// has no back button of its own: when present, a
    /// floating Library button returns to the deck list.
    var onBack: (() -> Void)? = nil

    @StateObject private var job = PrintJobModel()
    @State private var pickerTarget: PickerTarget?
    @State private var zoomTarget: ZoomTarget?
    @State private var replaceTarget: ReplaceTarget?
    @State private var faceOptions: [UUID: PrintingOption] = [:]
    @State private var facesSettled = false
    @State private var flippedFaces: Set<UUID> = []
    @State private var pageWidth: CGFloat = 0
    @State private var nameDraft: String = ""
    @State private var showExporter = false
    @State private var showBarOptions = false
    /// The deck list's scroll proxy, captured as the list
    /// appears, so the build bar's Advanced options link
    /// can jump the list straight to Print settings.
    @State private var scrollProxy: ScrollViewProxy?
    @State private var exportDocument: BuildFileDocument?
    @State private var showJPEGExporter = false
    @State private var jpegDocument: JPEGFileDocument?
    @State private var jpegFilename = "card.jpg"
    @State private var savedMessage: String?
    @State private var showEditor = false
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss

    private var deck: SavedDeck? { store.deck(id: deckId) }

    var body: some View {
        Group {
            if let deck {
                Group {
                    if faceOptions.isEmpty && !facesSettled {
                        LeatherBackground()
                    } else {
                        PanelScaffold(bar: {
                            buildBar(deck: deck)
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(Theme.leatherDeep)
                                .tint(Theme.gold)
                                .font(Theme.fellFont(
                                    size: isMacUI ? 16 : 15))
                        }) {
                            deckList(deck)
                        }
                    }
                }
                .sheet(item: $pickerTarget) { target in
                    if deck.entries.indices.contains(target.entryIndex) {
                        PrintingPickerView(
                            entry: deck.entries[target.entryIndex],
                            onPick: { set, num in
                                store.setPrinting(
                                    deckId: deckId,
                                    entryIndex: target.entryIndex,
                                    setCode: set, collectorNumber: num)
                                syncJob()
                            },
                            onReset: {
                                store.resetPrinting(
                                    deckId: deckId,
                                    entryIndex: target.entryIndex)
                                syncJob()
                            })
                    }
                }
                .sheet(item: $zoomTarget) { target in
                    if deck.entries.indices.contains(target.entryIndex) {
                        CardZoomView(
                            entry: deck.entries[target.entryIndex],
                            option: faceOptions[
                                deck.entries[target.entryIndex].id],
                            onPick: { set, num in
                                store.setPrinting(
                                    deckId: deckId,
                                    entryIndex: target.entryIndex,
                                    setCode: set, collectorNumber: num)
                                syncJob()
                            },
                            onReset: {
                                store.resetPrinting(
                                    deckId: deckId,
                                    entryIndex: target.entryIndex)
                                syncJob()
                            },
                            onRevert: {
                                store.revertReplacement(
                                    deckId: deckId,
                                    entryIndex: target.entryIndex)
                                syncJob()
                            })
                    }
                }
                .sheet(item: $replaceTarget) { target in
                    if deck.entries.indices.contains(target.entryIndex) {
                        ReplaceCardView(
                            currentName: deck
                                .entries[target.entryIndex].name,
                            onReplace: { option in
                                store.replaceCard(
                                    deckId: deckId,
                                    entryIndex: target.entryIndex,
                                    name: option.name,
                                    setCode: option.set,
                                    collectorNumber: option
                                        .collectorNumber)
                                syncJob()
                            })
                    }
                }
                .sheet(isPresented: $showEditor) {
                    DeckTextEditorView(deckId: deckId)
                        .environmentObject(store)
                }
                .fileExporter(isPresented: $showExporter,
                              document: exportDocument,
                              contentType: exportDocument?.url
                                  .pathExtension == "zip" ? .zip
                                : exportDocument?.url
                                    .pathExtension == "png" ? .png
                                : exportDocument?.url
                                    .pathExtension == "jpg" ? .jpeg
                                                             : .pdf,
                              defaultFilename: job.result?.outputURL
                                  .lastPathComponent ?? "proxies.pdf") { outcome in
                    switch outcome {
                    case .success(let url):
                        savedMessage = "Saved to \(url.lastPathComponent)"
                    case .failure(let error):
                        job.errorText = "Save failed: \(error)"
                    }
                }
                .fileExporter(isPresented: $showJPEGExporter,
                              document: jpegDocument,
                              contentType: .jpeg,
                              defaultFilename: jpegFilename) { outcome in
                    if case .success = outcome {
                        savedMessage = "Card image saved as JPEG."
                    }
                }
                .onAppear {
                    nameDraft = deck.name
                    job.outputName = deck.name
                        .replacingOccurrences(of: " ", with: "-")
                        .lowercased()
                    syncJob()
                }
                .task(id: deck.entries) {
                    await loadFaces()
                }
            } else {
                KingdomText(text: "This deck is gone.",
                            size: isMacUI ? 20 : 19)
            }
        }
        .overlay(alignment: .topLeading) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    Label("Library", systemImage: "chevron.left")
                        .font(Theme.fellFont(size: isMacUI ? 16 : 15))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Theme.leatherDeep.opacity(0.85)))
                        .foregroundStyle(Theme.gold)
                }
                .buttonStyle(.plain)
                .padding(10)
            }
        }
    }

    /// The deck page's list itself, riding on the floating
    /// suede panel. Kept separate so the page can show nothing
    /// but the leather artwork while card faces are loading.
    private func deckList(_ deck: SavedDeck) -> some View {
        ScrollViewReader { proxy in
        List {
            Section {
                FoilNameplate(
                    name: $nameDraft,
                    subtitle: "\(deck.cardCount) cards · from \(deck.source)",
                    onCommit: {
                        let trimmed = nameDraft
                            .trimmingCharacters(
                                in: .whitespaces)
                        if !trimmed.isEmpty {
                            store.rename(deckId: deckId,
                                         to: trimmed)
                        }
                    })
                    .listRowInsets(EdgeInsets(
                        top: 8, leading: 10,
                        bottom: 8, trailing: 10))
                    .listRowBackground(Color.clear)
                    .hiddenRowSeparator()
                if deck.sideboardCount > 0 {
                    KingdomText(
                        text: "\(deck.sideboardCount) sideboard and maybeboard cards ride along in the list; printing swaps below cover the mainboard.",
                        size: isMacUI ? 19 : 17.5)
                }
            }
            .listRowBackground(Color.clear)




            Section {
                    DeckWideBanner(
                        entries: twoSidedEntries(in: deck),
                        onEdit: { showEditor = true },
                        copyText: { copyDecklistText() },
                        cardCount: deck.cardCount + deck.sideboardCount,
                        onJump: { entry in
                            jumpToTwoSided(entry, deck: deck,
                                           proxy: proxy)
                        })
                    .listRowInsets(EdgeInsets(
                        top: 2, leading: 8,
                        bottom: 6, trailing: 8))
                    .hiddenRowSeparator()
                    .listRowBackground(Color.clear)
                    DeckFacesGrid(
                        pairs: Array(deck.entries.enumerated())
                            .filter { $0.element.board == "main" }
                            .map { (index: $0.offset,
                                    entry: $0.element) },
                        columns: faceColumns,
                        options: faceOptions,
                        flipped: flippedFaces,
                        onFlip: { entry in
                            flippedFaces.formSymmetricDifference(
                                [entry.id])
                        },
                        onZoom: { index in
                            zoomTarget = ZoomTarget(
                                entryIndex: index)
                        },
                        onChangePrinting: { index in
                            pickerTarget = PickerTarget(
                                entryIndex: index)
                        },
                        onReplace: { index in
                            replaceTarget = ReplaceTarget(
                                entryIndex: index)
                        },
                        onRevert: { index in
                            store.revertReplacement(
                                deckId: deckId,
                                entryIndex: index)
                            syncJob()
                        },
                        onSaveJPEG: { entry, url in
                            saveJPEG(entry: entry, url: url)
                        },
                        onRemoveCard: { index in
                            store.removeCard(deckId: deckId,
                                             entryIndex: index)
                            syncJob()
                        })
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        OrnamentCaption(
                            text: facesFooterText(for: deck),
                            size: isMacUI ? 19.5 : 18)
                            .frame(maxWidth: .infinity)
                        if facesSettled,
                           faceOptions.count < deck.entries
                               .filter({ $0.board == "main" })
                               .count {
                            Button("Try again") {
                                Task { await loadFaces() }
                            }
                            .font(isMacUI ? .body : .callout)
                        }
                        // The same copy button again under the
                        // cards, so a long deck needs no scrolling
                        // back up.
                        CopyDecklistButton(
                            copyText: { copyDecklistText() },
                            cardCount: deck.cardCount + deck.sideboardCount,
                            size: isMacUI ? 24 : 21)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 26)
                            .background {
                                WashPlaque()
                                    .shadow(color: .black.opacity(0.35),
                                            radius: 3, x: 0, y: 2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                    }
                }
            Section {
                bigHeader("Print settings")
                    .id("printSettingsTop")
                    .hiddenRowSeparator()
                VStack(alignment: .leading, spacing: 6) {
                    KingdomText(
                        text: "Scale",
                        size: isMacUI ? 20 : 19)
                    FantasySegmentedControl(
                        items: [(1, "300"), (2, "600"),
                                (4, "1200"), (6, "1800")],
                        selection: $job.scale,
                        fontSize: isMacUI ? 16 : 14)
                    OrnamentCaption(text: "Dots per inch",
                                    size: 18)
                        .frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 6) {
                    KingdomText(
                        text: "Format",
                        size: isMacUI ? 20 : 19)
                    FantasySegmentedControl(
                        items: [(.pdf, "PDF"), (.png, "PNG"),
                                (.jpeg, "JPEG")],
                        selection: $job.format,
                        fontSize: isMacUI ? 16 : 14)
                    if job.format == .jpeg {
                        HStack(spacing: 10) {
                            KingdomText(
                                text: "JPEG quality",
                                size: isMacUI ? 19 : 19)
                            Slider(value: $job.jpegQuality,
                                   in: 0.3...0.95)
                                .tint(Theme.gold)
                            KingdomText(
                                text: "\(Int(job.jpegQuality * 100))%",
                                size: isMacUI ? 19 : 19)
                                .frame(width: 46,
                                       alignment: .trailing)
                        }
                    }
                    OrnamentCaption(text: jobFormatCaption,
                                    size: 18)
                        .frame(maxWidth: .infinity)
                }
                HStack(spacing: 18) {
                    Toggle(isOn: $job.guides) {
                        KingdomText(text: "Cutting guides",
                                    size: isMacUI ? 20 : 19)
                    }
                    Toggle(isOn: $job.thickGuides) {
                        KingdomText(text: "Thick guides",
                                    size: isMacUI ? 20 : 19)
                    }
                    .disabled(!job.guides)
                }
                .frame(maxWidth: .infinity,
                       alignment: .center)
                Toggle(isOn: $job.shuffleBeforeRender) {
                    KingdomText(text: "Shuffle before rendering",
                                size: isMacUI ? 20 : 19)
                }
                HideawayGroup(title: "Low ink calibration",
                              summary: job.calibrationSummary) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $job.useCalibration) {
                            KingdomText(text: "Use low ink calibration",
                                        size: isMacUI ? 20 : 19)
                        }
                        if job.useCalibration {
                            jobBoostSlider("Cyan boost", $job.cyanBoost)
                            jobBoostSlider("Magenta boost", $job.magentaBoost)
                            jobBoostSlider("Yellow boost", $job.yellowBoost)
                        }
                    }
                }
                HStack {
                    Spacer()
                    RealismSticker(isOn: job.autoVibrance) {
                        job.autoVibrance.toggle()
                    }
                    Spacer()
                }
                OrnamentCaption(
                    text: job.autoVibrance
                        ? "Auto is on: 40% vibrance and 12% midtone lift. The two sliders sit this one out."
                        : "Auto is off: tap the sticker to make your prints pop.",
                    size: 16)
                    .frame(maxWidth: .infinity)
                jobVibranceSlider($job.vibrance)
                    .disabled(job.autoVibrance)
                    .opacity(job.autoVibrance ? 0.45 : 1)
                jobMidtoneSlider($job.midtoneLift)
                    .disabled(job.autoVibrance)
                    .opacity(job.autoVibrance ? 0.45 : 1)
                HStack {
                    KingdomText(text: "Paper",
                                size: isMacUI ? 20 : 19)
                    Spacer()
                    Picker("", selection: $job.paper) {
                        Text("Letter").tag(PaperSize.letter)
                        Text("A4").tag(PaperSize.a4)
                        Text("Legal").tag(PaperSize.legal)
                        Text("11 by 17").tag(PaperSize.tabloid)
                        Text("A3").tag(PaperSize.a3)
                        Text("Custom").tag(
                            PaperSize.custom(widthMM: 216,
                                             heightMM: 279))
                    }
                    .labelsHidden()
                    .frame(width: isMacUI ? 190 : 170)
                    .pickerChip()
                }
                OrnamentCaption(text: job.paperCaption,
                                size: 16)
                if job.paper.isCustom {
                    HStack {
                        KingdomText(text: "Paper width (mm)",
                                    size: isMacUI ? 20 : 19)
                        Spacer()
                        KingdomText(
                            text: String(
                                format: "%.0f",
                                job.customPaperWidthMM),
                            size: isMacUI ? 20 : 19)
                        Stepper("",
                                value: $job.customPaperWidthMM,
                                in: 100...500, step: 1)
                            .labelsHidden()
                    }
                    HStack {
                        KingdomText(text: "Paper height (mm)",
                                    size: isMacUI ? 20 : 19)
                        Spacer()
                        KingdomText(
                            text: String(
                                format: "%.0f",
                                job.customPaperHeightMM),
                            size: isMacUI ? 20 : 19)
                        Stepper("",
                                value: $job.customPaperHeightMM,
                                in: 100...700, step: 1)
                            .labelsHidden()
                    }
                }
                HideawayGroup(title: "Print options",
                              summary: job.printOptionsSummary) {
                    VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $job.backToBack) {
                    KingdomText(text: "Two sided back to back",
                                size: isMacUI ? 20 : 19)
                }
                HStack {
                    KingdomText(text: "Shift up (mm)",
                                size: isMacUI ? 20 : 19)
                    Spacer()
                    KingdomText(
                        text: String(format: "%.1f", job.shiftUpMM),
                        size: isMacUI ? 20 : 19)
                    Stepper("", value: $job.shiftUpMM,
                            in: 0...4, step: 0.5)
                        .labelsHidden()
                }
                HStack {
                    KingdomText(text: "Extra gap (mm)",
                                size: isMacUI ? 20 : 19)
                    Spacer()
                    KingdomText(
                        text: String(format: "%.2f", job.extraGapMM),
                        size: isMacUI ? 20 : 19)
                    Stepper("", value: $job.extraGapMM,
                            in: 0...2, step: 0.25)
                        .labelsHidden()
                }
                HStack {
                    KingdomText(text: "Safe area",
                                size: isMacUI ? 20 : 19)
                    Spacer()
                    FantasySegmentedControl(
                        items: [(.off, "Off"),
                                (.fit, "Fit to my printer")],
                        selection: $job.marginMode,
                        fontSize: isMacUI ? 15 : 13)
                        .frame(width: isMacUI ? 280 : 240)
                }
                Toggle(isOn: $job.maximizeGap) {
                    KingdomText(text: "Max gap",
                                size: isMacUI ? 20 : 19)
                }
                if job.maximizeGap {
                    OrnamentCaption(
                        text: job.resolvedGapCaption,
                        size: 16)
                }
#if os(macOS)
                Group {
                    if job.marginMode == .fit {
                        HStack {
                            KingdomText(text: "Printer",
                                        size: isMacUI ? 20 : 19)
                            Spacer()
                            Picker("", selection: $job.fitPrinter) {
                                ForEach(job.printerNames,
                                        id: \.self) { name in
                                    Text(name).tag(Optional(name))
                                }
                            }
                            .labelsHidden()
                            .frame(width: isMacUI ? 190 : 170)
                            .pickerChip()
                            .onChange(of: job.fitPrinter) { _ in
                                job.fitPrinterPicked()
                            }
                        }
                        if !job.fitStatus.isEmpty {
                            if job.fitStatusIsSuccess {
                                SuccessCaption(
                                    text: job.fitStatus,
                                    size: 17)
                            } else {
                                OrnamentCaption(
                                    text: job.fitStatus,
                                    size: 16)
                            }
                        }
                        Button {
                            job.refreshFit(adoptPaper: false)
                        } label: {
                            KingdomText(text: "Read again",
                                        size: 16)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onChange(of: job.marginMode) { _ in
                    job.fitToggled()
                }
                .onChange(of: job.paper) { _ in
                    job.fitPaperPicked()
                }
                .onAppear {
                    job.fitAppeared()
                }
#endif
                    }
                }
                HStack {
                    KingdomText(text: "Proxy mark",
                                size: isMacUI ? 20 : 19)
                    Spacer()
                }
                FantasySegmentedControl(
                    items: [(.none, "Off"),
                            (.label, "Label"),
                            (.logo, "Fox"),
                            (.border, "Border")],
                    selection: $job.markKind,
                    fontSize: isMacUI ? 15 : 13)
                if job.markKind != .none {
                    HStack(spacing: 8) {
                        KingdomText(text: "Mark color",
                                    size: isMacUI ? 20 : 19)
                        Spacer()
                        ForEach(PrintJobModel.markPalette.indices,
                                id: \.self) { index in
                            let swatch = PrintJobModel
                                .markPalette[index]
                            Circle()
                                .fill(Color(
                                    red: Double(swatch.color.r) / 255,
                                    green: Double(swatch.color.g) / 255,
                                    blue: Double(swatch.color.b) / 255))
                                .frame(width: 20, height: 20)
                                .overlay(
                                    Circle().stroke(
                                        job.markColor == swatch.color
                                            ? Theme.gold
                                            : Color.black.opacity(0.3),
                                        lineWidth: job.markColor == swatch.color
                                            ? 2.5 : 1))
                                .onTapGesture {
                                    job.markColor = swatch.color
                                }
                        }
                    }
                }
                if job.markKind == .label {
                    HStack {
                        KingdomText(text: "Mark font",
                                    size: isMacUI ? 20 : 19)
                        Spacer()
                        Picker("", selection: $job.markFont) {
                            Text("Cinzel").tag(MarkFont.cinzel)
                            Text("Cinzel Decorative").tag(
                                MarkFont.cinzelDecorative)
                            Text("Fell English").tag(
                                MarkFont.fellEnglish)
                            Text("Fell English Italic").tag(
                                MarkFont.fellEnglishItalic)
                            Text("Faerie Moot").tag(
                                MarkFont.faerieMoot)
                        }
                        .labelsHidden()
                        .frame(width: isMacUI ? 230 : 210)
                        .pickerChip()
                    }
                }
                if job.markKind == .label
                    || job.markKind == .logo {
                    HStack {
                        KingdomText(text: "Mark spot",
                                    size: isMacUI ? 20 : 19)
                        Spacer()
                        Picker("", selection: $job.markPosition) {
                            Text("Top left").tag(MarkPosition.topLeft)
                            Text("Top middle").tag(MarkPosition.top)
                            Text("Top right").tag(MarkPosition.topRight)
                            Text("Middle left").tag(MarkPosition.middleLeft)
                            Text("Middle").tag(MarkPosition.middle)
                            Text("Middle right").tag(MarkPosition.middleRight)
                            Text("Bottom left").tag(MarkPosition.bottomLeft)
                            Text("Bottom middle").tag(MarkPosition.bottom)
                            Text("Bottom right").tag(MarkPosition.bottomRight)
                        }
                        .labelsHidden()
                        .frame(width: isMacUI ? 230 : 210)
                        .pickerChip()
                    }
                }
                if job.markKind == .border {
                    HStack {
                        KingdomText(text: "Border width (mm)",
                                    size: isMacUI ? 20 : 19)
                        Spacer()
                        KingdomText(
                            text: String(format: "%.1f",
                                         job.markBorderMM),
                            size: isMacUI ? 20 : 19)
                        Stepper("", value: $job.markBorderMM,
                                in: 1...6, step: 0.5)
                            .labelsHidden()
                    }
                }
                if job.markKind != .none {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            ProxyMarkPreview(mark: job.proxyMark)
                            OrnamentCaption(
                                text: "Preview: the mark on a card, in its spot",
                                size: 16)
                        }
                        Spacer()
                    }
                }
            }
            .listRowBackground(Color.clear)

            if let result = job.result {
                Section {
                    bigHeader("Finished")
                        .hiddenRowSeparator()
                    KingdomText(
                        text: "\(result.frontCount) card fronts, \(result.pageCount) pages",
                        size: isMacUI ? 19 : 19)
                    if result.backCount > 0 {
                        KingdomText(
                            text: "Two sided backs: \(result.backNames.joined(separator: ", "))",
                            size: isMacUI ? 19 : 19)
                    }
                    KingdomText(
                        text: "Size: \(ByteCountFormatter.string(fromByteCount: Int64(result.sizeBytes), countStyle: .file))",
                        size: isMacUI ? 19 : 19)
                    if let savedMessage {
                        KingdomText(text: savedMessage,
                                    size: isMacUI ? 19 : 18)
                    }
                }
                .listRowBackground(Color.clear)
            }

            if let errorText = job.errorText {
                Section {
                    Text(errorText).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                .listRowBackground(Color.clear)
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    KingdomText(text: "DELETE THIS DECK",
                                size: isMacUI ? 19 : 18)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Color.clear)
        }
        .confirmationDialog(
            "Delete this deck?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete deck", role: .destructive) {
                store.deleteDeck(id: deckId)
                dismiss()
                onBack?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The deck is removed from your library. This cannot be undone.")
        }
        .hiddenScrollBackground()
        .foregroundStyle(Theme.ink)
        .tint(Theme.gold)
        .font(Theme.fellFont(size: isMacUI ? 19 : 17))
        .navigationTitle(deck.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { pageWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { newWidth in
                        pageWidth = newWidth
                    }
            }
        )
        .onAppear { scrollProxy = proxy }
        }
    }

    /// The whole list, sideboard and all, as "1 Plains (TRK) 361"
    /// lines, with the printings Scryfall resolved for the grid.
    private func copyDecklistText() -> String? {
        guard let deck else { return nil }
        return DeckStore.exportText(for: deck, resolved: faceOptions)
    }

    /// The deck's two sided cards, in deck order: the ones the
    /// faces fetch found a real back face for.
    private func twoSidedEntries(in deck: SavedDeck)
        -> [SavedCardLine] {
        deck.entries.filter {
            $0.board == "main"
                && faceOptions[$0.id]?.hasBackFace == true
        }
    }

    /// Banner tap: scroll the faces wall so the card's row is
    /// centered, then flip the card over to its back if it is
    /// not already showing it.
    private func jumpToTwoSided(_ entry: SavedCardLine,
                                deck: SavedDeck,
                                proxy: ScrollViewProxy) {
        let main = deck.entries.filter { $0.board == "main" }
        if let pos = main.firstIndex(where: { $0.id == entry.id }) {
            let rowStart = pos / faceColumns * faceColumns
            withAnimation {
                proxy.scrollTo(main[rowStart].id, anchor: .center)
            }
        }
        if !flippedFaces.contains(entry.id) {
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                flippedFaces.insert(entry.id)
            }
        }
    }

    /// How many face tiles fit across the page, from the window
    /// width: two across on a phone, up to six across on a wide
    /// Mac window, with tiles sized to feel generous rather
    /// than squeezed.
    private var faceColumns: Int {
        #if os(macOS)
        let target: CGFloat = 245
        #else
        let target: CGFloat = 150
        #endif
        guard pageWidth > 0 else { return 3 }
        return min(6, max(2, Int(pageWidth / target)))
    }

    /// Section headers for the deck page, in a larger style than
    /// the system default so the page structure reads at a glance.
    private func bigHeader(_ title: String) -> some View {
        SpectacularHeader(title: title)
    }

    /// One line under the deck page's format picker saying what
    /// the chosen format gets you.
    private var jobFormatCaption: String {
        switch job.format {
        case .pdf:
            return "One printable PDF at full quality"
        case .png:
            return "Every page stitched into one tall PNG at full quality"
        case .jpeg:
            return "Every page stitched into one tall JPEG. Quality down, file down"
        }
    }

    /// One ink boost as a wide slider with a big label, in place
    /// of the cramped system stepper.
    private func jobBoostSlider(_ label: String,
                                _ value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            KingdomText(text: label,
                        size: isMacUI ? 20 : 20)
                .frame(width: isMacUI ? 124 : 116,
                       alignment: .leading)
            Slider(value: value, in: 0.8...1.6)
                .tint(Theme.gold)
            KingdomText(
                text: String(format: "%.2fx",
                             value.wrappedValue),
                size: isMacUI ? 20 : 20)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func jobVibranceSlider(_ value: Binding<Double>)
        -> some View {
        HStack(spacing: 10) {
            KingdomText(text: "Vibrance",
                        size: isMacUI ? 20 : 20)
                .frame(width: isMacUI ? 124 : 116,
                       alignment: .leading)
            Slider(value: value, in: 0...0.6, step: 0.05)
                .tint(Theme.gold)
            KingdomText(
                text: "+\(Int((value.wrappedValue * 100).rounded()))%",
                size: isMacUI ? 20 : 20)
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func jobMidtoneSlider(_ value: Binding<Double>)
        -> some View {
        HStack(spacing: 10) {
            KingdomText(text: "Midtone lift",
                        size: isMacUI ? 20 : 20)
                .frame(width: isMacUI ? 124 : 116,
                       alignment: .leading)
            Slider(value: value, in: 0...0.35, step: 0.01)
                .tint(Theme.gold)
            KingdomText(
                text: "+\(Int((value.wrappedValue * 100).rounded()))%",
                size: isMacUI ? 20 : 20)
                .frame(width: 56, alignment: .trailing)
        }
    }

    /// Footer for the faces section. While faces are still
    /// arriving it says how many have landed, so a slow load reads
    /// as progress rather than failure.
    private func facesFooterText(for deck: SavedDeck) -> String {
        let total = deck.entries.filter { $0.board == "main" }.count
        let hint = "Tap any card to flip it: two sided cards "
            + "show their real back."
        if faceOptions.count < total {
            if facesSettled {
                return "\(total - faceOptions.count) cards could not "
                    + "be matched to a printing. " + hint
            }
            return "Loading card faces: \(faceOptions.count) of "
                + "\(total) so far. " + hint
        }
        return hint
    }

    private func syncJob() {
        guard let deck = store.deck(id: deckId) else { return }
        job.deckText = DeckStore.deckText(for: deck)
    }

    /// Fetches the card image picked in a tile or row menu and
    /// offers it through the save panel as a JPEG.
    private func saveJPEG(entry: SavedCardLine, url: URL?) {
        guard let url else {
            savedMessage = "That card has no image loaded yet."
            return
        }
        Task {
            do {
                let (data, _) = try await URLSession.shared
                    .data(from: url)
                let jpeg = jpegData(fromImageData: data) ?? data
                jpegDocument = JPEGFileDocument(data: jpeg)
                jpegFilename = entry.name
                    .replacingOccurrences(of: "/", with: "-")
                    + ".jpg"
                showJPEGExporter = true
            } catch {
                savedMessage = "Could not fetch that card image."
            }
        }
    }

    /// Loads image data for every mainboard card in the deck.
    /// Cards whose lines name an exact printing resolve in a couple
    /// of batched requests. Everything else (bare name lines, and
    /// identifiers Scryfall does not match) resolves by name, the
    /// same way the print engine resolves them at build time, so
    /// what the faces view shows is what will print. Results are
    /// keyed by entry, so two lines for the same card can show
    /// different printings.
    private func loadFaces() async {
        facesSettled = false
        guard let deck = store.deck(id: deckId) else { return }
        let main = deck.entries.filter { $0.board == "main" }
        var loaded: [UUID: PrintingOption] = [:]

        // Pass 1: exact printings, batched.
        let exactKeys = Array(Set(
            main.filter { $0.setCode != nil && $0.collectorNumber != nil }
                .map { PrintingKey(set: $0.setCode!,
                                   collectorNumber: $0.collectorNumber!) }))
        var fetched: [PrintingKey: PrintingOption] = [:]
        if !exactKeys.isEmpty {
            fetched = (try? await PrintingsClient.options(
                for: exactKeys)) ?? [:]
        }
        for entry in main {
            guard let set = entry.setCode,
                  let num = entry.collectorNumber else { continue }
            if let option = fetched[PrintingKey(set: set,
                                                collectorNumber: num)] {
                loaded[entry.id] = option
            }
        }
        // Show what is ready right away. The name lookups below can
        // take a while on a fresh list, and cards that already
        // resolved should not wait for them.
        faceOptions = loaded

        // Pass 2: resolve whatever is still missing. First ask
        // for all the names at once, in batched search requests:
        // a whole deck costs one or two requests, which keeps
        // clear of the rate limits that per card lookups trip.
        // Only bare name lines settle here: a line that names a
        // set stays missing on purpose, because the batch search
        // answers with Scryfall's default printing, which may
        // live in another set. The per card pass below resolves
        // those through the named endpoint with their set, the
        // same lookup the print engine runs, so the preview
        // shows the printing that will actually print.
        let missing = main.filter { loaded[$0.id] == nil }
        if !missing.isEmpty {
            let uniqueNames = Array(Set(missing.map(\.name)))
            if let byName = try? await PrintingsClient.resolveByNames(
                uniqueNames) {
                let lookup = Dictionary(
                    uniqueKeysWithValues: byName.map {
                        ($0.key.lowercased(), $0.value)
                    })
                var changed = false
                for entry in missing where entry.setCode == nil {
                    if let option = lookup[entry.name.lowercased()] {
                        loaded[entry.id] = option
                        changed = true
                    }
                }
                if changed {
                    faceOptions = loaded
                }
            }
        }

        // Backstop: whatever the batch left behind goes through
        // the per card path, six at a time. Previews get a short
        // retry ladder (the full one can burn two minutes per
        // card against a rate limit), a named lookup that fails
        // with a set gets one more try without it, and a card the
        // named endpoint will not give up falls back to the
        // printing search the picker uses.
        let stillMissing = main.filter { loaded[$0.id] == nil }
        if !stillMissing.isEmpty {
            let client = ScryfallClient()
            var start = 0
            while start < stillMissing.count {
                let chunk = Array(
                    stillMissing[start..<min(start + 6,
                                              stillMissing.count)])
                var chunkKeys: [UUID: PrintingKey] = [:]
                var changed = false
                await withTaskGroup(
                    of: (UUID, FaceResolution?).self
                ) { group in
                    for entry in chunk {
                        group.addTask {
                            var named = try? await client.lookupNamed(
                                name: entry.name, set: entry.setCode,
                                maxAttempts: 2)
                            if named == nil, entry.setCode != nil {
                                named = try? await client.lookupNamed(
                                    name: entry.name, set: nil,
                                    maxAttempts: 2)
                            }
                            if let card = named {
                                return (entry.id, FaceResolution.key(
                                    PrintingKey(
                                        set: card.set,
                                        collectorNumber:
                                            card.collectorNumber)))
                            }
                            if let printings = try? await PrintingsClient
                                .allPrintings(of: entry.name),
                               !printings.isEmpty {
                                let pick = printings.first {
                                    $0.set == entry.setCode
                                } ?? printings[0]
                                return (entry.id, FaceResolution.option(
                                    pick))
                            }
                            return (entry.id, nil)
                        }
                    }
                    for await (entryID, resolution) in group {
                        switch resolution {
                        case .key(let key):
                            chunkKeys[entryID] = key
                        case .option(let option):
                            loaded[entryID] = option
                            changed = true
                        case nil:
                            break
                        }
                    }
                }
                // Publish each chunk as it lands instead of waiting
                // for every name in the deck to resolve.
                if !chunkKeys.isEmpty,
                   let extra = try? await PrintingsClient.options(
                       for: Array(Set(chunkKeys.values))) {
                    for entry in chunk {
                        if let key = chunkKeys[entry.id],
                           let option = extra[key] {
                            loaded[entry.id] = option
                            changed = true
                        }
                    }
                }
                if changed {
                    faceOptions = loaded
                }
                start += chunk.count
            }
        }

        faceOptions = loaded
        facesSettled = true
    }

    @ViewBuilder
    private func buildBar(deck: SavedDeck) -> some View {
        // The PNG gate, from data the page already has:
        // the deck's own entries, and the two sided flags
        // the preview fetch resolved.
        let totalCards = deck.entries.reduce(0) {
            $0 + $1.quantity
        }
        // Back to back prints a back behind every copy, so
        // its count follows quantities; the classic layout
        // prints one back per two sided card.
        let twoSidedCards = deck.entries.filter {
            faceOptions[$0.id]?.hasBackFace == true
        }.reduce(0) { $0 + (job.backToBack ? $1.quantity : 1) }
        let pngRefused = job.pngRefused(cards: totalCards,
                                        twoSided: twoSidedCards)
        VStack(spacing: 6) {
            if showBarOptions && !job.isRunning {
#if os(macOS)
                // The Mac bar has the whole window width to work
                // with, so the options spread out in one row at
                // desktop sizes instead of stacking like a phone.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 26) {
                        HStack(spacing: 8) {
                            KingdomText(text: "Scale", size: 20)
                            FantasySegmentedControl(
                                items: [(1, "300"), (2, "600"),
                                        (4, "1200"), (6, "1800")],
                                selection: $job.scale,
                                fontSize: 16,
                                unselectedColor: Theme.parchment)
                                .frame(width: 320)
                        }
                        Toggle(isOn: $job.guides) {
                            KingdomText(text: "Guides", size: 19)
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        KingdomText(text: "Format", size: 20)
                        FantasySegmentedControl(
                            items: [(.pdf, "PDF"), (.png, "PNG"),
                                    (.jpeg, "JPEG")],
                            selection: $job.format,
                            fontSize: 16,
                            unselectedColor: Theme.parchment)
                            .frame(width: 300)
                        if job.format == .jpeg {
                            KingdomText(text: "Quality", size: 19)
                            Slider(value: $job.jpegQuality,
                                   in: 0.3...0.95)
                                .tint(Theme.gold)
                                .frame(width: 150)
                            KingdomText(
                                text: "\(Int(job.jpegQuality * 100))%",
                                size: 19)
                        }
                        Spacer()
                    }
                }
                .font(Theme.fellFont(size: 16))
                .foregroundStyle(Theme.parchment)
#else
                VStack(spacing: 4) {
                    FantasySegmentedControl(
                        items: [(1, "300"), (2, "600"),
                                (4, "1200"), (6, "1800")],
                        selection: $job.scale,
                        fontSize: 14,
                        unselectedColor: Theme.parchment)
                    FantasySegmentedControl(
                        items: [(.pdf, "PDF"), (.png, "PNG"),
                                (.jpeg, "JPEG")],
                        selection: $job.format,
                        fontSize: 14,
                        unselectedColor: Theme.parchment)
                    if job.format == .jpeg {
                        HStack(spacing: 10) {
                            KingdomText(text: "JPEG quality",
                                        size: 18)
                            Slider(value: $job.jpegQuality,
                                   in: 0.3...0.95)
                                .tint(Theme.gold)
                            KingdomText(
                                text: "\(Int(job.jpegQuality * 100))%",
                                size: 18)
                                .frame(width: 46,
                                       alignment: .trailing)
                        }
                    }
                    HStack {
                        Toggle(isOn: $job.guides) {
                            KingdomText(text: "Guides", size: 18)
                        }
                    }
                }
                .foregroundStyle(Theme.parchment)
#endif
            }
            if !job.isRunning {
                HStack(spacing: 10) {
                    Text("FILE NAME")
                        .font(Theme.plaqueFont(
                            size: isMacUI ? 15 : 13))
                        .foregroundStyle(Theme.gold)
                    TextField("File name", text: $job.outputName)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.fellFont(
                            size: isMacUI ? 20 : 18))
                        .multilineTextAlignment(.center)
                        .colorScheme(.light)
                }
            }
            if job.isRunning {
                ProgressView(value: job.fraction)
                HStack {
                    KingdomText(text: job.errorText
                                        ?? job.stageText,
                                size: isMacUI ? 19 : 19)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Cancel", role: .destructive) { job.cancel() }
                        .controlSize(isMacUI ? .large : .regular)
                }
            } else if let result = job.result {
                HStack(spacing: 10) {
                    Button {
                        exportDocument = BuildFileDocument(url: result.outputURL)
                        showExporter = true
                    } label: {
                        Label(job.format == .pdf ? "Save PDF"
                              : job.format == .png ? "Save PNG"
                                                 : "Save JPEG",
                              systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FantasyButtonStyle(
                        fontSize: isMacUI ? 19 : 17))
                    FileShareButton(url: result.outputURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buildControlSize()
                }
                if job.format == .pdf {
                    PrintJobButtons(model: job, result: result,
                                    message: $savedMessage)
                }
                Button("Build again") {
                    savedMessage = nil
                    job.start()
                }
                .controlSize(isMacUI ? .large : .regular)
                .disabled(!job.canRun)
            } else {
                ZStack {
                    Button {
                        savedMessage = nil
                        job.start()
                    } label: {
                        Text(job.format == .pdf
                             ? "Build PDF"
                             : "Build \(job.format.label)")
                    }
                    .buttonStyle(FantasyButtonStyle(
                        fontSize: isMacUI ? 23 : 20))
                    .disabled(!job.canRun || pngRefused)
                    if pngRefused {
                        Image(systemName: "xmark")
                            .font(.system(size: 30,
                                          weight: .black))
                            .foregroundStyle(.red)
                            .shadow(color: .black.opacity(0.6),
                                    radius: 2)
                            .allowsHitTesting(false)
                    }
                }
                .help(pngRefused
                      ? job.pngLimitNotice(
                            cards: totalCards,
                            twoSided: twoSidedCards)
                      : "")
            }
            if !job.isRunning, !job.sizeCaption.isEmpty {
                KingdomText(text: job.sizeCaption,
                            size: isMacUI ? 16 : 15)
            }
            if !job.isRunning, let warning = job.pngWarning {
                Text(warning)
                    .foregroundStyle(.orange)
                    .font(isMacUI ? .body : .callout)
                    .multilineTextAlignment(.center)
            }
            if !job.isRunning, pngRefused {
                Text(job.pngLimitNotice(
                        cards: totalCards,
                        twoSided: twoSidedCards))
                    .foregroundStyle(.orange)
                    .font(isMacUI ? .body : .callout)
                    .multilineTextAlignment(.center)
            }
            if !job.isRunning, job.format == .png,
               pngRefused || job.pngOverride {
                GuardedOverride(isOn: $job.pngOverride)
            }
            if !job.isRunning {
                HStack(spacing: 26) {
                    Button {
                        withAnimation { showBarOptions.toggle() }
                    } label: {
                        Label(showBarOptions
                                  ? "Hide quick options"
                                  : "Quick options",
                              systemImage: showBarOptions
                                  ? "chevron.down" : "chevron.up")
                            .font(isMacUI ? .body : .callout)
                    }
                    .controlSize(isMacUI ? .large : .regular)
                    Button {
                        withAnimation {
                            scrollProxy?.scrollTo(
                                "printSettingsTop", anchor: .top)
                        }
                    } label: {
                        Label("Advanced options",
                              systemImage: "slider.horizontal.3")
                            .font(isMacUI ? .body : .callout)
                    }
                    .controlSize(isMacUI ? .large : .regular)
                }
            }
        }
    }
}

// MARK: - Printing picker

struct PrintingPickerView: View {
    let entry: SavedCardLine
    let onPick: (String, String) -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options: [PrintingOption] = []
    @State private var loading = true
    @State private var errorText: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        NavContainer {
            Group {
                if loading {
                    ProgressView("Loading printings…")
                } else if let errorText {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .padding()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(options) { option in
                                PrintingCell(
                                    option: option,
                                    isCurrent: option.set == entry.setCode
                                        && option.collectorNumber
                                            == entry.collectorNumber,
                                    onTap: {
                                        onPick(option.set,
                                               option.collectorNumber)
                                        dismiss()
                                    })
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(entry.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if entry.isAltPrinting {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Reset to imported") {
                            onReset()
                            dismiss()
                        }
                    }
                }
            }
        }
        .background(LeatherBackground())
        .font(Theme.fellFont(size: isMacUI ? 16 : 15))
        .task {
            do {
                options = try await PrintingsClient.allPrintings(
                    of: entry.name)
                if options.isEmpty {
                    errorText = "Scryfall lists no printings for this card."
                }
            } catch {
                errorText = "\(error)"
            }
            loading = false
        }
    }
}

// MARK: - One printing in the picker grid

/// Kept as its own small view: the inline version of this cell was
/// complex enough that the compiler could not type check it in
/// reasonable time.
private struct PrintingCell: View {
    let option: PrintingOption
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                cardImage
                Text(option.setAndNumber)
                    .font(Theme.fellFont(size: 13.5))
                    .foregroundStyle(Theme.parchment)
                if isCurrent {
                    Text("Current")
                        .font(.caption2.bold())
                        .foregroundStyle(Theme.gold)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var cardImage: some View {
        AsyncImage(url: option.displayImageURL) { phase in
            Group {
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                        if phase.error == nil {
                            VStack(spacing: 6) {
                                ProgressView()
                                Text("Loading\u{2026}")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .aspectRatio(63.0 / 88.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isCurrent ? Color.accentColor : Color.clear,
                        lineWidth: 3))
    }
}

/// The card shaped stand-in shown while a card image
/// is on its way: a spinner and the word Loading, so a
/// slow image never reads as a broken tile. (Liam,
/// Nov 13, 2026: it should say loading when loading
/// the card images, or people will ask what is
/// happening here.)
private struct CardLoadingPlaceholder: View {
    var cornerRadius: CGFloat = 6

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.secondary.opacity(0.15))
            VStack(spacing: 6) {
                ProgressView()
                Text("Loading\u{2026}")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(63.0 / 88.0, contentMode: .fit)
    }
}

// MARK: - Faces grid

/// Gold letters with a black outline, for the two sided tile
/// badge: four black copies offset behind one gold copy.
private struct OutlinedBadgeText: View {
    let text: String

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                Text(text)
                    .foregroundStyle(.black)
                    .offset(x: [0.8, -0.8, 0, 0][i],
                            y: [0, 0, 0.8, -0.8][i])
            }
            Text(text)
                .foregroundStyle(
                    Color(red: 1.0, green: 0.85, blue: 0.35))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// The deck page banner: one wide wash plaque spanning
/// the suede, holding the EDIT THIS DECK button and, under
/// a gold rule, every two sided card in the deck by name.
/// The name list scrolls inside the banner, so a deck full
/// of two sided cards cannot eat the page. Tapping a name
/// jumps the wall to that card and flips it to its back.
/// The system clipboard, on the Mac and on iOS.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// Copy Decklist, mirrored from the Windows build (Nov 14,
/// 2026): copies every card with its printing, like
/// "1 Plains (TRK) 361", then says COPIED for a moment.
/// Both labels share one spot, so the shorter one never
/// makes the row jump.
private struct CopyDecklistButton: View {
    let copyText: () -> String?
    let cardCount: Int
    let size: CGFloat
    @State private var copied = false
    @State private var token = 0

    var body: some View {
        Button {
            guard let text = copyText() else { return }
            Clipboard.copy(text)
            copied = true
            token += 1
            let mine = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if token == mine { copied = false }
            }
        } label: {
            ZStack {
                label(icon: "doc.on.doc", text: "COPY DECKLIST")
                    .opacity(copied ? 0 : 1)
                label(icon: "checkmark",
                      text: "COPIED \(cardCount) CARD"
                        + (cardCount == 1 ? "" : "S"))
                    .opacity(copied ? 1 : 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy every card with its printing, like \"1 Plains (TRK) 361\", ready to paste anywhere")
        .accessibilityLabel(copied ? "Copied" : "Copy decklist")
    }

    private func label(icon: String, text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.ink)
            PlaqueTitleText(text: text, size: size)
        }
    }
}

private struct DeckWideBanner: View {
    let entries: [SavedCardLine]
    let onEdit: () -> Void
    /// The deck list to copy, built when the button is
    /// clicked so it carries the printings resolved by then.
    let copyText: () -> String?
    let cardCount: Int
    let onJump: (SavedCardLine) -> Void

    /// Five names tall at most; more than that scrolls.
    private var listHeight: CGFloat {
        CGFloat(min(entries.count, 5)) * 27
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: isMacUI ? 28 : 12) {
                Button {
                    onEdit()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "pencil")
                            .font(.system(size: 21,
                                          weight: .bold))
                            .foregroundStyle(Theme.ink)
                        PlaqueTitleText(
                            text: "EDIT THIS DECK",
                            size: isMacUI ? 24 : 19)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add, remove or change the cards in this deck")
                CopyDecklistButton(copyText: copyText,
                                   cardCount: cardCount,
                                   size: isMacUI ? 24 : 19)
            }
            .frame(maxWidth: .infinity)
            if !entries.isEmpty {
                Rectangle()
                    .fill(Theme.gold.opacity(0.5))
                    .frame(height: 1.5)
                    .padding(.horizontal, 6)
                PlaqueTitleText(
                    text: "\(entries.count) TWO SIDED "
                        + (entries.count == 1
                            ? "CARD" : "CARDS"),
                    size: isMacUI ? 22 : 20)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(entries) { entry in
                            Button {
                                onJump(entry)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName:
                                            "arrow.2.squarepath")
                                        .font(.system(
                                            size: 13,
                                            weight: .bold))
                                        .foregroundStyle(
                                            Theme.gold)
                                    KingdomText(
                                        text: entry.name,
                                        size: isMacUI
                                            ? 19 : 17.5)
                                    if entry.quantity > 1 {
                                        KingdomText(
                                            text: "×\(entry.quantity)",
                                            size: isMacUI
                                                ? 19 : 17.5)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity,
                           alignment: .leading)
                }
                .frame(height: listHeight)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background { WidePlaque() }
        .frame(maxWidth: .infinity)
    }
}

private struct DeckFacesGrid: View {
    let pairs: [(index: Int, entry: SavedCardLine)]
    let columns: Int
    let options: [UUID: PrintingOption]
    let flipped: Set<UUID>
    let onFlip: (SavedCardLine) -> Void
    let onZoom: (Int) -> Void
    let onChangePrinting: (Int) -> Void
    let onReplace: (Int) -> Void
    let onRevert: (Int) -> Void
    let onSaveJPEG: (SavedCardLine, URL?) -> Void
    let onRemoveCard: (Int) -> Void

    /// The cards dealt out a row at a time, `columns` to a row.
    /// This view sits inside a List section, and a lazy grid inside
    /// a single list row builds every tile at once, which flooded
    /// the page with a hundred simultaneous image downloads. As
    /// list rows instead, the List itself is the lazy container: a
    /// row, and its downloads, only exist as they approach the
    /// screen.
    private var rows: [[(index: Int, entry: SavedCardLine)]] {
        stride(from: 0, to: pairs.count, by: columns).map {
            Array(pairs[$0..<min($0 + columns, pairs.count)])
        }
    }

    var body: some View {
        ForEach(rows, id: \.first?.entry.id) { row in
            HStack(spacing: 8) {
                ForEach(row, id: \.entry.id) { pair in
                    FaceTile(
                        entry: pair.entry,
                        option: options[pair.entry.id],
                        flipped: flipped.contains(pair.entry.id),
                        onTap: { onFlip(pair.entry) },
                        onZoom: { onZoom(pair.index) },
                        onChangePrinting: {
                            onChangePrinting(pair.index)
                        },
                        onReplace: { onReplace(pair.index) },
                        onRevert: { onRevert(pair.index) },
                        onSaveJPEG: { url in
                            onSaveJPEG(pair.entry, url)
                        },
                        onRemove: { onRemoveCard(pair.index) })
                        .frame(maxWidth: .infinity)
                }
                if row.count < columns {
                    ForEach(0..<(columns - row.count), id: \.self) { _ in
                        Color.clear
                            .aspectRatio(63.0 / 88.0, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 8,
                                      bottom: 4, trailing: 8))
            .hiddenRowSeparator()
            .listRowBackground(Color.clear)
            .id(row.first?.entry.id ?? UUID())
        }
    }
}

/// One card face in the grid. The front loads at mid size
/// preview quality; the back (the real back face, or the classic card back for
/// single faced cards) loads only after the first flip. Both sides
/// live in a stack, the back pre rotated, and the whole tile rotates
/// on flip: the standard SwiftUI card flip, with the crossfade
/// covering the midpoint.
private struct FaceTile: View {
    let entry: SavedCardLine
    let option: PrintingOption?
    let flipped: Bool
    let onTap: () -> Void
    let onZoom: () -> Void
    let onChangePrinting: () -> Void
    let onReplace: () -> Void
    let onRevert: () -> Void
    let onSaveJPEG: (URL?) -> Void
    let onRemove: () -> Void

    /// The back image is only requested after the first flip, so a
    /// deck page never downloads two images per card up front.
    @State private var backRequested = false

    var body: some View {
        faceStack
            .overlay {
                if option?.hasBackFace == true {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Theme.angelGoldLinear,
                                lineWidth: 3)
                }
            }
            .overlay(alignment: .topLeading) {
                if entry.isAltPrinting {
                    Text("ALT")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.85))
                        .clipShape(Capsule())
                        .padding(3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if entry.quantity > 1 {
                    Text("×\(entry.quantity)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(3)
                }
            }
            .overlay(alignment: .bottom) {
                if option?.hasBackFace == true {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.2.squarepath")
                        OutlinedBadgeText(
                            text: "TWO SIDED · TAP TO FLIP")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(
                        Color(red: 1.0, green: 0.85, blue: 0.35))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.65),
                                in: Capsule())
                    .padding(.bottom, 4)
                }
            }
            .onTapGesture(count: 2) { onZoom() }
            .onTapGesture { onTap() }
            .onLongPressGesture { onZoom() }
            .onChange(of: flipped) { newFlipped in
                if newFlipped { backRequested = true }
            }
            .contextMenu {
                Button {
                    onChangePrinting()
                } label: {
                    Label("Change printing",
                          systemImage: "rectangle.stack")
                }
                Button {
                    onTap()
                } label: {
                    Label("Flip card",
                          systemImage: "arrow.2.squarepath")
                }
                Button {
                    onSaveJPEG(displayedImageURL)
                } label: {
                    Label("Save card as JPEG",
                          systemImage: "photo")
                }
                Button {
                    onReplace()
                } label: {
                    Label("Replace card",
                          systemImage: "arrow.left.arrow.right")
                }
                if entry.canRevertReplacement {
                    Button {
                        onRevert()
                    } label: {
                        Label("Change back to \(entry.previousName ?? "original card")",
                              systemImage: "arrow.uturn.backward")
                    }
                }
                Divider()
                Button {
                    onZoom()
                } label: {
                    Label("View larger",
                          systemImage: "magnifyingglass")
                }
                Divider()
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove from deck",
                          systemImage: "trash")
                }
            }
    }

    /// The image currently facing the viewer, at save quality:
    /// the front face, the real back face, or the classic card
    /// back when a single faced card is flipped over.
    private var displayedImageURL: URL? {
        if flipped {
            if option?.hasBackFace == true {
                return option?.faceImageURL(1, quality: .large)
            }
            return PrintingsClient.cardBackImageURL
        }
        return option?.faceImageURL(0, quality: .large)
    }

    private var faceStack: some View {
        ZStack {
            singleFace(0)
                .opacity(flipped ? 0 : 1)
            if backRequested {
                backFace
                    .rotation3DEffect(.degrees(180),
                                      axis: (x: 0, y: 1, z: 0))
                    .opacity(flipped ? 1 : 0)
            }
        }
        .aspectRatio(63.0 / 88.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .rotation3DEffect(.degrees(flipped ? 180 : 0),
                          axis: (x: 0, y: 1, z: 0))
        .animation(.easeInOut(duration: 0.35), value: flipped)
    }

    /// The far side of the tile: the real back face for two sided
    /// cards, the classic Magic card back for everything else.
    private var backFace: some View {
        Group {
            if option?.hasBackFace == true {
                singleFace(1)
            } else {
                AsyncImage(url: PrintingsClient.cardBackImageURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else if phase.error != nil {
                        placeholder
                    } else {
                        loadingPlaceholder
                    }
                }
            }
        }
    }

    private func singleFace(_ index: Int) -> some View {
        Group {
            if let url = option?.faceImageURL(index, quality: .normal) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else if phase.error != nil {
                        placeholder
                    } else {
                        loadingPlaceholder
                    }
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.15))
            Text(entry.name)
                .font(.caption)
                .multilineTextAlignment(.center)
                .padding(4)
        }
        .aspectRatio(63.0 / 88.0, contentMode: .fit)
    }

    /// The placeholder while this tile's image is on
    /// its way: the name, a spinner, and the word
    /// Loading, so a slow tile never looks broken.
    private var loadingPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.15))
            VStack(spacing: 5) {
                Text(entry.name)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                ProgressView()
                Text("Loading\u{2026}")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
        .aspectRatio(63.0 / 88.0, contentMode: .fit)
    }
}

// MARK: - Zoomed card

private struct CardZoomView: View {
    let entry: SavedCardLine
    let option: PrintingOption?
    let onPick: (String, String) -> Void
    let onReset: () -> Void
    let onRevert: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var faceIndex = 0
    @State private var showPicker = false

    private var flipped: Bool { faceIndex == 1 }

    var body: some View {
        NavContainer {
            ScrollView {
                VStack(spacing: 12) {
                    zoomedImage
                        .frame(maxWidth: 440)
                    Button {
                        faceIndex = flipped ? 0 : 1
                    } label: {
                        Label("Flip card",
                              systemImage: "arrow.2.squarepath")
                    }
                    .buttonStyle(.bordered)
                    .buildControlSize()
                    VStack(spacing: 4) {
                        Text(entry.name)
                            .font(isMacUI ? .title3.weight(.semibold)
                                          : .headline)
                        Text(entry.printingLabel)
                            .font(isMacUI ? .body : .callout)
                            .foregroundStyle(.secondary)
                        if entry.isAltPrinting {
                            Text("ALT PRINTING")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.25))
                                .clipShape(Capsule())
                        }
                    }
                    Button("Change printing") { showPicker = true }
                        .buttonStyle(.borderedProminent)
                        .buildControlSize()
                    if entry.canRevertReplacement {
                        Button("Change back to original: \(entry.previousName ?? "")") {
                            onRevert()
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .buildControlSize()
                    }
                }
                .padding()
            }
            .font(Theme.fellFont(size: isMacUI ? 16 : 15))
            .navigationTitle(entry.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showPicker) {
                PrintingPickerView(entry: entry, onPick: onPick,
                                   onReset: onReset)
            }
        }
    }

    private var zoomedImage: some View {
        ZStack {
            zoomedFace(0)
                .opacity(flipped ? 0 : 1)
            zoomedBack
                .rotation3DEffect(.degrees(180),
                                  axis: (x: 0, y: 1, z: 0))
                .opacity(flipped ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .rotation3DEffect(.degrees(flipped ? 180 : 0),
                          axis: (x: 0, y: 1, z: 0))
        .animation(.easeInOut(duration: 0.35), value: flipped)
    }

    /// The far side when zoomed: the real back face for two sided
    /// cards, the classic Magic card back for everything else.
    private var zoomedBack: some View {
        Group {
            if option?.hasBackFace == true {
                zoomedFace(1)
            } else {
                AsyncImage(url: PrintingsClient.cardBackImageURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else if phase.error != nil {
                        facePlaceholder
                    } else {
                        faceLoadingPlaceholder
                    }
                }
            }
        }
    }

    private func zoomedFace(_ index: Int) -> some View {
        Group {
            if let url = option?.faceImageURL(index) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else if phase.error != nil {
                        facePlaceholder
                    } else {
                        faceLoadingPlaceholder
                    }
                }
            } else {
                facePlaceholder
            }
        }
    }

    private var facePlaceholder: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.15))
            .aspectRatio(63.0 / 88.0, contentMode: .fit)
    }

    /// The zoom placeholder while the big image is on
    /// its way: a spinner and the word Loading.
    private var faceLoadingPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.15))
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading\u{2026}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(63.0 / 88.0, contentMode: .fit)
    }
}

// MARK: - Replace card

/// Search for a different card and swap it into the deck in place
/// of the current one. The filters mirror Scryfall's own search
/// grammar: name words, card types, colors the card must include,
/// and a mana value. Results arrive one printing per card; after
/// replacing, the printing picker can refine the printing as
/// usual. The swap keeps the line's quantity and board, and it
/// flows into the previews, the exported list, and the next PDF.
private struct ReplaceCardView: View {
    let currentName: String
    let onReplace: (PrintingOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nameText = ""
    @State private var typeText = ""
    @State private var colors: Set<String> = []
    @State private var manaValue: Int = -1   // -1 means any
    @State private var results: [PrintingOption] = []
    @State private var searching = false
    @State private var searched = false
    @State private var errorText: String?

    private let colorOrder = ["w", "u", "b", "r", "g", "c"]
    private let colorPaints: [String: Color] = [
        "w": Color(red: 0.98, green: 0.95, blue: 0.85),
        "u": Color(red: 0.35, green: 0.55, blue: 0.95),
        "b": Color(red: 0.45, green: 0.40, blue: 0.50),
        "r": Color(red: 0.95, green: 0.45, blue: 0.35),
        "g": Color(red: 0.35, green: 0.75, blue: 0.45),
        "c": Color(red: 0.75, green: 0.72, blue: 0.68),
    ]

    var body: some View {
        NavContainer {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    filterPanel
                    resultsArea
                }
                .padding()
            }
            .background(LeatherBackground())
            .navigationTitle("Replace \(currentName)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if searching {
            ProgressView("Searching Scryfall…")
                .frame(maxWidth: .infinity)
                .foregroundStyle(Theme.parchment)
        } else if let errorText {
            Text(errorText)
                .foregroundStyle(.red)
        } else if searched && results.isEmpty {
            Text("No cards match. Loosen a filter and try again.")
                .font(Theme.fellFont(size: 15))
                .foregroundStyle(Theme.parchment.opacity(0.8))
        } else if !results.isEmpty {
            Text("Tap a card to replace \(currentName) with it. One printing per card; you can change the printing afterwards.")
                .font(Theme.fellFont(size: 14))
                .foregroundStyle(Theme.parchment.opacity(0.75))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130),
                                         spacing: 10)],
                      spacing: 12) {
                ForEach(results) { option in
                    Button {
                        onReplace(option)
                        dismiss()
                    } label: {
                        VStack(spacing: 4) {
                            AsyncImage(url: option.displayImageURL) { phase in
                                if let image = phase.image {
                                    image.resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else if phase.error == nil {
                                    CardLoadingPlaceholder()
                                } else {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.secondary
                                            .opacity(0.15))
                                        .aspectRatio(63.0 / 88.0,
                                                     contentMode: .fit)
                                }
                            }
                            Text(option.name)
                                .font(Theme.fellFont(size: 13))
                                .foregroundStyle(Theme.parchment)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            if let type = option.typeLine {
                                Text(type)
                                    .font(.caption2)
                                    .foregroundStyle(
                                        Theme.parchment.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if results.count >= 150 {
                Text("Showing the first 150 matches. Add filters to narrow it down.")
                    .font(.caption)
                    .foregroundStyle(Theme.parchment.opacity(0.6))
            }
        } else {
            Text("Search by name, or filter by type, color, and mana value. The replacement keeps the same quantity and takes effect in the previews and the next PDF.")
                .font(Theme.fellFont(size: 15))
                .foregroundStyle(Theme.parchment.opacity(0.8))
        }
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Card name", text: $nameText)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(Theme.ink)
                .onSubmit { runSearch() }
            TextField("Card type (creature, instant, legendary…)",
                      text: $typeText)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(Theme.ink)
                .onSubmit { runSearch() }
            HStack(spacing: 8) {
                Text("Colors")
                    .font(Theme.fellFont(size: 15))
                ForEach(colorOrder, id: \.self) { letter in
                    Button {
                        toggleColor(letter)
                    } label: {
                        Text(letter.uppercased())
                            .font(.headline)
                            .foregroundStyle(
                                letter == "w" || letter == "c"
                                    ? Theme.ink : Color.white)
                            .frame(width: 32, height: 32)
                            .background(colorPaints[letter] ?? .gray,
                                        in: Circle())
                            .overlay(
                                Circle().strokeBorder(
                                    colors.contains(letter)
                                        ? Theme.gold : Color.clear,
                                    lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Mana value")
                    .font(Theme.fellFont(size: 15))
                Picker("Mana value", selection: $manaValue) {
                    Text("Any").tag(-1)
                    ForEach(0..<8, id: \.self) { value in
                        Text("\(value)").tag(value)
                    }
                    Text("8+").tag(8)
                }
                .labelsHidden()
                .foregroundStyle(Theme.ink)
            }
            Button {
                runSearch()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.gold)
            .controlSize(.large)
            .disabled(searching)
        }
        .foregroundStyle(Theme.ink)
        .padding()
        .background {
            SuedePanel()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .colorScheme(.light)
    }

    /// Colorless is exclusive: a card is colorless, or it has
    /// colors. Tapping C clears the rest, and tapping a color
    /// clears C.
    private func toggleColor(_ letter: String) {
        if letter == "c" {
            colors = colors.contains("c") ? [] : ["c"]
        } else {
            colors.remove("c")
            if colors.contains(letter) {
                colors.remove(letter)
            } else {
                colors.insert(letter)
            }
        }
    }

    /// The Scryfall query for the current filter fields.
    private var query: String {
        var parts: [String] = []
        let name = nameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { parts.append(name) }
        let type = typeText.trimmingCharacters(in: .whitespaces)
        if !type.isEmpty {
            for word in type.lowercased().split(separator: " ") {
                parts.append("t:\(word)")
            }
        }
        if colors == ["c"] {
            parts.append("c=c")
        } else if !colors.isEmpty {
            let letters = colorOrder.filter {
                colors.contains($0) && $0 != "c"
            }
            if !letters.isEmpty {
                parts.append("c>=" + letters.joined())
            }
        }
        if manaValue >= 8 {
            parts.append("mv>=8")
        } else if manaValue >= 0 {
            parts.append("mv=\(manaValue)")
        }
        return parts.joined(separator: " ")
    }

    private func runSearch() {
        let q = query
        guard !q.isEmpty else {
            errorText = "Type a name or set at least one filter first."
            return
        }
        searching = true
        errorText = nil
        Task {
            do {
                results = try await PrintingsClient
                    .searchCards(query: q)
                searched = true
            } catch {
                errorText = "Search failed: \(error)"
            }
            searching = false
        }
    }
}


// MARK: - Add a card

/// Search for a card and add it to the deck's mainboard. A
/// leaner sibling of the replace search: name and type
/// filters, one printing per card in the results, and a
/// copies stepper for how many land at once. Adding a card
/// the deck already holds in the same printing raises its
/// quantity instead of adding a second line.
private struct AddCardView: View {
    let onAdd: (PrintingOption, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nameText = ""
    @State private var typeText = ""
    @State private var quantity = 1
    @State private var results: [PrintingOption] = []
    @State private var searching = false
    @State private var searched = false
    @State private var errorText: String?

    var body: some View {
        NavContainer {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    filterPanel
                    resultsArea
                }
                .padding()
            }
            .background(LeatherBackground())
            .navigationTitle("Add a card")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var resultsArea: some View {
        if searching {
            ProgressView("Searching Scryfall…")
                .frame(maxWidth: .infinity)
                .foregroundStyle(Theme.parchment)
        } else if let errorText {
            Text(errorText)
                .foregroundStyle(.red)
        } else if searched && results.isEmpty {
            Text("No cards match. Loosen a filter and try again.")
                .font(Theme.fellFont(size: 15))
                .foregroundStyle(Theme.parchment.opacity(0.8))
        } else if !results.isEmpty {
            Text("Tap a card to add \(quantity) \(quantity == 1 ? "copy" : "copies") to the deck. One printing per card; you can change the printing afterwards.")
                .font(Theme.fellFont(size: 14))
                .foregroundStyle(Theme.parchment.opacity(0.75))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130),
                                         spacing: 10)],
                      spacing: 12) {
                ForEach(results) { option in
                    Button {
                        onAdd(option, quantity)
                        dismiss()
                    } label: {
                        VStack(spacing: 4) {
                            AsyncImage(url: option.displayImageURL) { phase in
                                if let image = phase.image {
                                    image.resizable()
                                        .aspectRatio(contentMode: .fit)
                                } else if phase.error == nil {
                                    CardLoadingPlaceholder()
                                } else {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.secondary
                                            .opacity(0.15))
                                        .aspectRatio(63.0 / 88.0,
                                                     contentMode: .fit)
                                }
                            }
                            Text(option.name)
                                .font(Theme.fellFont(size: 13))
                                .foregroundStyle(Theme.parchment)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            if let type = option.typeLine {
                                Text(type)
                                    .font(.caption2)
                                    .foregroundStyle(
                                        Theme.parchment.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if results.count >= 150 {
                Text("Showing the first 150 matches. Add filters to narrow it down.")
                    .font(.caption)
                    .foregroundStyle(Theme.parchment.opacity(0.6))
            }
        } else {
            Text("Search by name or card type, set how many copies, then tap a card to add it to the deck.")
                .font(Theme.fellFont(size: 15))
                .foregroundStyle(Theme.parchment.opacity(0.8))
        }
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Card name", text: $nameText)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(Theme.ink)
                .onSubmit { runSearch() }
            TextField("Card type (creature, instant, legendary…)",
                      text: $typeText)
                .textFieldStyle(.roundedBorder)
                .foregroundStyle(Theme.ink)
                .onSubmit { runSearch() }
            Stepper(value: $quantity, in: 1...40) {
                Text("Copies: \(quantity)")
                    .font(Theme.fellFont(size: 15))
            }
            Button {
                runSearch()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.gold)
            .controlSize(.large)
            .disabled(searching)
        }
        .foregroundStyle(Theme.ink)
        .padding()
        .background {
            SuedePanel()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .colorScheme(.light)
    }

    /// The Scryfall query for the current filter fields.
    private var query: String {
        var parts: [String] = []
        let name = nameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { parts.append(name) }
        let type = typeText.trimmingCharacters(in: .whitespaces)
        if !type.isEmpty {
            for word in type.lowercased().split(separator: " ") {
                parts.append("t:\(word)")
            }
        }
        return parts.joined(separator: " ")
    }

    private func runSearch() {
        let q = query
        guard !q.isEmpty else {
            errorText = "Type a name or a type first."
            return
        }
        searching = true
        errorText = nil
        Task {
            do {
                results = try await PrintingsClient
                    .searchCards(query: q)
                searched = true
            } catch {
                errorText = "Search failed: \(error)"
            }
            searching = false
        }
    }
}


// MARK: - Deck editor

/// The deck as its list: every line with its quantity and
/// printing, the same information the deck's .txt carries.
/// Quantities step up and down, lines swipe away, and the
/// add search drops new cards in. Every change lands in
/// the store the moment it happens, so the card previews
/// and the next build use the edited list right away.
private struct DeckEditorView: View {
    @EnvironmentObject private var store: DeckStore
    let deckId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var showAddCard = false
    @State private var showTextEditor = false

    private var deck: SavedDeck? { store.deck(id: deckId) }

    var body: some View {
        let stack = NavContainer {
            Group {
                if let deck {
                    List {
                        Section {
                            ForEach(
                                Array(deck.entries.enumerated()),
                                id: \.element.id
                            ) { pair in
                                editorRow(pair: pair)
                            }
                        } footer: {
                            Text("Changes apply to the card previews and the next build right away.")
                                .foregroundStyle(
                                    Theme.parchment.opacity(0.75))
                        }

                        Section {
                            Button {
                                showAddCard = true
                            } label: {
                                Label("Add a card",
                                      systemImage: "plus.circle")
                                    .frame(maxWidth: .infinity,
                                           alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.gold)
                        }
                        .listRowBackground(Color.clear)

                        Section {
                            Button {
                                showTextEditor = true
                            } label: {
                                Label("Edit as text",
                                      systemImage: "text.alignleft")
                                    .frame(maxWidth: .infinity,
                                           alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.gold)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .hiddenScrollBackground()
                    .background(LeatherBackground())
                    .navigationTitle("Edit \(deck.name)")
                } else {
                    LeatherBackground()
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddCard = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddCard) {
                AddCardView(onAdd: { option, qty in
                    store.addCard(
                        deckId: deckId, name: option.name,
                        setCode: option.set,
                        collectorNumber: option.collectorNumber,
                        quantity: qty)
                })
            }
            .sheet(isPresented: $showTextEditor) {
                DeckTextEditorView(deckId: deckId)
            }
        }
        // On the Mac a sheet sizes itself to its content,
        // and a list claims no height of its own, which
        // squeezed the editor into a sliver of a window.
        // Give it a real size there.
        #if os(macOS)
        return stack.frame(minWidth: 580, idealWidth: 700,
                           minHeight: 620, idealHeight: 760)
        #else
        return stack
        #endif
    }

    private func editorRow(
        pair: (offset: Int, element: SavedCardLine)
    ) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    store.setQuantity(
                        deckId: deckId,
                        entryIndex: pair.offset,
                        quantity: pair.element.quantity - 1)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .disabled(pair.element.quantity <= 1)
                Text("\(pair.element.quantity)×")
                    .font(Theme.fellFont(size: isMacUI ? 16 : 15))
                    .frame(width: 34, alignment: .center)
                Button {
                    store.setQuantity(
                        deckId: deckId,
                        entryIndex: pair.offset,
                        quantity: pair.element.quantity + 1)
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.gold)

            VStack(alignment: .leading, spacing: 1) {
                Text(pair.element.name)
                    .font(Theme.fellFont(size: isMacUI ? 17 : 16))
                    .foregroundStyle(Theme.parchment)
                Text(pair.element.board == "main"
                     ? pair.element.printingLabel
                     : "\(pair.element.printingLabel) · \(pair.element.board)")
                    .font(.caption)
                    .foregroundStyle(Theme.parchment.opacity(0.6))
            }
            Spacer()
        }
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.removeCard(deckId: deckId,
                                 entryIndex: pair.offset)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                store.removeCard(deckId: deckId,
                                 entryIndex: pair.offset)
            } label: {
                Label("Remove from deck",
                      systemImage: "trash")
            }
        }
    }
}

// MARK: - Text deck editor (Pack D, mirroring the Windows 1.60.1 editor)

private enum TextLineKind {
    case blank, header, card, unreadable
}

private struct TextLineIssue {
    var message: String
    var severe: Bool
}

private struct TextLineInfo {
    var kind: TextLineKind
    var entry: DeckEntry?
    var issue: TextLineIssue?
    var isMatch: Bool
    var isChecked: Bool
}

/// The deck as list text, the Windows style editor: lines cut,
/// copy and paste like any text, Find picks out matching lines,
/// and checked lines can be deleted together or replaced by
/// pasted lines or a card from the search. As you type, every
/// card is checked against Scryfall: a card it cannot find is
/// flagged, and a printing number that belongs to another card
/// is called out. SwiftUI draws no checkbox gutter and no
/// in-text underlines, so the panel beside the text carries
/// the checkboxes, the match bands, and the notes instead.
/// Nothing in the deck changes until Save changes.
private struct DeckTextEditorView: View {
    @EnvironmentObject private var store: DeckStore
    let deckId: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var savedText = ""
    @State private var lastLines: [String] = []
    @State private var checked: [Bool] = []
    @State private var findText = ""
    @State private var currentMatch: Int? = nil
    @State private var printingNames: [PrintingKey: String] = [:]
    @State private var missingPrintings: Set<PrintingKey> = []
    @State private var askedKeys: Set<PrintingKey> = []
    @State private var knownNames: [String: Bool] = [:]
    @State private var checking = false
    @State private var checkError: String? = nil
    @State private var showPickCard = false
    @State private var pickForReplace = false
    @State private var showReplacePaste = false
    @State private var pasteText = ""
    @State private var showEmptyAlert = false
    @State private var severeCountAtSave = 0
    @State private var showSevereConfirm = false
    @State private var showDirtyConfirm = false
    @State private var showLegacyEditor = false
    @State private var showSwitchConfirm = false
    @State private var started = false

    private var deckName: String {
        store.deck(id: deckId)?.name ?? "deck"
    }

    private var lines: [String] {
        text.components(separatedBy: "\n")
    }

    private var isDirty: Bool { text != savedText }

    var body: some View {
        let infos = lineInfos()
        let checkedCount = infos.enumerated().filter {
            $0.element.isChecked && $0.element.kind == .card
        }.count
        let stack = NavContainer {
            VStack(spacing: 10) {
                findRow(infos: infos)
                toolsRow(checkedCount: checkedCount)
                hint
                split(infos: infos)
                statusBar(infos: infos)
            }
            .padding(14)
            .background(LeatherBackground())
            .navigationTitle("Edit \(deckName) as text")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancelTapped() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save changes") { saveTapped() }
                }
            }
            .onAppear { loadIfNeeded() }
            .onChange(of: text) { newText in
                let fresh = newText.components(separatedBy: "\n")
                checked = Self.carryChecks(old: lastLines,
                                           checks: checked,
                                           fresh: fresh)
                lastLines = fresh
                currentMatch = nil
            }
            .task(id: text) { await runChecks() }
            .sheet(isPresented: $showPickCard) {
                AddCardView(onAdd: { option, qty in
                    if pickForReplace {
                        replaceChecked(with: option)
                    } else {
                        insertCardLine(
                            "\(qty) \(Self.cardLine(option))")
                    }
                })
            }
            .sheet(isPresented: $showReplacePaste) {
                replacePasteSheet
            }
            .sheet(isPresented: $showLegacyEditor) {
                DeckEditorView(deckId: deckId)
            }
            .onChange(of: showLegacyEditor) { shown in
                if !shown { reloadIfClean() }
            }
            .alert("Save the deck", isPresented: $showEmptyAlert) {
                Button("OK") {}
            } message: {
                Text("A deck needs at least one card. Add a line, "
                     + "or use Delete this deck on the deck page "
                     + "instead.")
            }
            .confirmationDialog(
                "Save the deck?",
                isPresented: $showSevereConfirm,
                titleVisibility: .visible
            ) {
                Button("Save anyway") { doSave() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text(severeMessage)
            }
            .confirmationDialog(
                "Unsaved changes",
                isPresented: $showDirtyConfirm,
                titleVisibility: .visible
            ) {
                Button("Save changes") { saveTapped() }
                Button("Discard changes", role: .destructive) {
                    dismiss()
                }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Save your changes to \(deckName)?")
            }
            .confirmationDialog(
                "Unsaved changes",
                isPresented: $showSwitchConfirm,
                titleVisibility: .visible
            ) {
                Button("Save changes") {
                    applySave()
                    showLegacyEditor = true
                }
                Button("Discard changes", role: .destructive) {
                    reloadFromStore()
                    showLegacyEditor = true
                }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Save your changes to \(deckName) "
                     + "before switching editors?")
            }
        }
        #if os(macOS)
        return stack
            .frame(minWidth: 900, idealWidth: 1060,
                   minHeight: 640, idealHeight: 800)
            .interactiveDismissDisabled(isDirty)
        #else
        return stack
            .interactiveDismissDisabled(isDirty)
        #endif
    }

    private var severeMessage: String {
        let n = severeCountAtSave
        let what = n == 1
            ? "1 line has a card that can't be found or a line "
              + "that can't be read"
            : "\(n) lines have cards that can't be found or "
              + "can't be read"
        return what + ". Cards that can't be found won't print, "
            + "and lines that can't be read are left out."
    }

    // MARK: - Pieces

    private var hint: some View {
        Text("One card per line, like 4 Llanowar Elves (M19) 314. "
             + "Cut, copy and paste lines like any text. Tick the "
             + "box beside a line in the list to check it.")
            .font(Theme.fellFont(size: 14))
            .foregroundStyle(Theme.parchment.opacity(0.75))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func findRow(infos: [TextLineInfo]) -> some View {
        let matchCount = infos.filter { $0.isMatch }.count
        let noMatch = matchCount == 0 && !findText.isEmpty
        return HStack(spacing: 10) {
            TextField("Find", text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .onSubmit { nextMatch(step: 1, infos: infos) }
            Text(findText.isEmpty ? ""
                 : matchCount == 0 ? "no match"
                 : "\(matchCount) line\(matchCount == 1 ? "" : "s")")
                .font(Theme.fellFont(size: 15))
                .foregroundStyle(noMatch
                    ? Color(red: 1.0, green: 0.54, blue: 0.48)
                    : Theme.parchment)
            Button("Check matches") { checkMatches(infos: infos) }
                .disabled(matchCount == 0)
            Spacer()
        }
        .font(Theme.fellFont(size: 15))
        .foregroundStyle(Theme.parchment)
    }

    private func toolsRow(checkedCount: Int) -> some View {
        HStack(spacing: 14) {
            Button {
                switchToLegacy()
            } label: {
                Label("Legacy editor",
                      systemImage: "list.bullet")
            }
            Spacer()
            Menu {
                Button("With a card from the search…") {
                    pickForReplace = true
                    showPickCard = true
                }
                Button("With lines I paste…") {
                    pasteText = ""
                    showReplacePaste = true
                }
            } label: {
                Text(checkedCount > 0
                     ? "Replace \(checkedCount) checked"
                     : "Replace checked")
            }
            .disabled(checkedCount == 0)
            .fixedSize()
            Button(checkedCount > 0
                   ? "Delete \(checkedCount) checked"
                   : "Delete checked") {
                deleteChecked()
            }
            .disabled(checkedCount == 0)
            Button("Uncheck all") {
                checked = Array(repeating: false,
                                count: checked.count)
            }
            .disabled(checkedCount == 0)
            Button("+ Add a card") {
                pickForReplace = false
                showPickCard = true
            }
        }
        .font(Theme.fellFont(size: 15))
        .foregroundStyle(Theme.gold)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func split(infos: [TextLineInfo]) -> some View {
        let editor = TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(Theme.ink)
            .hiddenScrollBackground()
            .background(SuedePanel())
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.gold.opacity(0.5)))
        if isMacUI {
            HStack(spacing: 10) {
                editor
                linesPanel(infos: infos).frame(width: 360)
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                editor
                linesPanel(infos: infos).frame(height: 200)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func linesPanel(infos: [TextLineInfo]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(infos.enumerated()),
                            id: \.offset) { pair in
                        lineRow(index: pair.offset,
                                info: pair.element)
                    }
                }
                .padding(8)
            }
            .background(Theme.leatherDeep)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.gold.opacity(0.5)))
            .onChange(of: currentMatch) { match in
                if let match {
                    withAnimation {
                        proxy.scrollTo(match, anchor: .center)
                    }
                }
            }
        }
    }

    private func lineRow(index: Int,
                         info: TextLineInfo) -> some View {
        let raw = index < lines.count ? lines[index] : ""
        return HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.parchment.opacity(0.45))
                .frame(width: 26, alignment: .trailing)
                .padding(.top, 3)
            if info.kind == .card {
                Button {
                    toggleCheck(index)
                } label: {
                    Image(systemName: info.isChecked
                          ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                        .foregroundStyle(info.isChecked
                            ? Theme.gold
                            : Theme.parchment.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            } else {
                Spacer().frame(width: 15)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(raw.isEmpty ? " " : raw)
                    .font(Theme.fellFont(size: 13.5))
                    .foregroundStyle(rowTextColor(info))
                    .lineLimit(1)
                if let issue = info.issue {
                    Text(issue.message)
                        .font(Theme.fellFont(size: 12))
                        .foregroundStyle(issue.severe
                            ? Color(red: 1.0, green: 0.54,
                                    blue: 0.48)
                            : Color(red: 1.0, green: 0.78,
                                    blue: 0.43))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(rowBackground(index: index, info: info))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .id(index)
    }

    private func rowTextColor(_ info: TextLineInfo) -> Color {
        switch info.kind {
        case .header: return Theme.gold
        case .unreadable:
            return Color(red: 1.0, green: 0.54, blue: 0.48)
        case .blank: return Theme.parchment.opacity(0.4)
        case .card: return Theme.parchment
        }
    }

    private func rowBackground(index: Int,
                               info: TextLineInfo) -> Color {
        if info.isChecked {
            return Color(red: 1.0, green: 0.84, blue: 0.40)
                .opacity(0.30)
        }
        if currentMatch == index && info.isMatch {
            return Color(red: 0.47, green: 0.78, blue: 1.0)
                .opacity(0.45)
        }
        if info.isMatch {
            return Color(red: 0.47, green: 0.78, blue: 1.0)
                .opacity(0.20)
        }
        return Color.clear
    }

    private func statusBar(infos: [TextLineInfo]) -> some View {
        let status = statusText(infos: infos)
        return HStack {
            Text(status.0)
                .font(Theme.fellFont(size: 15))
                .foregroundStyle(status.1)
                .lineLimit(2)
            Spacer()
            Button("Legacy editor") { switchToLegacy() }
                .font(Theme.fellFont(size: 15))
                .foregroundStyle(Theme.gold)
                .buttonStyle(.plain)
        }
    }

    private var replacePasteSheet: some View {
        let stack = NavContainer {
            VStack(alignment: .leading, spacing: 10) {
                Text("Paste or type the new lines. They go where "
                     + "the first checked line is, and the "
                     + "checked lines are removed.")
                    .font(Theme.fellFont(size: 15))
                    .foregroundStyle(Theme.parchment)
                TextEditor(text: $pasteText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .hiddenScrollBackground()
                    .background(SuedePanel())
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(minHeight: 220)
            }
            .padding(14)
            .background(LeatherBackground())
            .navigationTitle("Replace checked lines")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showReplacePaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Replace") { replaceWithPaste() }
                }
            }
        }
        #if os(macOS)
        return stack.frame(minWidth: 560, idealWidth: 700,
                           minHeight: 420, idealHeight: 480)
        #else
        return stack
        #endif
    }

    // MARK: - Lines

    private static func classify(
        _ line: String
    ) -> (kind: TextLineKind, entry: DeckEntry?) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("//") || t.hasPrefix("#") {
            return (.blank, nil)
        }
        let parsed = DeckList.parse(line)
        if parsed.entries.count == 1 {
            return (.card, parsed.entries[0])
        }
        if !parsed.warnings.isEmpty { return (.unreadable, nil) }
        return (.header, nil)
    }

    private func lineInfos() -> [TextLineInfo] {
        let q = findText.trimmingCharacters(in: .whitespaces)
        return lines.enumerated().map { pair in
            let c = Self.classify(pair.element)
            return TextLineInfo(
                kind: c.kind,
                entry: c.entry,
                issue: issue(kind: c.kind, entry: c.entry),
                isMatch: !q.isEmpty && c.kind == .card
                    && pair.element.range(
                        of: q, options: .caseInsensitive) != nil,
                isChecked: pair.offset < checked.count
                    ? checked[pair.offset] : false)
        }
    }

    private func issue(kind: TextLineKind,
                       entry: DeckEntry?) -> TextLineIssue? {
        if kind == .unreadable {
            return TextLineIssue(message: "can't read this line",
                                 severe: true)
        }
        guard kind == .card, let entry else { return nil }
        if let set = entry.setCode,
           let num = entry.collectorNumber {
            let key = PrintingKey(set: set, collectorNumber: num)
            let label = "(\(set.uppercased())) \(num)"
            if let printed = printingNames[key] {
                if !Self.sameCard(printed, entry.name) {
                    return TextLineIssue(
                        message: "\(label) is \(printed)",
                        severe: false)
                }
                return nil
            }
            if missingPrintings.contains(key) {
                if knownNames[entry.name] == false {
                    return TextLineIssue(
                        message: "card can't be found",
                        severe: true)
                }
                if knownNames[entry.name] == true {
                    return TextLineIssue(
                        message: "printing \(label) not found, "
                            + "so another printing will print",
                        severe: false)
                }
            }
            return nil
        }
        if knownNames[entry.name] == false {
            return TextLineIssue(message: "card can't be found",
                                 severe: true)
        }
        return nil
    }

    private static func sameCard(_ printed: String,
                                 _ name: String) -> Bool {
        if printed.caseInsensitiveCompare(name) == .orderedSame {
            return true
        }
        return printed.components(separatedBy: " // ").contains {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func cardLine(_ option: PrintingOption)
        -> String {
        "\(option.name) (\(option.set.uppercased())) "
            + option.collectorNumber
    }

    /// Checks follow their lines: an edit inside lines keeps
    /// every check; added or removed lines keep the checks
    /// above and below them.
    private static func carryChecks(old: [String],
                                    checks: [Bool],
                                    fresh: [String]) -> [Bool] {
        if old.count == fresh.count { return checks }
        var prefix = 0
        while prefix < old.count && prefix < fresh.count
                && old[prefix] == fresh[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix
                && suffix < fresh.count - prefix
                && old[old.count - 1 - suffix]
                    == fresh[fresh.count - 1 - suffix] {
            suffix += 1
        }
        var result: [Bool] = []
        for i in 0..<fresh.count {
            if i < prefix {
                result.append(i < checks.count ? checks[i] : false)
            } else if i >= fresh.count - suffix {
                let oldIndex = old.count - (fresh.count - i)
                result.append(oldIndex >= 0 && oldIndex < checks.count
                              ? checks[oldIndex] : false)
            } else {
                result.append(false)
            }
        }
        return result
    }

    private func setLines(_ newLines: [String],
                          _ newChecks: [Bool]) {
        lastLines = newLines
        text = newLines.joined(separator: "\n")
        checked = newChecks
    }

    private func toggleCheck(_ index: Int) {
        var c = checked
        while c.count <= index { c.append(false) }
        c[index].toggle()
        checked = c
    }

    private func checkedCardLines() -> [Int] {
        lineInfos().enumerated().compactMap { pair in
            pair.element.isChecked && pair.element.kind == .card
                ? pair.offset : nil
        }
    }

    // MARK: - Find

    private func nextMatch(step: Int, infos: [TextLineInfo]) {
        let matches = infos.enumerated().compactMap { pair in
            pair.element.isMatch ? pair.offset : nil
        }
        guard !matches.isEmpty else { return }
        if let current = currentMatch {
            if step > 0 {
                currentMatch = matches.first { $0 > current }
                    ?? matches[0]
            } else {
                currentMatch = matches.last { $0 < current }
                    ?? matches[matches.count - 1]
            }
        } else {
            currentMatch = step > 0 ? matches[0]
                : matches[matches.count - 1]
        }
    }

    private func checkMatches(infos: [TextLineInfo]) {
        var c = checked
        while c.count < lines.count { c.append(false) }
        for pair in infos.enumerated() where pair.element.isMatch {
            c[pair.offset] = true
        }
        checked = c
    }

    // MARK: - Checked line operations

    private func deleteChecked() {
        let gone = checkedCardLines()
        guard !gone.isEmpty else { return }
        let keep = lines.indices.filter { !gone.contains($0) }
        setLines(keep.map { lines[$0] },
                 Array(repeating: false, count: keep.count))
    }

    private func replaceChecked(with option: PrintingOption) {
        let targets = checkedCardLines()
        guard !targets.isEmpty else { return }
        var ls = lines
        for i in targets {
            let entry = Self.classify(ls[i]).entry
            let qty = entry?.quantity ?? 1
            let trimmed = ls[i].trimmingCharacters(
                in: .whitespaces)
            let prefix = trimmed.uppercased().hasPrefix("SB:")
                ? "SB: " : ""
            ls[i] = "\(prefix)\(qty) \(Self.cardLine(option))"
        }
        setLines(ls, Array(repeating: false, count: ls.count))
    }

    private func replaceWithPaste() {
        let targets = checkedCardLines()
        guard let first = targets.first else { return }
        let pasted = pasteText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        for i in lines.indices {
            if i == first { out.append(contentsOf: pasted) }
            if !targets.contains(i) { out.append(lines[i]) }
        }
        setLines(out, Array(repeating: false, count: out.count))
        showReplacePaste = false
    }

    private func insertCardLine(_ newLine: String) {
        var ls = lines
        var insertAt: Int? = nil
        for (i, line) in ls.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
                .lowercased()
            if t == "sideboard" || t == "sideboard:"
                || t == "maybeboard" || t == "maybeboard:" {
                insertAt = i
                break
            }
        }
        if var at = insertAt {
            while at > 0
                    && ls[at - 1].trimmingCharacters(
                        in: .whitespaces).isEmpty {
                at -= 1
            }
            insertAt = at
        } else {
            while let last = ls.last,
                  last.trimmingCharacters(in: .whitespaces)
                    .isEmpty {
                ls.removeLast()
            }
            insertAt = ls.count
        }
        guard let at = insertAt else { return }
        ls.insert(newLine, at: at)
        var c = checked
        while c.count < ls.count { c.append(false) }
        c.insert(false, at: min(at, c.count))
        setLines(ls, c)
    }

    // MARK: - Scryfall checking

    private func runChecks() async {
        let snapshot = text
        try? await Task.sleep(nanoseconds: 700_000_000)
        if Task.isCancelled { return }
        var keys: [PrintingKey] = []
        for line in snapshot.components(separatedBy: "\n") {
            let c = Self.classify(line)
            guard c.kind == .card, let e = c.entry,
                  let set = e.setCode,
                  let num = e.collectorNumber else { continue }
            let key = PrintingKey(set: set, collectorNumber: num)
            if !askedKeys.contains(key) && !keys.contains(key) {
                keys.append(key)
            }
        }
        if keys.isEmpty && namesToAsk(snapshot: snapshot).isEmpty {
            if snapshot == text { checking = false }
            return
        }
        if snapshot == text {
            checking = true
            checkError = nil
        }
        let client = ScryfallClient()
        do {
            if !keys.isEmpty {
                let found = try await client.lookupPrintings(
                    keys, strict: false)
                for key in keys {
                    askedKeys.insert(key)
                    if let card = found[key] {
                        printingNames[key] = card.name
                    } else {
                        missingPrintings.insert(key)
                    }
                }
            }
            let names = namesToAsk(snapshot: snapshot)
            if !names.isEmpty {
                let unknown = try await client.unknownNames(names)
                let lowered = Set(unknown.map { $0.lowercased() })
                for name in names {
                    knownNames[name] =
                        !lowered.contains(name.lowercased())
                }
            }
        } catch {
            if snapshot == text {
                checkError =
                    (error as? ScryfallClientError)?.description
                    ?? error.localizedDescription
            }
        }
        if snapshot == text { checking = false }
    }

    /// Names Scryfall has not been asked about yet: every
    /// name-only line, plus lines whose printing was not found.
    private func namesToAsk(snapshot: String) -> [String] {
        var names: [String] = []
        for line in snapshot.components(separatedBy: "\n") {
            let c = Self.classify(line)
            guard c.kind == .card, let e = c.entry else { continue }
            if knownNames[e.name] != nil
                || names.contains(e.name) {
                continue
            }
            if let set = e.setCode,
               let num = e.collectorNumber {
                let key = PrintingKey(set: set, collectorNumber: num)
                if missingPrintings.contains(key) {
                    names.append(e.name)
                }
            } else {
                names.append(e.name)
            }
        }
        return names
    }

    // MARK: - Status and save

    private func statusText(infos: [TextLineInfo])
        -> (String, Color) {
        let parsed = DeckList.parse(text)
        let main = parsed.entries.filter { $0.board == .main }
            .reduce(0) { $0 + $1.quantity }
        let side = parsed.entries.filter { $0.board != .main }
            .reduce(0) { $0 + $1.quantity }
        var s = "\(main) card\(main == 1 ? "" : "s")"
        if side > 0 { s += " and \(side) in the sideboard" }
        let errors = infos.filter {
            $0.issue?.severe == true
        }.count
        let warnings = infos.filter { $0.issue != nil }.count
            - errors
        var color = Theme.parchment
        if let checkError {
            s += " · couldn't check cards with Scryfall "
                + "(\(checkError))"
            color = Color(red: 1.0, green: 0.75, blue: 0.47)
        } else if checking {
            s += " · checking cards with Scryfall…"
        } else if errors > 0 {
            s += " · \(errors) line\(errors == 1 ? " needs" : "s need") fixing"
            color = Color(red: 1.0, green: 0.54, blue: 0.48)
        } else if warnings > 0 {
            s += " · \(warnings) printing"
                + "\(warnings == 1 ? "" : "s") to look at"
            color = Color(red: 1.0, green: 0.78, blue: 0.43)
        } else {
            s += " · every card found"
        }
        if isDirty { s += " · not saved yet" }
        return (s, color)
    }

    private func loadIfNeeded() {
        guard !started else { return }
        started = true
        reloadFromStore()
    }

    private func reloadFromStore() {
        guard let deck = store.deck(id: deckId) else { return }
        let t = DeckStore.deckText(for: deck)
        savedText = t
        lastLines = t.components(separatedBy: "\n")
        checked = Array(repeating: false, count: lastLines.count)
        currentMatch = nil
        text = t
    }

    /// After the legacy editor closes: if this editor holds
    /// no unsaved edits of its own, take the store's current
    /// text, so changes made over there are what shows here.
    private func reloadIfClean() {
        if !isDirty { reloadFromStore() }
    }

    private func switchToLegacy() {
        if isDirty {
            showSwitchConfirm = true
        } else {
            showLegacyEditor = true
        }
    }

    private func applySave() {
        store.replaceEntries(deckId: deckId, text: text)
        savedText = text
    }

    private func saveTapped() {
        let parsed = DeckList.parse(text)
        if parsed.entries.isEmpty {
            showEmptyAlert = true
            return
        }
        let severe = lineInfos().filter {
            $0.issue?.severe == true
        }.count
        if severe > 0 {
            severeCountAtSave = severe
            showSevereConfirm = true
            return
        }
        doSave()
    }

    private func doSave() {
        applySave()
        dismiss()
    }

    private func cancelTapped() {
        if isDirty {
            showDirtyConfirm = true
        } else {
            dismiss()
        }
    }
}
