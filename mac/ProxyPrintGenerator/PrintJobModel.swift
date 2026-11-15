//
//  PrintJobModel.swift
//  Version 29
//  Proxy Printer (native port) — Phase 2 view model
//
//  Holds the screen's state and runs one print job at a time through
//  ProxyPrintEngine, translating its progress callbacks into published
//  values the view can show. The finished PDF lands in the app's
//  Documents folder, ready for the share sheet on both platforms.
//

import Foundation
import Combine
import SwiftUI
import PDFKit
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

@MainActor
final class PrintJobModel: ObservableObject {

    // Inputs
    @Published var deckText: String = ""
    @Published var scale: Int = 4
    @Published var guides: Bool = true
    @Published var useCalibration: Bool = false
    // 1.0 across the board since the fresh cartridges went
    // in: the old 1.35/1.30/1.30 defaults were tuned to the
    // dying set and only darken prints now.
    @Published var cyanBoost: Double = 1.0
    @Published var magentaBoost: Double = 1.0
    @Published var yellowBoost: Double = 1.0
    /// Saturation lift for the build, 0 (off) to 0.6.
    /// Independent of the ink calibration above.
    @Published var vibrance: Double = 0
    /// Midtone lift for the build, 0 (off) to 0.35, run
    /// as a gamma of 1 minus this value.
    @Published var midtoneLift: Double = 0
    /// The realism sticker's switch: while it is on, the
    /// build runs the Windows Auto recipe, 40% vibrance
    /// and 12% midtone lift, whatever the sliders say.
    @Published var autoVibrance: Bool = false

    /// The vibrance the next build actually uses.
    var effectiveVibrance: Double {
        autoVibrance ? 0.40 : vibrance
    }

    /// The midtone lift the next build actually uses.
    var effectiveMidtoneLift: Double {
        autoVibrance ? 0.12 : midtoneLift
    }
    /// Printer safe area profile for the build.
    @Published var safeArea: SafeAreaProfile = .none
    /// How the build keeps cards inside the printable
    /// area: not at all, or fitted to the chosen
    /// printer's own reach. One choice in the margin
    /// settings, where the Canon safe area preset used
    /// to sit: the preset was the same promise with the
    /// numbers typed in by hand, so Fit replaces it.
    enum MarginMode: String, CaseIterable, Sendable {
        case off
        case fit
    }

    /// The Safe area choice in the margin settings.
    /// Fit to my printer keeps every card inside the
    /// reach the chosen printer's driver reports, and
    /// it is on by default (Liam, Nov 13, 2026):
    /// clipped edges were the app's original sin, and
    /// every way the reading can fail falls back to
    /// laying out without it. macOS only; on iOS the
    /// Fit choice stays inert.
    @Published var marginMode: MarginMode = .fit

    /// Whether Fit to my printer is the chosen mode.
    var fitToPrinter: Bool { marginMode == .fit }
    @Published var fitPrinter: String? = nil
    @Published var fitMargins: PrinterMargins? = nil
    @Published var fitStatus: String = ""

    /// Whether the current fit status is a good
    /// reading (shown in green with a check mark)
    /// rather than a warning.
    var fitStatusIsSuccess: Bool {
        fitToPrinter && fitMargins != nil
    }
    @Published var printerNames: [String] = []
    /// Reads in flight, so a slow driver answer never
    /// overwrites a newer one.
    private var fitReadCount = 0

    /// The driver margins the next build uses, when
    /// fit is on.
    var activePrinterMargins: PrinterMargins? {
        fitToPrinter ? fitMargins : nil
    }

    /// A paper size's short name, for captions.
    static func paperLabel(_ paper: PaperSize) -> String {
        switch paper {
        case .letter: return "Letter"
        case .a4: return "A4"
        case .legal: return "Legal"
        case .tabloid: return "11 by 17"
        case .a3: return "A3"
        case .custom: return "Custom"
        }
    }
    /// Push the gaps to the most the sheet allows.
    @Published var maximizeGap: Bool = false
    /// Heavier dotted cutting guides.
    @Published var thickGuides: Bool = false
    /// The sheet the pages are built for.
    @Published var paper: PaperSize = .letter
    /// Custom sheet dimensions in mm, used when the
    /// paper choice is Custom.
    @Published var customPaperWidthMM: Double = 216
    @Published var customPaperHeightMM: Double = 279

