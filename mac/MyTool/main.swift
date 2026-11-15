//
//  main.swift
//  Version 4
//  Proxy Printer (native port) — Phase 1 command line harness
//
//  Mirrors the Python script's CLI:
//    proxy-printer DECK.txt [-o OUT.pdf] [--paper letter|a4]
//                  [--gap 3] [--buffer 1] [--scale 4]
//                  [--cyan 1.35] [--magenta 1.30] [--yellow 1.30]
//                  [--no-guides]
//
//  Deck lists are one card per line:  qty Name (set) collectorNumber
//  (see DeckList.swift for the forgiving variants). Images are cached
//  under ./cache so reruns are fast.
//
//  Launched with no deck argument (for example, Xcode's Run button),
//  the tool asks for the deck list path on the console instead of
//  failing; flags such as --scale can still be passed on their own.
//

import Foundation

struct CLIConfig {
    var deckPath: String = ""
    var outputPath: String? = nil
    var paper: PaperSize = .letter
    var paperName: String = "letter"
    var gap: Double = 3.0
    var buffer: Double = 1.0
    var scale: Int = 4
    var cyan: Double = 1.0
    var magenta: Double = 1.0
    var yellow: Double = 1.0
    var guides: Bool = true
}

let usageText = """
    usage: proxy-printer DECK.txt [-o OUT.pdf] [--paper letter|a4]
                      [--gap 3] [--buffer 1] [--scale 4]
                      [--cyan F] [--magenta F] [--yellow F] [--no-guides]
    """

func failUsage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n\(usageText)\n".utf8))
    exit(2)
}

func parseArgs() -> CLIConfig {
    var config = CLIConfig()
    let args = Array(CommandLine.arguments.dropFirst())
    var positionals: [String] = []
    var i = 0
    func value(for flag: String) -> String {
        if let eq = flag.firstIndex(of: "=") {
            return String(flag[flag.index(after: eq)...])
        }
        i += 1
        guard i < args.count else { failUsage("Missing value for \(flag)") }
        return args[i]
    }
    while i < args.count {
        let arg = args[i]
        let flag = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
        switch flag {
        case "-o", "--output":
            config.outputPath = value(for: arg)
        case "--paper":
            let v = value(for: arg)
            switch v {
            case "letter": config.paper = .letter
            case "a4": config.paper = .a4
            case "legal": config.paper = .legal
            case "tabloid": config.paper = .tabloid
            case "a3": config.paper = .a3
            default: failUsage("Unknown paper: \(v)")
            }
            config.paperName = v
        case "--gap":
            config.gap = Double(value(for: arg)) ?? 3.0
        case "--buffer":
            config.buffer = Double(value(for: arg)) ?? 1.0
        case "--scale":
            config.scale = Int(value(for: arg)) ?? 4
        case "--cyan":
            config.cyan = Double(value(for: arg)) ?? 1.0
        case "--magenta":
            config.magenta = Double(value(for: arg)) ?? 1.0
        case "--yellow":
            config.yellow = Double(value(for: arg)) ?? 1.0
        case "--no-guides":
            config.guides = false
        case "-h", "--help":
            print(usageText)
            exit(0)
        default:
            if arg.hasPrefix("-") { failUsage("Unknown option: \(arg)") }
            positionals.append(arg)
        }
        i += 1
    }
    if let deck = positionals.first {
        config.deckPath = deck
    } else {
        config.deckPath = promptForDeckPath()
    }
    guard config.scale >= 1 else { failUsage("--scale must be at least 1") }
    return config
}

