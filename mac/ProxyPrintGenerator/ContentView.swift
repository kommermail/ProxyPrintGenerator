//
//  ContentView.swift
//  Version 54
//  Proxy Printer (native port) — app shell and Quick Build screen
//
//  The app opens on two tabs:
//    - Library: the full printing selector (DeckLibrary, LibraryView)
//    - Quick Build: paste a list and print it, no saving
//
//  PDFFileDocument lives here; both tabs use it for the save panel.
//

import SwiftUI
import UniformTypeIdentifiers

/// A FileDocument wrapper so the system save panel (fileExporter) can
/// write the finished PDF wherever the user chooses: Files, iCloud,
/// Google Drive, or any other installed file provider.
struct PDFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".pdf")
        try data.write(to: tmp)
        self.url = tmp
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try Data(contentsOf: url))
    }
}

/// A FileDocument wrapper for Quick Build's finished file, which
/// is a PDF or a zip of page images depending on the format the
/// user picked.
struct BuildFileDocument: FileDocument {
    // PNG joined the writable set when builds started
    // producing a stitched .png file: without it the
    // exporter refuses the type outright and the save
    // comes out broken, which wore a "corrupt file"
    // costume for an evening.
    static var readableContentTypes: [UTType] { [.pdf, .zip, .png, .jpeg] }
    static var writableContentTypes: [UTType] { [.pdf, .zip, .png, .jpeg] }
    var url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let ext = configuration.contentType == .zip ? "zip"
            : configuration.contentType == .png ? "png"
            : configuration.contentType == .jpeg ? "jpg" : "pdf"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: tmp)
        self.url = tmp
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try Data(contentsOf: url))
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label("Deck Library", systemImage: "books.vertical")
                }
            QuickBuildView()
                .tabItem {
                    Label("Quick Build", systemImage: "printer")
                }
        }
        .tint(Theme.gold)
        .overlay {
            if isMacUI {
                StitchedEdgeOverlay()
            }
        }
        #if os(macOS)
        .modifier(UpdateSheets())
        #endif
    }
}

// MARK: - Quick Build

struct QuickBuildView: View {
    @StateObject private var model = PrintJobModel()
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: BuildFileDocument?
    @State private var savedMessage: String?

    private enum Field {
        case deck
        case name
    }
    @FocusState private var focus: Field?