    /// The chosen paper with any custom dimensions
    /// filled in from the steppers.
    var resolvedPaper: PaperSize {
        if paper.isCustom {
            return .custom(widthMM: customPaperWidthMM,
                           heightMM: customPaperHeightMM)
        }
        return paper
    }

    /// The proxy mark settings. The choice lives in the
    /// model for the session, like the other job settings.
    @Published var markKind: ProxyMarkKind = .none
    @Published var markColor: RGBColor = RGBColor(196, 28, 44)
    @Published var markPosition: MarkPosition = .topLeft
    @Published var markBorderMM: Double = 3.0
    @Published var markFont: MarkFont = .cinzel

    /// The eight mark colors, the Windows build's palette.
    static let markPalette: [(name: String, color: RGBColor)] = [
        ("Red", RGBColor(196, 28, 44)),
        ("Black", RGBColor(20, 20, 20)),
        ("White", RGBColor(250, 250, 250)),
        ("Blue", RGBColor(30, 90, 200)),
        ("Green", RGBColor(30, 130, 70)),
        ("Purple", RGBColor(122, 46, 158)),
        ("Orange", RGBColor(224, 112, 26)),
        ("Gold", RGBColor(201, 150, 47)),
    ]

    /// The mark the current settings describe.
    var proxyMark: ProxyMark {
        ProxyMark(kind: markKind, color: markColor,
                  position: markPosition, borderMM: markBorderMM,
                  font: markFont)
    }

    /// Cards per sheet at the chosen paper, worded for
    /// the caption under the paper picker.
    var paperCaption: String {
        var s = PrintSettings()
        s.paper = resolvedPaper
        s.printerMargins = activePrinterMargins
        return "\(s.cardsPerPage) cards per sheet "
            + "(\(s.columns) across, \(s.rows) down)"
    }

    /// The gaps the current settings resolve to, worded
    /// for the caption under the gap controls.
    var resolvedGapCaption: String {
        var s = PrintSettings()
        s.paper = resolvedPaper
        s.gapMM = 3.0 + extraGapMM
        s.safeArea = safeArea
        s.printerMargins = activePrinterMargins
        s.maximizeGap = maximizeGap
        let gaps = s.resolvedGapsMM()
        return String(
            format: "Resolved gaps: %.1fmm between rows, "
                + "%.1fmm between columns",
            gaps.row, gaps.column)
    }