/// When the tool is launched with no deck argument (the usual case from
/// Xcode's Run button), ask for the deck list path on the console instead
/// of failing. Accepts a pasted path, a quoted path, or a path dragged
/// into a Terminal window (which arrives with escaped spaces).
func promptForDeckPath() -> String {
    print("No deck list given.")
    while true {
        print("Paste the deck list path, or drag its file into this "
              + "window, then press Return:")
        guard let line = readLine() else {
            failUsage("A deck list file is required.")
        }
        var path = line.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count > 1 {
            path = String(path.dropFirst().dropLast())
        }
        path = path.replacingOccurrences(of: "\\ ", with: " ")
        if path == "~" || path.hasPrefix("~/") {
            path = (path as NSString).expandingTildeInPath
        }
        if FileManager.default.fileExists(atPath: path) {
            return path
        }
        print("That file does not exist: \(path)")
        print("Try again, or press Control-C to stop.")
    }
}

/// The Python script's in place progress bar, same shape.
func progressBar(_ label: String, _ done: Int, _ total: Int, _ start: Date) {
    let frac = total > 0 ? Double(done) / Double(total) : 1.0
    let width = 30
    let filled = Int(Double(width) * frac)
    let bar = String(repeating: "#", count: filled)
        + String(repeating: "-", count: width - filled)
    var eta = ""
    if done > 0 {
        let left = Date().timeIntervalSince(start) / Double(done)
            * Double(total - done)
        eta = " | ~\(Int(left + 0.5))s left"
    }
    print("\r\(label): [\(bar)] \(done)/\(total) "
          + "(\(String(format: "%.0f", frac * 100))%)\(eta)",
          terminator: "")
    fflush(stdout)
    if done >= total { print("") }
}

struct FaceSource {
    var url: URL
    var set: String
    var collector: String
}