    private var deckLineCount: Int {
        model.deckText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    /// Section titles on bright foil plaques, matching the
    /// library screens.
    private func sectionHeader(_ title: String) -> some View {
        // On the desktop the headings stand shorter, with the
        // five type symbols split across the words, so the
        // masthead above them has room to land.
        SpectacularHeader(title: title, pipsOnSides: isMacUI)
    }

    /// One line under the format picker saying what the chosen
    /// format gets you.
    private var formatCaption: String {
        switch model.format {
        case .pdf:
            return "One printable PDF at full quality"
        case .png:
            return "Every page stitched into one tall PNG at full quality"
        case .jpeg:
            return "Every page stitched into one tall JPEG. Quality down, file down"
        }
    }

    /// One ink boost: the label and its value on one line, and
    /// a full width slider under them. Stacked rather than side
    /// by side on purpose: a wide row appearing in a form makes
    /// the Mac window grow to fit it, and the stacked row asks
    /// for no width at all. The deck page uses a list, which
    /// never had the problem, so its sliders stay side by side.
    private func boostSlider(_ label: String,
                             _ value: Binding<Double>) -> some View {
        VStack(spacing: 2) {
            HStack {
                KingdomText(text: label,
                            size: isMacUI ? 20 : 19)
                Spacer()
                KingdomText(
                    text: String(format: "%.2fx",
                                 value.wrappedValue),
                    size: isMacUI ? 20 : 19)
            }
            Slider(value: value, in: 0.8...1.6)
                .tint(Theme.gold)
        }
    }

    private func vibranceSlider(_ value: Binding<Double>)
        -> some View {
        VStack(spacing: 2) {
            HStack {
                KingdomText(text: "Vibrance",
                            size: isMacUI ? 20 : 19)
                Spacer()
                KingdomText(
                    text: "+\(Int((value.wrappedValue * 100).rounded()))%",
                    size: isMacUI ? 20 : 19)
            }
            Slider(value: value, in: 0...0.6, step: 0.05)
                .tint(Theme.gold)
        }
    }

    private func midtoneSlider(_ value: Binding<Double>)
        -> some View {
        VStack(spacing: 2) {
            HStack {
                KingdomText(text: "Midtone lift",
                            size: isMacUI ? 20 : 19)
                Spacer()
                KingdomText(
                    text: "+\(Int((value.wrappedValue * 100).rounded()))%",
                    size: isMacUI ? 20 : 19)
            }
            Slider(value: value, in: 0...0.35, step: 0.01)
                .tint(Theme.gold)
        }
    }

    var body: some View {
        NavContainer {
            PanelScaffold(bar: {
                actionBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Theme.leatherDeep)
                    .tint(Theme.gold)
                    .font(Theme.fellFont(size: isMacUI ? 16 : 15))
            }) {
                VStack(spacing: 0) {
                    AppMasthead(section: "Quick Build")
                        .padding(.horizontal, 12)
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                    // Deck editor: fixed height, scrolls inside itself.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            KingdomText(text: "Deck list",
                                        size: isMacUI ? 21 : 20)
                            Spacer()
                            if deckLineCount > 0 {
                                KingdomText(
                                    text: "\(deckLineCount) lines",
                                    size: 17.5)
                            }
                            Button { showImporter = true } label: {
                                Text("Open a .txt file…")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(Color(
                                        red: 0.90, green: 0.78,
                                        blue: 0.55))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background {
                                        RoundedRectangle(
                                            cornerRadius: 8,
                                            style: .continuous)
                                            .fill(Theme.leatherLinear)
                                            .overlay(
                                                RoundedRectangle(
                                                    cornerRadius: 8,
                                                    style: .continuous)
                                                    .strokeBorder(
                                                        Theme.leatherDeep,
                                                        lineWidth: 1))
                                            .shadow(
                                                color: .black.opacity(0.35),
                                                radius: 2, x: 0, y: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                        TextEditor(text: $model.deckText)
                            .font(.system(
                                isMacUI ? .title3 : .body,
                                design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .hiddenScrollBackground()
                            .background(SuedePanel())
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .frame(height: 150)
                            .focused($focus, equals: .deck)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.gold.opacity(0.5)))
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    List {
                        Section {
                            sectionHeader("Quality")
                                .hiddenRowSeparator()
                            FantasySegmentedControl(
                                items: [(1, "300"), (2, "600"),
                                        (4, "1200"), (6, "1800")],
                                selection: $model.scale,
                                fontSize: isMacUI ? 15 : 13)
                            HStack(spacing: 18) {
                                Toggle(isOn: $model.guides) {
                                    KingdomText(text: "Cutting guides",
                                                size: isMacUI ? 20 : 19)
                                }
                                Toggle(isOn: $model.thickGuides) {
                                    KingdomText(text: "Thick guides",
                                                size: isMacUI ? 20 : 19)
                                }
                                .disabled(!model.guides)
                            }
                            .frame(maxWidth: .infinity,
                                   alignment: .center)
                            Toggle(isOn: $model.shuffleBeforeRender) {
                                KingdomText(text: "Shuffle before rendering",
                                            size: isMacUI ? 20 : 19)
                            }
                            HStack {
                                KingdomText(text: "Paper",
                                            size: isMacUI ? 20 : 19)
                                Spacer()
                                Picker("", selection: $model.paper) {
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
                            OrnamentCaption(text: model.paperCaption,
                                            size: 16)
                            if model.paper.isCustom {
                                HStack {
                                    KingdomText(text: "Paper width (mm)",
                                                size: isMacUI ? 20 : 19)
                                    Spacer()
                                    KingdomText(
                                        text: String(
                                            format: "%.0f",
                                            model.customPaperWidthMM),
                                        size: isMacUI ? 20 : 19)
                                    Stepper("",
                                            value: $model.customPaperWidthMM,
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
                                            model.customPaperHeightMM),
                                        size: isMacUI ? 20 : 19)
                                    Stepper("",
                                            value: $model.customPaperHeightMM,
                                            in: 100...700, step: 1)
                                        .labelsHidden()
                                }
                            }
                            HideawayGroup(title: "Print options",
                                          summary: model.printOptionsSummary) {
                                VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: $model.backToBack) {
                                KingdomText(text: "Two sided back to back",
                                            size: isMacUI ? 20 : 19)
                            }
                            HStack {
                                KingdomText(text: "Shift up (mm)",
                                            size: isMacUI ? 20 : 19)
                                Spacer()
                                KingdomText(
                                    text: String(format: "%.1f",
                                                 model.shiftUpMM),
                                    size: isMacUI ? 20 : 19)
                                Stepper("", value: $model.shiftUpMM,
                                        in: 0...4, step: 0.5)
                                    .labelsHidden()
                            }
                            HStack {
                                KingdomText(text: "Extra gap (mm)",
                                            size: isMacUI ? 20 : 19)
                                Spacer()
                                KingdomText(
                                    text: String(format: "%.2f",
                                                 model.extraGapMM),
                                    size: isMacUI ? 20 : 19)
                                Stepper("", value: $model.extraGapMM,
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
                                    selection: $model.marginMode,
                                    fontSize: isMacUI ? 15 : 13)
                                    .frame(width: isMacUI ? 280 : 240)
                            }
                            Toggle(isOn: $model.maximizeGap) {
                                KingdomText(text: "Max gap",
                                            size: isMacUI ? 20 : 19)
                            }
                            if model.maximizeGap {
                                OrnamentCaption(
                                    text: model.resolvedGapCaption,
                                    size: 16)
                            }
#if os(macOS)
                            Group {
                                if model.marginMode == .fit {
                                    HStack {
                                        KingdomText(text: "Printer",
                                                    size: isMacUI ? 20 : 19)
                                        Spacer()
                                        Picker("", selection: $model.fitPrinter) {
                                            ForEach(model.printerNames,
                                                    id: \.self) { name in
                                                Text(name).tag(Optional(name))
                                            }
                                        }
                                        .labelsHidden()
                                        .frame(width: isMacUI ? 190 : 170)
                                        .pickerChip()
                                        .onChange(of: model.fitPrinter) { _ in
                                            model.fitPrinterPicked()
                                        }
                                    }
                                    if !model.fitStatus.isEmpty {
                                        if model.fitStatusIsSuccess {
                                            SuccessCaption(
                                                text: model.fitStatus,
                                                size: 17)
                                        } else {
                                            OrnamentCaption(
                                                text: model.fitStatus,
                                                size: 16)
                                        }
                                    }
                                    Button {
                                        model.refreshFit(adoptPaper: false)
                                    } label: {
                                        KingdomText(text: "Read again",
                                                    size: 16)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .onChange(of: model.marginMode) { _ in
                                model.fitToggled()
                            }
                            .onChange(of: model.paper) { _ in
                                model.fitPaperPicked()
                            }
                            .onAppear {
                                model.fitAppeared()
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
                                selection: $model.markKind,
                                fontSize: isMacUI ? 15 : 13)
                            if model.markKind != .none {
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
                                                    model.markColor == swatch.color
                                                        ? Theme.gold
                                                        : Color.black.opacity(0.3),
                                                    lineWidth: model.markColor == swatch.color
                                                        ? 2.5 : 1))
                                            .onTapGesture {
                                                model.markColor = swatch.color
                                            }
                                    }
                                }
                            }
                            if model.markKind == .label {
                                HStack {
                                    KingdomText(text: "Mark font",
                                                size: isMacUI ? 20 : 19)
                                    Spacer()
                                    Picker("", selection: $model.markFont) {
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
                            if model.markKind == .label
                                || model.markKind == .logo {
                                HStack {
                                    KingdomText(text: "Mark spot",
                                                size: isMacUI ? 20 : 19)
                                    Spacer()
                                    Picker("", selection: $model.markPosition) {
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
                            if model.markKind == .border {
                                HStack {
                                    KingdomText(text: "Border width (mm)",
                                                size: isMacUI ? 20 : 19)
                                    Spacer()
                                    KingdomText(
                                        text: String(format: "%.1f",
                                                     model.markBorderMM),
                                        size: isMacUI ? 20 : 19)
                                    Stepper("", value: $model.markBorderMM,
                                            in: 1...6, step: 0.5)
                                        .labelsHidden()
                                }
                            }
                            if model.markKind != .none {
                                HStack {
                                    Spacer()
                                    VStack(spacing: 6) {
                                        ProxyMarkPreview(
                                            mark: model.proxyMark)
                                        OrnamentCaption(
                                            text: "Preview: the mark on a card, in its spot",
                                            size: 16)
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .listRowBackground(Color.clear)

                        Section {
                            sectionHeader("Color")
                                .hiddenRowSeparator()
                            HideawayGroup(title: "Low ink calibration",
                                          summary: model.calibrationSummary) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Toggle(isOn: $model.useCalibration) {
                                        KingdomText(text: "Use calibration",
                                                    size: isMacUI ? 20 : 19)
                                    }
                                    if model.useCalibration {
                                        boostSlider("Cyan boost",
                                                    $model.cyanBoost)
                                        boostSlider("Magenta boost",
                                                    $model.magentaBoost)
                                        boostSlider("Yellow boost",
                                                    $model.yellowBoost)
                                    }
                                }
                            }
                            HStack {
                                Spacer()
                                RealismSticker(
                                    isOn: model.autoVibrance) {
                                    model.autoVibrance.toggle()
                                }
                                Spacer()
                            }
                            OrnamentCaption(
                                text: model.autoVibrance
                                    ? "Auto is on: 40% vibrance and 12% midtone lift. The two sliders sit this one out."
                                    : "Auto is off: tap the sticker to make your prints pop.",
                                size: 16)
                                .frame(maxWidth: .infinity)
                            vibranceSlider($model.vibrance)
                                .disabled(model.autoVibrance)
                                .opacity(model.autoVibrance
                                            ? 0.45 : 1)
                            midtoneSlider($model.midtoneLift)
                                .disabled(model.autoVibrance)
                                .opacity(model.autoVibrance
                                            ? 0.45 : 1)
                        }
                        .listRowBackground(Color.clear)

                        Section {
                            sectionHeader("Format")
                                .hiddenRowSeparator()
                            FantasySegmentedControl(
                                items: [(.pdf, "PDF"), (.png, "PNG"),
                                        (.jpeg, "JPEG")],
                                selection: $model.format,
                                fontSize: isMacUI ? 15 : 13)
                            if model.format == .jpeg {
                                VStack(spacing: 2) {
                                    HStack {
                                        KingdomText(
                                            text: "JPEG quality",
                                            size: isMacUI ? 19 : 19)
                                        Spacer()
                                        KingdomText(
                                            text: "\(Int(model.jpegQuality * 100))%",
                                            size: isMacUI ? 19 : 19)
                                    }
                                    Slider(value: $model.jpegQuality,
                                           in: 0.3...0.95)
                                        .tint(Theme.gold)
                                }
                            }
                            OrnamentCaption(text: formatCaption)
                        }
                        .listRowBackground(Color.clear)

                        if let result = model.result {
                            Section {
                                sectionHeader("Finished")
                                    .hiddenRowSeparator()
                                KingdomText(
                                    text: "\(result.frontCount) card fronts, \(result.pageCount) pages",
                                    size: isMacUI ? 19 : 18)
                                if result.backCount > 0 {
                                    KingdomText(
                                        text: "Two sided backs: \(result.backNames.joined(separator: ", "))",
                                        size: isMacUI ? 19 : 18)
                                }
                                KingdomText(
                                    text: "Size: \(ByteCountFormatter.string(fromByteCount: Int64(result.sizeBytes), countStyle: .file))",
                                    size: isMacUI ? 19 : 18)
                                if let savedMessage {
                                    KingdomText(text: savedMessage,
                                                size: isMacUI ? 18 : 17)
                                }
                                if !result.warnings.isEmpty {
                                    ForEach(result.warnings, id: \.self) { warning in
                                        Text(warning)
                                            .font(.footnote)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                            .listRowBackground(Color.clear)
                        }

                        if let errorText = model.errorText {
                            Section {
                                Text(errorText).foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    // Take whatever height the deck editor leaves,
                    // so the list scrolls inside the panel instead
                    // of pushing the build bar off the window. A
                    // List, not a Form, since Nov 2, 2026: once the
                    // rows grew taller the Form sized itself to its
                    // contents and stopped scrolling, clipping the
                    // bottom of the page and the build bar.
                    .frame(maxHeight: .infinity)
                    .hiddenScrollBackground()
                    .foregroundStyle(Theme.ink)
                    .font(Theme.fellFont(size: isMacUI ? 16 : 15))
                }
                .navigationTitle("")
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focus = nil }
                    }
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.plainText]) { outcome in
            if case .success(let url) = outcome {
                model.loadDeckFile(url)
            }
        }
        .fileExporter(isPresented: $showExporter,
                      document: exportDocument,
                      contentType: exportDocument?.url.pathExtension
                          == "zip" ? .zip
                        : exportDocument?.url.pathExtension
                          == "png" ? .png
                        : exportDocument?.url.pathExtension
                          == "jpg" ? .jpeg : .pdf,
                      defaultFilename: model.result?.outputURL
                          .lastPathComponent ?? "proxies.pdf") { outcome in
            switch outcome {
            case .success(let url):
                savedMessage = "Saved to \(url.lastPathComponent)"
            case .failure(let error):
                model.errorText = "Save failed: \(error)"
            }
        }
    }

    /// The always visible action strip: Build before a run, progress
    /// and Cancel during one, Save and Share after a successful one.
    private var actionBar: some View {
        VStack(spacing: 6) {
            if !model.isRunning {
                HStack(spacing: 10) {
                    Text("FILE NAME")
                        .font(Theme.plaqueFont(
                            size: isMacUI ? 15 : 13))
                        .foregroundStyle(Theme.gold)
                    TextField("File name", text: $model.outputName)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.fellFont(
                            size: isMacUI ? 20 : 18))
                        .multilineTextAlignment(.center)
                        .colorScheme(.light)
                }
            }
            if model.isRunning {
                ProgressView(value: model.fraction)
                HStack {
                    KingdomText(text: model.errorText
                                        ?? model.stageText,
                                size: isMacUI ? 19 : 19)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Cancel", role: .destructive) {
                        model.cancel()
                    }
                }
            } else if let result = model.result {
                HStack(spacing: 10) {
                    Button {
                        exportDocument = BuildFileDocument(
                            url: result.outputURL)
                        showExporter = true
                    } label: {
                        Label(model.format == .pdf ? "Save PDF"
                              : model.format == .png ? "Save PNG"
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
                if model.format == .pdf {
                    PrintJobButtons(model: model, result: result,
                                    message: $savedMessage)
                }
                Button("Build again") {
                    focus = nil
                    savedMessage = nil
                    model.start()
                }
                .controlSize(isMacUI ? .large : .regular)
                .disabled(!model.canRun)
            } else {
                ZStack {
                    Button {
                        focus = nil
                        savedMessage = nil
                        model.start()
                    } label: {
                        Text(model.format == .pdf
                             ? "Build PDF"
                             : "Build \(model.format.label)")
                    }
                    .buttonStyle(FantasyButtonStyle(
                        fontSize: isMacUI ? 23 : 20))
                    .disabled(!model.canRun
                              || model.pngRefusedFromText)
                    if model.pngRefusedFromText {
                        Image(systemName: "xmark")
                            .font(.system(size: 30,
                                          weight: .black))
                            .foregroundStyle(.red)
                            .shadow(color: .black.opacity(0.6),
                                    radius: 2)
                            .allowsHitTesting(false)
                    }
                }
                .help(model.pngRefusedFromText
                      ? model.pngLimitNotice(
                            cards: PrintJobModel.cardCount(
                                in: model.deckText),
                            twoSided: nil)
                      : "")
            }
            if !model.isRunning, !model.sizeCaption.isEmpty {
                KingdomText(text: model.sizeCaption,
                            size: isMacUI ? 16 : 15)
            }
            if !model.isRunning, let warning = model.pngWarning {
                Text(warning)
                    .foregroundStyle(.orange)
                    .font(isMacUI ? .body : .callout)
                    .multilineTextAlignment(.center)
            }
            if !model.isRunning, model.pngRefusedFromText {
                Text(model.pngLimitNotice(
                        cards: PrintJobModel.cardCount(
                            in: model.deckText),
                        twoSided: nil))
                    .foregroundStyle(.orange)
                    .font(isMacUI ? .body : .callout)
                    .multilineTextAlignment(.center)
            }
            if !model.isRunning, model.format == .png,
               model.pngRefusedFromText || model.pngOverride {
                GuardedOverride(isOn: $model.pngOverride)
            }
        }
    }
}

#Preview {
    ContentView()
}