    /// How many cards the current list holds, counting
    /// quantities. Section headers and comments are ignored,
    /// so the number is approximate by design.
    static func cardCount(in text: String) -> Int {
        var total = 0
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//")
                || line.hasPrefix("#") { continue }
            let first = line.split(separator: " ").first ?? ""
            if let qty = Int(first) {
                total += qty
            } else if line.contains("(") {
                total += 1
            }
        }
        return total
    }

    /// Rough output size in bytes for the current settings.
    /// Calibrated against real builds: the 1200 dpi
    /// Narcoberries PDF landed within a few percent of the
    /// bytes per pixel used for PDFs here.
    var estimatedOutputBytes: Int64 {
        let cards = Self.cardCount(in: deckText)
        guard cards > 0 else { return 0 }
        let dpi = Double(scale) * 300.0
        let pagePixels = 8.5 * dpi * (11.0 * dpi)
        let pages = Int(ceil(Double(cards) / 9.0))
        switch format {
        case .pdf:
            let facePixels = (63.0 / 25.4 * dpi)
                * (88.0 / 25.4 * dpi)
            return Int64(Double(cards) * facePixels * 0.95)
        case .png:
            return Int64(Double(pages) * pagePixels * 0.85)
        case .jpeg:
            return Int64(Double(pages) * pagePixels
                * (0.12 + 0.42 * jpegQuality))
        }
    }

    /// Working room a build wants on the volume, beyond the
    /// output itself: staged page files and the JPEG scratch
    /// canvas for the image formats, plus a first build's
    /// face cache at a new scale.
    var estimatedWorkingBytes: Int64 {
        let output = estimatedOutputBytes
        guard output > 0 else { return 0 }
        let cards = Self.cardCount(in: deckText)
        let dpi = Double(scale) * 300.0
        let facePixels = (63.0 / 25.4 * dpi)
            * (88.0 / 25.4 * dpi)
        let cache = Int64(Double(cards) * facePixels * 0.45)
        let staging = format == .pdf ? output / 3 : output * 3 / 2
        return output + staging + cache
    }

    /// Free space on the volume the build writes to. The
    /// important usage figure is the honest one: it counts
    /// space the system can purge on demand. One call, no
    /// scanning, effectively instant.
    var freeDiskBytes: Int64 {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        let values = try? documents.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
            ?? 0
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes,
                                  countStyle: .file)
    }

    /// The slow corner, named before it is entered: PNG
    /// at 1800 with several of the extra options on takes
    /// minutes even for a small print, because every face
    /// is filtered and losslessly encoded at full size.
    /// The options counted are the low ink calibration,
    /// Vibrance, Midtone lift, Max gap, and Thick guides.
    var pngWarning: String? {
        guard format == .png, scale == 6 else { return nil }
        var options = 0
        if useCalibration { options += 1 }
        if effectiveVibrance > 0 { options += 1 }
        if effectiveMidtoneLift > 0 { options += 1 }
        if maximizeGap { options += 1 }
        if thickGuides { options += 1 }
        guard options > 2 else { return nil }
        return "Heads up: PNG at 1800 with several options "
            + "on takes a long time. Figure 6 minutes "
            + "or more, even for a small print."
    }

    /// Armed by the guarded switch in the build bars.
    /// Session only, never saved: a fresh launch starts
    /// with the override off.
    @Published var pngOverride: Bool = false

    /// Whether a PNG build of this size is refused: over
    /// 12 cards or over 2 two sided cards, unless the
    /// override switch is on.
    func pngRefused(cards: Int, twoSided: Int) -> Bool {
        format == .png && !pngOverride
            && (cards > 12 || twoSided > 2)
    }

    /// The refusal, worded for the notice under the
    /// crossed out build button and its hover text.
    func pngLimitNotice(cards: Int, twoSided: Int?)
        -> String {
        var text = "PNG is limited to 12 cards and 2 two "
            + "sided cards. This build has \(cards) cards"
        if let twoSided {
            text += " and \(twoSided) two sided"
        }
        return text + "."
    }

    /// Shuffle the deck's order for the build, commander
    /// pinned at the front. For decks built to be played
    /// straight off the printer.
    @Published var shuffleBeforeRender: Bool = false

    /// Two sided cards print back to back: the one sided
    /// cards come first, then the two sided cards as front
    /// and back page pairs, each back mirrored behind its
    /// front for double sided printing.
    @Published var backToBack: Bool = false

    /// Quick Build's refusal, from the list text alone:
    /// two sided cards are only known after the fetch
    /// there, so the engine still checks those itself.
    var pngRefusedFromText: Bool {
        pngRefused(cards: Self.cardCount(in: deckText),
                   twoSided: 0)
    }

    /// The one line shown beside the build button.
    var sizeCaption: String {
        guard estimatedOutputBytes > 0 else { return "" }
        return "Output ≈ \(Self.formatBytes(estimatedOutputBytes))"
            + "  •  Free \(Self.formatBytes(freeDiskBytes))"
    }

    @Published var outputName: String = "proxies"
    @Published var format: OutputFormat = .pdf
    @Published var jpegQuality: Double = 0.65
    /// What's on under Print options, for its closed title:
    /// "back to back, shift up 1.0 mm", or "all off".
    var printOptionsSummary: String {
        var on: [String] = []
        if backToBack { on.append("back to back") }
        if shiftUpMM > 0 {
            on.append(String(format: "shift up %.1f mm", shiftUpMM))
        }
        if extraGapMM > 0 {
            on.append(String(format: "extra gap %.2f mm", extraGapMM))
        }
        if marginMode == .fit { on.append("fit to my printer") }
        if maximizeGap { on.append("max gap") }
        return on.isEmpty ? "all off" : on.joined(separator: ", ")
    }

    var calibrationSummary: String { useCalibration ? "on" : "off" }

    @Published var shiftUpMM: Double = 0
    @Published var extraGapMM: Double = 0

    // Run state
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var stageText: String = ""
    @Published private(set) var fraction: Double = 0
    @Published var result: PrintJobResult?
    @Published var errorText: String?

    private var jobTask: Task<Void, Never>?

    var canRun: Bool {
        !isRunning
            && !deckText.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    func start() {
        // Default priority: the utility priority experiment
        // starved heavy builds, and the chunked progress
        // reporting keeps the interface honest instead.
        jobTask = Task { await self.runJob() }
    }

    func cancel() {
        jobTask?.cancel()
    }

    /// Reads a deck list file picked by the user into the editor.
    func loadDeckFile(_ url: URL) {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            deckText = try String(contentsOf: url, encoding: .utf8)
            errorText = nil
        } catch {
            errorText = "Could not read that file: \(error)"
        }
    }

    private func runJob() async {
        isRunning = true
        result = nil
        errorText = nil
        stageText = "Starting"
        fraction = 0
        defer { isRunning = false }

        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        var name = outputName.trimmingCharacters(in: .whitespaces)
        for suffix in [".pdf", ".zip", ".png", ".jpg"]
        where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        if name.isEmpty { name = "proxies" }
        let outputURL = documents.appendingPathComponent(
            name + "." + format.fileExtension)

        // Cheap insurance before a long build: the biggest
        // builds want several gigabytes of working room, and
        // finding out halfway through helps nobody.
        let free = freeDiskBytes
        let needed = estimatedWorkingBytes
        if free > 0, needed > 0, free < needed {
            errorText = "[PPG:DISK-SPACE] Not enough free "
                + "space for this build: it wants about "
                + "\(Self.formatBytes(needed)) of working room "
                + "and only \(Self.formatBytes(free)) is free."
            return
        }
        let calibration = useCalibration
            ? InkCalibration(cyan: cyanBoost, magenta: magentaBoost,
                             yellow: yellowBoost)
            : InkCalibration.none

        do {
            let jobResult = try await ProxyPrintEngine.run(
                deckText: deckText,
                outputURL: outputURL,
                scale: scale,
                calibration: calibration,
                vibrance: effectiveVibrance,
                midtoneLift: effectiveMidtoneLift,
                pngOverride: pngOverride,
                shuffleDeck: shuffleBeforeRender,
                backToBack: backToBack,
                safeArea: safeArea,
                printerMargins: activePrinterMargins,
                maximizeGap: maximizeGap,
                thickGuides: thickGuides,
                paper: resolvedPaper,
                mark: proxyMark,
                guides: guides,
                format: format,
                jpegQuality: jpegQuality,
                extraGapMM: extraGapMM,
                shiftUpMM: shiftUpMM,
                cacheDirectory: ProxyPrintEngine.defaultCacheDirectory()
            ) { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.stageText = update.stage
                    self?.fraction = update.fraction
                }
            }
            result = jobResult
            stageText = "Done"
            fraction = 1
        } catch is CancellationError {
            stageText = "Cancelled"
        } catch {
            errorText = "\(error)"
            stageText = ""
        }
    }

    // MARK: - Fit to my printer (macOS)

    /// The margin mode changed: Fit picks a printer
    /// and reads it; Off clears the reading.
    func fitToggled() {
        #if os(macOS)
        if fitToPrinter {
            turnOnFit()
        } else {
            fitStatus = ""
            fitMargins = nil
        }
        #endif
    }

    /// A printer was picked while fit is on: start
    /// from the paper that printer is set to.
    func fitPrinterPicked() {
        #if os(macOS)
        if fitToPrinter { refreshFit(adoptPaper: true) }
        #endif
    }

    /// The paper changed while fit is on: read the
    /// same printer again for the new paper.
    func fitPaperPicked() {
        #if os(macOS)
        if fitToPrinter { refreshFit(adoptPaper: false) }
        #endif
    }

    /// The margin settings appeared: Fit is on by
    /// default, so pick a printer and read it without
    /// anyone touching the switch. Appearing does not
    /// adopt the driver's paper over the paper chosen
    /// in the app; adopting stays with switching Fit
    /// on or picking a printer.
    func fitAppeared() {
        #if os(macOS)
        if fitToPrinter { turnOnFit(adoptPaper: false) }
        #endif
    }

    /// Fit switched on: choose the printer (the one
    /// already picked, else this Mac's default, else
    /// the first installed), then read its driver.
    func turnOnFit(adoptPaper: Bool = true) {
        #if os(macOS)
        if printerNames.isEmpty {
            printerNames = PrinterFitReader.printerNames()
        }
        let current = fitPrinter
        if current == nil
            || !printerNames.contains(current!) {
            let fallback = PrinterFitReader
                .defaultPrinterName()
            let pick = fallback.flatMap {
                printerNames.contains($0) ? $0 : nil
            } ?? printerNames.first
            guard let pick = pick else {
                fitStatus = "No printers are installed "
                    + "on this Mac."
                return
            }
            fitPrinter = pick
        }
        refreshFit(adoptPaper: adoptPaper)
        #endif
    }

    /// Ask the chosen printer's driver what it can
    /// reach, on the chosen paper (or on the paper the
    /// driver is set to, when adopting, which then
    /// becomes the chosen paper). Mirrors the Windows
    /// read, status wording included.
    func refreshFit(adoptPaper: Bool) {
        #if os(macOS)
        guard fitToPrinter, let printer = fitPrinter
        else { return }
        fitReadCount += 1
        let mine = fitReadCount
        let target = resolvedPaper
        fitStatus = "Asking the \(printer) driver "
            + "what it can reach\u{2026}"
        Task { [weak self] in
            let reading = await Task.detached(
                priority: .userInitiated
            ) {
                PrinterFitReader.read(
                    printerName: printer,
                    paper: target,
                    adoptDriverPaper: adoptPaper)
            }.value
            guard let self = self,
                  self.fitReadCount == mine
            else { return }
            guard let reading = reading else {
                self.fitMargins = nil
                self.fitStatus = "Couldn't read "
                    + "\(printer)'s driver: it isn't "
                    + "installed on this Mac any more."
                return
            }
            var note = ""
            if adoptPaper, let set = reading.driverPaper,
               set != self.resolvedPaper {
                note = "Your printer is set to "
                    + "\(Self.paperLabel(set)) paper, so "
                    + "the paper size is now "
                    + "\(Self.paperLabel(set)). "
                self.paper = set
            }
            self.fitMargins = reading.paperListed
                ? reading.margins : nil
            let label = Self.paperLabel(self.resolvedPaper)
            if !reading.paperListed {
                self.fitStatus = note + "\(printer) "
                    + "doesn't list \(label) paper, so "
                    + "the cards are laid out without its "
                    + "edges. Pick a paper size it lists, "
                    + "or another printer."
            } else if let margins = reading.margins {
                let total = margins.top + margins.bottom
                    + margins.left + margins.right
                if total < 0.1 {
                    self.fitStatus = note + "Fitted to "
                        + "\(printer): it prints edge to "
                        + "edge on \(label) (borderless), "
                        + "so the cards just stay 1 mm in "
                        + "from the edge."
                } else {
                    self.fitStatus = note + String(
                        format: "Fitted to %@: on %@ paper "
                            + "it prints to within %.1f mm "
                            + "of the top, %.1f mm of the "
                            + "bottom, %.1f mm on the left "
                            + "and %.1f mm on the right, and "
                            + "the cards are laid out inside "
                            + "that reach, with 1 mm to spare.",
                        printer, label, margins.top,
                        margins.bottom, margins.left,
                        margins.right)
                }
            } else {
                self.fitStatus = note + "\(printer) "
                    + "didn't say where it can print, so "
                    + "the cards are laid out without its "
                    + "edges."
            }
        }
        #endif
    }

    // MARK: - Driver print presets (macOS)

    /// The preset names the default printer's driver
    /// offers: its own factory presets plus any the
    /// user saved in the print panel.
    static func driverPresetNames() -> [String] {
        #if os(macOS)
        let info = NSPrintInfo.shared
        let session = unsafeBitCast(
            info.pmPrintSession(), to: PMPrintSession.self)
        var printer: PMPrinter?
        guard PMSessionGetCurrentPrinter(
                session, &printer) == noErr,
              let printer = printer else { return [] }
        var presetsRef: Unmanaged<CFArray>?
        guard PMPrinterCopyPresets(
                printer, &presetsRef) == noErr,
              let presets = presetsRef?
                .takeRetainedValue()
        else { return [] }
        var names: [String] = []
        let count = CFArrayGetCount(presets)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(
                presets, index) else { continue }
            let preset = unsafeBitCast(
                raw, to: PMPreset.self)
            var nameRef: Unmanaged<CFString>?
            if PMPresetCopyName(
                    preset, &nameRef) == noErr,
               let unwrapped = nameRef?
                .takeRetainedValue() {
                names.append(unwrapped as String)
            }
        }
        return names
        #else
        return []
        #endif
    }

    #if os(macOS)
    /// Apply one of the driver's presets, by name, to
    /// a print info. Callers set the build's paper size
    /// and the job's duplex choice after this, so those
    /// win over whatever the preset holds. Best effort:
    /// a preset that will not apply leaves the info
    /// untouched.
    static func applyDriverPreset(named name: String,
                                  to info: NSPrintInfo) {
        #if os(macOS)
        let session = unsafeBitCast(
            info.pmPrintSession(), to: PMPrintSession.self)
        var printer: PMPrinter?
        guard PMSessionGetCurrentPrinter(
                session, &printer) == noErr,
              let printer = printer else { return }
        var presetsRef: Unmanaged<CFArray>?
        guard PMPrinterCopyPresets(
                printer, &presetsRef) == noErr,
              let presets = presetsRef?
                .takeRetainedValue()
        else { return }
        let count = CFArrayGetCount(presets)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(
                presets, index) else { continue }
            let preset = unsafeBitCast(
                raw, to: PMPreset.self)
            var nameRef: Unmanaged<CFString>?
            guard PMPresetCopyName(
                    preset, &nameRef) == noErr,
                  let unwrapped = nameRef?
                    .takeRetainedValue(),
                  (unwrapped as String) == name
            else { continue }
            var settings: PMPrintSettings?
            if PMPresetCreatePrintSettings(
                    preset, session,
                    &settings) == noErr,
               let created = settings {
                _ = PMCopyPrintSettings(
                    created,
                    unsafeBitCast(
                        info.pmPrintSettings(),
                        to: PMPrintSettings.self))
                PMRelease(unsafeBitCast(
                    created, to: PMObject.self))
            }
            return
        }
        #endif
    }
    #endif

    /// Send pages of the built PDF to the native print panel:
    /// the whole file when `range` is nil, or just that slice
    /// of pages. `duplex` presets the panel to long edge two
    /// sided printing. Returns a short line for the screen, or
    /// nil when there is nothing to say.
    func printPages(_ range: Range<Int>?,
                    duplex: Bool,
                    presetName: String? = nil) -> String? {
        guard let result else { return nil }
        var url = result.outputURL
        if let range {
            guard let sliced = Self.slicePDF(result.outputURL,
                                             pages: range) else {
                return "[PPG:PRINT] Could not prepare those "
                    + "pages for printing."
            }
            url = sliced
        }
        return Self.presentPrintPanel(url: url,
                                      jobName: outputName,
                                      duplex: duplex,
                                      presetName: presetName)
    }

    /// A copy of the PDF holding only the given pages, in the
    /// temporary folder, for handing to the print panel.
    static func slicePDF(_ url: URL,
                                 pages range: Range<Int>) -> URL? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let out = PDFDocument()
        var index = 0
        for i in range {
            guard i >= 0, i < doc.pageCount,
                  let page = doc.page(at: i) else { return nil }
            out.insert(page, at: index)
            index += 1
        }
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "print-\(url.deletingPathExtension().lastPathComponent)"
                    + "-\(range.lowerBound + 1)-\(range.upperBound).pdf")
        return out.write(to: target) ? target : nil
    }

    /// The platform print panel over one PDF file, at actual
    /// size: the pages in the file are already the printed
    /// page, so no scaling and no rotation. The printer,
    /// copies, paper, color, and the Canon driver choices all
    /// live in the panel itself, where they belong.
    static func presentPrintPanel(url: URL,
                                  jobName: String,
                                  duplex: Bool,
                                  presetName: String? = nil,
                                  printerName: String? = nil)
        -> String? {
        #if os(macOS)
        guard let doc = PDFDocument(url: url) else {
            return "[PPG:PRINT] Could not open the built file "
                + "for printing."
        }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        if let printerName, let printer = NSPrinter(name: printerName) {
            info.printer = printer
        }
        // A chosen driver preset goes on first: the
        // build's paper size (below) and the duplex
        // choice are set after it, so they win.
        if let presetName = presetName {
            Self.applyDriverPreset(named: presetName,
                                   to: info)
        }
        if let size = doc.page(at: 0)?.bounds(for: .mediaBox).size {
            info.paperSize = size
        }
        // Duplex lives in the Core Printing settings
        // under the print info, not on the info itself:
        // PMDuplexing 2 is long edge, 1 is off.
        info.printSettings[
            "com.apple.print.PrintSettings.PMDuplexing"]
            = NSNumber(value: duplex ? 2 : 1)
        guard let operation = doc.printOperation(
            for: info, scalingMode: .pageScaleNone,
            autoRotate: false) else {
            return "[PPG:PRINT] The print panel could not be "
                + "prepared."
        }
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
        return nil
        #elseif os(iOS)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.duplex = duplex ? .longEdge : .none
        info.jobName = jobName
        controller.printInfo = info
        controller.printingItem = url
        controller.present(animated: true, completionHandler: nil)
        return nil
        #else
        return "[PPG:PRINT] Printing is not available here."
        #endif
    }
}

