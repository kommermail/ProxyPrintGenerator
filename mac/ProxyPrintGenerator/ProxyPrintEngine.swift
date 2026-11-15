//
//  ProxyPrintEngine.swift
//  Version 19
//  Proxy Printer (native port) — Phase 2 app engine wrapper
//
//  The same pipeline the command line harness runs (parse, Scryfall
//  lookup, image preparation, page by page PDF assembly), packaged as
//  one async call the app can drive with progress updates and
//  cancellation. The four Phase 1 engine files are used unchanged.
//
//  Memory rule, same as the plan: faces are prepared one at a time and
//  the per page working set is released before the next page, so the
//  build stays flat even at 1800 DPI on a phone.
//

import Foundation

public struct PrintProgress: Sendable {
    public var stage: String
    public var done: Int
    public var total: Int
    public var fraction: Double {
        total > 0 ? Double(done) / Double(total) : 0
    }
}

public struct PrintJobResult {
    public var outputURL: URL
    public var frontCount: Int
    public var backCount: Int
    public var backNames: [String]
    public var pageCount: Int
    public var sizeBytes: Int
    public var warnings: [String]
    /// Back to back builds: the page where the front/back
    /// pairs begin, or -1 when the build has none.
    public var duplexStartPage: Int
    /// Sheets that print double sided in a back to back build.
    public var duplexSheets: Int {
        duplexStartPage < 0
            ? 0 : (pageCount - duplexStartPage) / 2
    }
}

/// What a build produces: the classic printable PDF, or the
/// pages as images packed into a zip (PNG at full quality,
/// JPEG when a small file matters more).
public enum OutputFormat: String, CaseIterable, Hashable, Sendable {
    case pdf
    case png
    case jpeg

    public var label: String {
        switch self {
        case .pdf: return "PDF"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        }
    }

    /// The extension of the file the build writes. Both
    /// image formats are one stitched tall file now.
    public var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }
}

private struct FaceSource {
    var url: URL
    var set: String
    var collector: String
}

public enum ProxyPrintEngine {

    /// Where prepared card faces are cached between runs. Lives in the
    /// system caches folder; the system may purge it under storage
    /// pressure, which only costs download time on the next run.
    public static func defaultCacheDirectory() -> URL {
        let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("ProxyPrintCache")
    }