func run(_ config: CLIConfig) async throws {
    let calibration = InkCalibration(cyan: config.cyan,
                                     magenta: config.magenta,
                                     yellow: config.yellow)
    let deckURL = URL(fileURLWithPath: config.deckPath)
    let parsed = try DeckList.parseFile(at: deckURL)
    for warning in parsed.warnings { print(warning) }

    let printable = parsed.entries.filter { $0.board == .main }
    let skipped = parsed.entries.count - printable.count
    if skipped > 0 {
        print("note: \(skipped) sideboard/maybeboard entries not printed")
    }
    guard !printable.isEmpty else {
        throw ScryfallClientError.message("No printable cards in deck list.")
    }

    // Resolve every entry to a concrete Scryfall card.
    let client = ScryfallClient()
    var cards: [PrintingKey: ScryfallCard] = [:]
    let printingKeys = Array(Set(
        printable.filter { $0.hasPrinting }.map {
            PrintingKey(set: $0.setCode!, collectorNumber: $0.collectorNumber!)
        })).sorted { ($0.set, $0.collectorNumber) < ($1.set, $1.collectorNumber) }
    print("Looking up \(printingKeys.count) cards on Scryfall...")
    // Not strict: an unknown printing falls back to the card's
    // name below instead of stopping the build.
    cards = try await client.lookupPrintings(printingKeys,
                                             strict: false)

    var resolved: [(entry: DeckEntry, card: ScryfallCard)] = []
    var namedCache: [String: ScryfallCard] = [:]

    // By name: in the line's set when it names one, then in any
    // set. Fallbacks are printed so the user can see which
    // printing stood in for the one the list asked for.
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
            print("\(reason); printed \(card.set.uppercased()) "
                + "\(card.collectorNumber) instead.")
        }
        namedCache[cacheKey] = card
        return card
    }

    for entry in printable {
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

    // Flatten the deck into face references (fronts in deck order, backs
    // collected in order), exactly like the Python main loop.
    var sources: [FaceRef: FaceSource] = [:]
    var fronts: [FaceRef] = []
    var backs: [(name: String, face: FaceRef)] = []
    for (entry, card) in resolved {
        let urls = try ScryfallClient.facePNGURLs(for: card)
        let front = FaceRef(set: card.set,
                            collectorNumber: card.collectorNumber,
                            faceIndex: 0)
        sources[front] = FaceSource(url: urls[0], set: card.set,
                                    collector: card.collectorNumber)
        fronts += Array(repeating: front, count: entry.quantity)
        if urls.count > 1 {
            let back = FaceRef(set: card.set,
                               collectorNumber: card.collectorNumber,
                               faceIndex: 1)
            sources[back] = FaceSource(url: urls[1], set: card.set,
                                       collector: card.collectorNumber)
            backs.append((card.name, back))
        }
    }

    let cacheDirectory = URL(fileURLWithPath:
        FileManager.default.currentDirectoryPath)
        .appendingPathComponent("cache")
    let pipeline = ImagePipeline(cacheDirectory: cacheDirectory,
                                 calibration: calibration)

    // Preparation pass over the unique faces, as the Python script does;
    // this warms the disk cache. Prepared images are dropped immediately,
    // so memory stays flat.
    var uniqueFaces: [FaceRef] = []
    var seen = Set<FaceRef>()
    for ref in fronts + backs.map({ $0.face }) where !seen.contains(ref) {
        seen.insert(ref)
        uniqueFaces.append(ref)
    }
    let t0 = Date()
    for (index, ref) in uniqueFaces.enumerated() {
        let src = sources[ref]!
        _ = try await pipeline.prepareFace(
            url: src.url, set: src.set, collector: src.collector,
            faceIndex: ref.faceIndex, scale: config.scale)
        progressBar("Preparing images (download + upscale)",
                    index + 1, uniqueFaces.count, t0)
    }

    let plan = LayoutPlan.makePlan(fronts: fronts, backs: backs)

    let outputPath = config.outputPath
        ?? deckURL.deletingPathExtension().appendingPathExtension("pdf").path
    var settings = PrintSettings()
    settings.paper = config.paper
    settings.gapMM = config.gap
    settings.bufferMM = config.buffer
    settings.showGuides = config.guides
    settings.calibration = calibration

    let deckStem = deckURL.deletingPathExtension().lastPathComponent
    let builder = PDFBuilder(
        outputURL: URL(fileURLWithPath: outputPath),
        settings: settings, title: "Proxies - \(deckStem)")
    let t1 = Date()
    builder.onFaceDrawn = { placed, total in
        progressBar("Assembling PDF", placed, total, t1)
    }
    try builder.begin(totalPlacements: plan.totalPlacements,
                      pageCount: plan.pageCount)

    // Assemble page by page. Each page keeps only its own faces alive;
    // the working set is released before the next page starts.
    for (pageIndex, pageFronts) in plan.pages.enumerated() {
        builder.beginPage()
        var pageFaces: [FaceRef: PreparedFace] = [:]
        func resolve(_ ref: FaceRef) async throws -> PreparedFace {
            if let face = pageFaces[ref] { return face }
            let src = sources[ref]!
            let face = try await pipeline.prepareFace(
                url: src.url, set: src.set, collector: src.collector,
                faceIndex: ref.faceIndex, scale: config.scale)
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

    print("Saving PDF (lossless builds can take a minute here)...")
    builder.finish()

    var sizeBytes: Double = 0
    if let attrs = try? FileManager.default.attributesOfItem(
        atPath: outputPath), let size = attrs[.size] as? NSNumber {
        sizeBytes = size.doubleValue
    }
    print("deck cards (fronts): \(fronts.count)")
    let backList = backs.isEmpty
        ? "none"
        : plan.backNames.joined(separator: ", ")
    print("two-sided backs placed: \(backs.count) (\(backList))")
    print("pages: \(plan.pageCount) | paper: \(config.paperName) | "
          + "gap: \(config.gap)mm | buffer: \(config.buffer)mm | "
          + "scale: \(config.scale)x (~\(300 * config.scale) DPI) | "
          + "cyan boost: \(config.cyan)x | magenta boost: \(config.magenta)x | "
          + "yellow boost: \(config.yellow)x | "
          + "guides: rounded, \(config.guides)")
    print("wrote: \(outputPath) "
          + "(\(String(format: "%.1f", sizeBytes / 1_000_000)) MB)")
}

// MARK: - Entry point

let config = parseArgs()
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        try await run(config)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
        exit(1)
    }
    semaphore.signal()
}
semaphore.wait()