/// What a printer's driver said when asked (Fit to
/// my printer): its unreachable edges in millimeters
/// for the paper asked about (nil when the driver gave
/// no printable area), whether it lists that paper at
/// all, and the paper it is set to now.
struct PrinterFitReading {
    var margins: PrinterMargins?
    var paperListed: Bool
    var driverPaper: PaperSize?
}

/// Asks a printer's driver what it can reach, through
/// AppKit's print info and the Core Printing page
/// format underneath it. Nothing is printed. Windows
/// can't see what paper is physically loaded either;
/// the driver's current paper setting is the closest
/// thing, exactly as on Windows.
enum PrinterFitReader {

    static func printerNames() -> [String] {
        #if os(macOS)
        return NSPrinter.printerNames.sorted()
        #else
        return []
        #endif
    }

    static func defaultPrinterName() -> String? {
        #if os(macOS)
        return NSPrintInfo.shared.printer.name
        #else
        return nil
        #endif
    }

    /// The paper name a print info knows a size by,
    /// or nil for a custom sheet (set by measure).
    static func paperName(for paper: PaperSize)
        -> String? {
        switch paper {
        case .letter: return "Letter"
        case .a4: return "A4"
        case .legal: return "Legal"
        case .tabloid: return "Tabloid"
        case .a3: return "A3"
        case .custom: return nil
        }
    }