    public static func run(
        deckText: String,
        outputURL: URL,
        scale: Int,
        calibration: InkCalibration,
        vibrance: Double = 0,
        midtoneLift: Double = 0,
        pngOverride: Bool = false,
        shuffleDeck: Bool = false,
        backToBack: Bool = false,
        safeArea: SafeAreaProfile = .none,
        printerMargins: PrinterMargins? = nil,
        maximizeGap: Bool = false,
        thickGuides: Bool = false,
        paper: PaperSize = .letter,
        mark: ProxyMark = .none,
        guides: Bool,
        format: OutputFormat = .pdf,
        jpegQuality: Double = 0.65,
        extraGapMM: Double = 0,
        shiftUpMM: Double = 0,
        cacheDirectory: URL,
        progress: @escaping @Sendable (PrintProgress) -> Void
    ) async throws -> PrintJobResult {

        // Parse and keep the printable (mainboard) entries, as the
        // command line version does.
        let parsed = DeckList.parse(deckText)
        let printable = parsed.entries.filter { $0.board == .main }
        guard !printable.isEmpty else {
            throw ScryfallClientError.message(
                "[PPG:DECK-EMPTY] No printable cards in the deck list.")
        }

        // Resolve every entry to a concrete Scryfall card.
        progress(PrintProgress(stage: "Looking up cards on Scryfall",
                               done: 0, total: 1))
        let client = ScryfallClient()
        let printingKeys = Array(Set(
            printable.filter { $0.hasPrinting }.map {
                PrintingKey(set: $0.setCode!,
                            collectorNumber: $0.collectorNumber!)
            })).sorted { ($0.set, $0.collectorNumber)
                        < ($1.set, $1.collectorNumber) }
        // Not strict: a printing Scryfall does not know (a typo,
        // or a number in another site's numbering) falls back to
        // the card's name below instead of stopping the build.
        let cards = try await client.lookupPrintings(printingKeys,
                                                     strict: false)

        var resolved: [(entry: DeckEntry, card: ScryfallCard)] = []
        var namedCache: [String: ScryfallCard] = [:]
        var buildWarnings = parsed.warnings

        // By name: in the line's set when it names one, then in
        // any set. A fallback the user should know about is noted
        // in the build's warnings, naming the printing used.
        func byName(_ entry: DeckEntry, why: String) async throws
            -> ScryfallCard {
            let cacheKey = "\(entry.name)|\(entry.setCode ?? "")"
            if let known = namedCache[cacheKey] { return known }
            var card: ScryfallCard
            var reason = why
            do {
                card = try await client.lookupNamed(
                    name: entry.name, set: entry.setCode)
            } catch {
                guard let set = entry.setCode else { throw error }
                card = try await client.lookupNamed(
                    name: entry.name, set: nil)
                reason = "\(entry.name): not found in set "
                    + set.uppercased()
            }
            if !reason.isEmpty {
                buildWarnings.append(
                    "\(reason); printed \(card.set.uppercased()) "
                        + "\(card.collectorNumber) instead.")
            }
            namedCache[cacheKey] = card
            return card
        }

        for entry in printable {
            try Task.checkCancellation()
            if entry.hasPrinting,
               let card = cards[PrintingKey(
                   set: entry.setCode!,
                   collectorNumber: entry.collectorNumber!)] {
                resolved.append((entry, card))
            } else if entry.hasPrinting {
                resolved.append((entry, try await byName(
                    entry,
                    why: "\(entry.name): Scryfall has no "
                        + "(\(entry.setCode!)) "
                        + "\(entry.collectorNumber!)")))
            } else {
                resolved.append((entry, try await byName(entry,
                                                         why: "")))
            }
        }

        // Flatten the deck into copies, each copy keeping its
        // own back (if any) beside its front, so a shuffle or a
        // back to back layout can never pair a front with the
        // wrong back. The classic layout also wants the backs
        // on their own, one per card that has one.
        var sources: [FaceRef: FaceSource] = [:]
        var copies: [(name: String, front: FaceRef,
                      back: FaceRef?)] = []
        var backs: [(name: String, face: FaceRef)] = []
        for (entry, card) in resolved {
            let urls = try ScryfallClient.facePNGURLs(for: card)
            let front = FaceRef(set: card.set,
                                collectorNumber: card.collectorNumber,
                                faceIndex: 0)
            sources[front] = FaceSource(url: urls[0], set: card.set,
                                        collector: card.collectorNumber)
            var backRef: FaceRef? = nil
            if urls.count > 1 {
                let back = FaceRef(set: card.set,
                                   collectorNumber: card.collectorNumber,
                                   faceIndex: 1)
                sources[back] = FaceSource(url: urls[1], set: card.set,
                                           collector: card.collectorNumber)
                backs.append((card.name, back))
                backRef = back
            }
            copies += Array(
                repeating: (name: card.name, front: front,
                            back: backRef),
                count: entry.quantity)
        }

        if shuffleDeck {
            // Shuffle the copies like a real deck: the
            // commander (and a legendary partner beside it)
            // stays at the front, and everything after is
            // shuffled with the system random source, so no
            // two builds come out alike. Each copy is its
            // own item in the list, so a card the deck runs
            // four of still turns up four times.
            var pinCount = 0
            for (index, pair) in resolved.prefix(2)
                .enumerated() {
                if index == 0
                    || (pair.card.typeLine ?? "")
                        .contains("Legendary") {
                    pinCount += pair.entry.quantity
                } else {
                    break
                }
            }
            let pinned = Array(copies.prefix(pinCount))
            let rest = Array(copies.dropFirst(pinCount))
                .shuffled()
            copies = pinned + rest
        }

        let fronts = copies.map { $0.front }

        // The plan, and the backs this build prints: in the
        // classic layout, one back per two sided card; back to
        // back, one behind every two sided copy.
        let plan: LayoutPlan
        var printBacks = backs
        if backToBack {
            let singles = copies.filter { $0.back == nil }
                .map { $0.front }
            let twoSided = copies.filter { $0.back != nil }
                .map { (name: $0.name, front: $0.front,
                        back: $0.back!) }
            plan = LayoutPlan.makeBackToBack(
                singles: singles, twoSided: twoSided,
                perPage: paper.gridColumns * paper.gridRows,
                columns: paper.gridColumns)
            printBacks = twoSided.map { (name: $0.name,
                                         face: $0.back) }
        } else {
            plan = LayoutPlan.makePlan(
                fronts: fronts, backs: backs,
                perPage: paper.gridColumns * paper.gridRows)
        }

        let pipeline = ImagePipeline(cacheDirectory: cacheDirectory,
                                     calibration: calibration,
                                     vibrance: vibrance,
                                     midtoneLift: midtoneLift)

        // Preparation pass over the unique faces; this warms the disk
        // cache. Prepared images are dropped immediately.
        var uniqueFaces: [FaceRef] = []
        var seen = Set<FaceRef>()
        for ref in fronts + printBacks.map({ $0.face })
        where !seen.contains(ref) {
            seen.insert(ref)
            uniqueFaces.append(ref)
        }
        for (index, ref) in uniqueFaces.enumerated() {
            try Task.checkCancellation()
            // Report before the face as well as after it, so
            // the bar shows which face is in flight instead
            // of sitting still until one completes.
            progress(PrintProgress(stage: "Preparing images",
                                   done: index,
                                   total: uniqueFaces.count))
            let src = sources[ref]!
            _ = try await pipeline.prepareFace(
                url: src.url, set: src.set, collector: src.collector,
                faceIndex: ref.faceIndex, scale: scale)
            progress(PrintProgress(stage: "Preparing images",
                                   done: index + 1,
                                   total: uniqueFaces.count))
        }

        var settings = PrintSettings()
        settings.gapMM = 3.0 + extraGapMM
        settings.bufferMM = 1.0
        settings.showGuides = guides
        settings.shiftUpMM = shiftUpMM
        settings.safeArea = safeArea
        settings.printerMargins = printerMargins
        settings.maximizeGap = maximizeGap
        settings.thickGuides = thickGuides
        settings.paper = paper
        settings.proxyMark = mark
        settings.calibration = calibration

        // PNG is a test print format in this app: capped
        // at a dozen cards and two two sided cards, because
        // a full deck at full scale takes the better part
        // of an hour of lossless encoding on a laptop.
        // PDF prints the same pixels in a fraction of the
        // time, so full decks belong there.
        if format == .png, !pngOverride,
           fronts.count > 12 || printBacks.count > 2 {
            throw ScryfallClientError.message(
                "[PPG:PNG-LIMIT] PNG is capped at small test "
                    + "prints: 12 cards and 2 two sided cards "
                    + "at most. This build has \(fronts.count) "
                    + "cards and \(printBacks.count) two sided. "
                    + "Use PDF for the full deck.")
        }

        // JPEG frames cap at 65,535 pixels a side. A tall
        // stitched build passes that quickly as the scale
        // climbs, so fail here with a plain answer instead
        // of after the stitch.
        if format == .jpeg {
            let pagePixels = Int(
                Double(settings.paper.size.height) / 72.0
                    * 300.0 * Double(scale))
            if pagePixels * plan.pageCount > 65_535 {
                throw ScryfallClientError.message(
                    "[PPG:JPEG-SIZE] JPEG cannot hold this build: the format "
                        + "caps an image at 65,535 pixels tall "
                        + "and \(plan.pageCount) pages at this "
                        + "scale run \(pagePixels * plan.pageCount). "
                        + "Use PNG or PDF here, or lower the "
                        + "scale.")
            }
        }

        let builder: any PageBuilding
        if format == .pdf {
            builder = PDFBuilder(outputURL: outputURL,
                                 settings: settings, title: "Proxies")
        } else {
            let imageBuilder = ImagePageBuilder(
                outputURL: outputURL, settings: settings,
                scale: scale,
                format: format == .png ? .png : .jpeg,
                jpegQuality: jpegQuality)
            imageBuilder.onStitchProgress = { done, total in
                progress(PrintProgress(
                    stage: format == .png ? "Stitching the PNG"
                                          : "Stitching the JPEG",
                    done: done, total: total))
            }
            imageBuilder.onVerifyProgress = { done, total in
                progress(PrintProgress(
                    stage: "Checking the stitched PNG",
                    done: done, total: total))
            }
            imageBuilder.shouldCancel = { Task.isCancelled }
            builder = imageBuilder
        }
        builder.onFaceDrawn = { placed, total in
            progress(PrintProgress(
                stage: format == .pdf ? "Assembling PDF"
                                      : "Assembling pages",
                done: placed, total: total))
        }
        try builder.begin(totalPlacements: plan.totalPlacements,
                          pageCount: plan.pageCount)

        // Assemble page by page, releasing each page's faces before
        // the next page starts.
        for (pageIndex, pageFronts) in plan.pages.enumerated() {
            try Task.checkCancellation()
            builder.beginPage()
            var pageFaces: [FaceRef: PreparedFace] = [:]
            func resolve(_ ref: FaceRef) async throws -> PreparedFace {
                if let face = pageFaces[ref] { return face }
                let src = sources[ref]!
                var face = try await pipeline.prepareFace(
                    url: src.url, set: src.set, collector: src.collector,
                    faceIndex: ref.faceIndex, scale: scale)
                // A border mark recolors the card's edge, so
                // the bleed around the card takes the mark's
                // color too, like the Windows build.
                if mark.kind == .border {
                    face = PreparedFace(image: face.image,
                                        borderColor: mark.color)
                }
                pageFaces[ref] = face
                return face
            }
            for (slot, ref) in pageFronts.enumerated() {
                builder.drawCard(slot: slot, face: try await resolve(ref))
            }
            if let pageBacks = plan.backPlacements[pageIndex] {
                for slot in pageBacks.keys.sorted() {
                    builder.drawCard(slot: slot,
                                     face: try await resolve(pageBacks[slot]!))
                }
            }
            builder.endPage()
        }

        progress(PrintProgress(
            stage: format == .pdf ? "Saving PDF"
                  : format == .png ? "Stitching the PNG"
                                   : "Stitching the JPEG",
            done: 0,
            total: format == .pdf ? 1 : max(plan.pageCount, 1)))
        builder.finish()
        if let imageBuilder = builder as? ImagePageBuilder,
           imageBuilder.wasCancelled {
            throw CancellationError()
        }
        if let failure = builder.failureMessage {
            throw PDFBuilderError.message(failure)
        }

        var sizeBytes = 0
        if let attrs = try? FileManager.default.attributesOfItem(
            atPath: outputURL.path), let size = attrs[.size] as? NSNumber {
            sizeBytes = size.intValue
        }
        return PrintJobResult(outputURL: outputURL,
                              frontCount: fronts.count,
                              backCount: printBacks.count,
                              backNames: plan.backNames,
                              pageCount: plan.pageCount,
                              sizeBytes: sizeBytes,
                              warnings: buildWarnings,
                              duplexStartPage: plan.duplexStartPage)
    }
}