    /// A standard paper size from its print info name.
    static func paper(forName name: String)
        -> PaperSize? {
        switch name {
        case "Letter": return .letter
        case "A4": return .a4
        case "Legal": return .legal
        case "Tabloid": return .tabloid
        case "A3": return .a3
        default: return nil
        }
    }

    /// The app paper matching a size in points, in
    /// either orientation. A size the app does not
    /// know becomes a custom paper of that size:
    /// drivers file their papers under names that
    /// vary ("US Letter", "Letter"), sizes do not.
    static func paper(forSize size: NSSize)
        -> PaperSize? {
        let known: [PaperSize] = [.letter, .a4, .legal,
                                  .tabloid, .a3]
        for candidate in known {
            let s = candidate.size
            let straight = abs(s.width - size.width) < 1.5
                && abs(s.height - size.height) < 1.5
            let turned = abs(s.width - size.height) < 1.5
                && abs(s.height - size.width) < 1.5
            if straight || turned { return candidate }
        }
        if size.width > 10 && size.height > 10 {
            let shortSide = min(size.width, size.height)
            let longSide = max(size.width, size.height)
            return .custom(
                widthMM: Double(shortSide) * 25.4 / 72,
                heightMM: Double(longSide) * 25.4 / 72)
        }
        return nil
    }

    /// Read one printer: the paper it is set to, and
    /// its reach on the target paper (its own paper,
    /// when adopting). Nil when the printer is gone.
    static func read(printerName: String,
                     paper: PaperSize,
                     adoptDriverPaper: Bool)
        -> PrinterFitReading? {
        #if os(macOS)
        guard let printer = NSPrinter(name: printerName)
        else { return nil }
        let info = NSPrintInfo.shared.copy()
            as! NSPrintInfo
        info.printer = printer
        let driverPaper = Self.paper(
                forSize: info.paperSize)
            ?? info.paperName.flatMap {
                Self.paper(forName: $0.rawValue)
            }
        let target = adoptDriverPaper
            ? (driverPaper ?? paper) : paper
        var listed = false
        if let name = Self.paperName(for: target) {
            info.paperName = NSPrinter.PaperName(
                rawValue: name)
            listed = (info.paperName?.rawValue == name)
        }
        if !listed {
            // The name did not stick: some drivers file
            // their papers under names the app cannot
            // guess. Ask for the size itself instead,
            // and count it listed when the size that
            // comes back is the size that was asked for.
            info.paperSize = target.size
            let back = info.paperSize
            listed = abs(back.width - target.size.width)
                    < 1.5
                && abs(back.height - target.size.height)
                    < 1.5
        }
        var margins: PrinterMargins? = nil
        if listed {
            let format = unsafeBitCast(
                info.pmPageFormat(), to: PMPageFormat.self)
            var paperRect = PMRect()
            var pageRect = PMRect()
            if PMGetUnadjustedPaperRect(
                    format, &paperRect) == noErr,
               PMGetUnadjustedPageRect(
                    format, &pageRect) == noErr {
                let k = 25.4 / 72.0
                margins = PrinterMargins(
                    top: max(0, (pageRect.top
                        - paperRect.top) * k),
                    bottom: max(0, (paperRect.bottom
                        - pageRect.bottom) * k),
                    left: max(0, (pageRect.left
                        - paperRect.left) * k),
                    right: max(0, (paperRect.right
                        - pageRect.right) * k))
            }
        }
        return PrinterFitReading(
            margins: margins, paperListed: listed,
            driverPaper: driverPaper)
        #else
        return nil
        #endif
    }
}

/// The print buttons under a finished PDF build: one Print
/// button for a classic build; for a back to back build, the
/// one sided pages and the two sided sheets print as separate
/// jobs, the same split the Windows print flow makes, so the
/// singles never go through the duplex path.
struct PrintJobButtons: View {
    @ObservedObject var model: PrintJobModel
    let result: PrintJobResult
    @Binding var message: String?
    #if os(macOS)
    @State private var request: MacPrintRequest?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
        if result.duplexStartPage >= 0 {
            HStack(spacing: 10) {
                if result.duplexStartPage > 0 {
                    printButton(
                        "Print one sided pages",
                        systemImage: "doc.text") {
                        printPages(0..<result.duplexStartPage,
                                   duplex: false,
                                   title: "Print one sided pages")
                    }
                }
                printButton(
                    "Print two sided sheets",
                    systemImage: "doc.on.doc") {
                    printPages(result.duplexStartPage..<result.pageCount,
                               duplex: true,
                               title: "Print two sided sheets")
                }
            }
        } else {
            printButton("Print", systemImage: "printer") {
                printPages(nil, duplex: false, title: "Print")
            }
        }
        }
        #if os(macOS)
        .sheet(item: $request) { r in
            MacPrintSheet(request: r) { line in
                if let line { message = line }
            }
        }
        #endif
    }

    /// On the Mac, the app's own print sheet; on iOS, the system
    /// print controller, as before.
    private func printPages(_ range: Range<Int>?, duplex: Bool,
                            title: String) {
        #if os(macOS)
        var url = result.outputURL
        if let range {
            guard let sliced = PrintJobModel.slicePDF(
                result.outputURL, pages: range) else {
                message = "[PPG:PRINT] Could not prepare those pages for printing."
                return
            }
            url = sliced
        }
        request = MacPrintRequest(
            title: title, url: url, jobName: model.outputName,
            duplex: duplex,
            fittedPrinter: model.marginMode == .fit ? model.fitPrinter : nil)
        #else
        message = model.printPages(range, duplex: duplex)
        #endif
    }

    private func printButton(_ title: String,
                             systemImage: String,
                             action: @escaping () -> Void)
        -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buildControlSize()
    }
}
