//
//  MacPrinting.swift
//  ProxyPrintGenerator
//
//  The Mac's printers as the print sheet sees them, read from CUPS
//  (the Mac's printing system), and jobs sent straight to CUPS the way
//  the lp command sends them, so the app's own choices (paper type,
//  quality, paper size, actual size, two sided) reach the driver
//  without Apple's print dialog in between. Nov 14, 2026.
//
//  It also reads what a printer's driver is, because on a Mac each
//  printer entry is tied to one driver when it is added, and macOS
//  picks AirPrint, its generic driver, by default. Installing the
//  maker's driver afterwards never changes printers already added,
//  so a Mac can have Canon's driver installed and still print through
//  AirPrint, with only "photographic" for paper instead of Canon's
//  Matte Photo Paper and friends. The sheet spots that and says how
//  to re-add the printer with the maker's driver.
//
//  Nothing here installs anything or changes a printer: it only
//  reads, and opens web pages or System Settings when asked.
//

#if os(macOS)
import Foundation
import AppKit

/// One choice list from a printer's driver (its PPD file): media
/// type, quality, paper size, two sided.
nonisolated struct DriverOption: Sendable {
    let keyword: String
    let label: String
    let choices: [Choice]
    let defaultValue: String?

    struct Choice: Hashable, Sendable {
        let value: String
        let label: String
        /// For PageSize: the sheet in points, from the driver.
        var size: CGSize? = nil
    }
}

nonisolated enum DriverKind: Equatable, Sendable {
    /// Apple's generic driver (AirPrint or IPP Everywhere).
    case airPrint
    /// The maker's own driver.
    case maker
    /// A generic CUPS driver (Generic PostScript, PCL, raw).
    case generic
    case unknown
}

/// A printer as CUPS knows it.
nonisolated struct MacPrinter: Identifiable, Hashable, Sendable {
    /// The CUPS queue name (Canon_MB5400_series_2).
    let id: String
    /// What System Settings calls it (Canon MB5400 series).
    let displayName: String
    let model: String
    let maker: String
    let isDefault: Bool
    let isFax: Bool
    let accepting: Bool
    /// printer-state: 3 idle, 4 printing, 5 stopped.
    let state: Int
    let stateReasons: [String]
    let driver: DriverKind
    let driverName: String
    /// The maker's driver for this model, when it is installed on
    /// this Mac but this printer entry doesn't use it.
    let unusedMakerDriver: String?
    let mediaType: DriverOption?
    let quality: DriverOption?
    let pageSize: DriverOption?
    let duplex: DriverOption?

    static func == (a: MacPrinter, b: MacPrinter) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isStopped: Bool { state == 5 || !accepting }
    var looksOffline: Bool {
        stateReasons.contains { $0.hasPrefix("offline") }
    }

    /// The driver's name for a sheet of this size, preferring the
    /// plain name over borderless variants.
    func pageSizeName(for size: CGSize) -> String? {
        guard let choices = pageSize?.choices else { return nil }
        let matches = choices.filter { c in
            guard let s = c.size else { return false }
            return abs(s.width - size.width) < 2
                && abs(s.height - size.height) < 2
        }
        return matches.first { !$0.value.contains(".") }?.value
            ?? matches.first?.value
    }
}

nonisolated enum MacPrinting {

    // MARK: - Printers

    /// Every printer queue CUPS has, fax queues included (callers
    /// leave those out of pickers).
    static func printers() -> [MacPrinter] {
        var dests: UnsafeMutablePointer<cups_dest_t>?
        let count = cupsGetDests2(nil, &dests)
        defer { cupsFreeDests(count, dests) }
        guard let dests, count > 0 else { return [] }
        let makerDrivers = installedMakerDrivers()
        var out: [MacPrinter] = []
        for i in 0..<Int(count) {
            let dest = dests[i]
            guard dest.instance == nil, let cName = dest.name else { continue }
            let name = String(cString: cName)
            var opts: [String: String] = [:]
            for j in 0..<Int(dest.num_options) {
                let o = dest.options[j]
                if let n = o.name, let v = o.value {
                    opts[String(cString: n)] = String(cString: v)
                }
            }
            let ppd = readPPD(queue: name)
            let type = Int(opts["printer-type"] ?? "") ?? 0
            let model = ppd?.modelName
                ?? opts["printer-make-and-model"] ?? name
            let maker = ppd?.manufacturer
                ?? model.components(separatedBy: " ").first ?? ""
            let kind = ppd.map(driverKind) ?? .unknown
            var unused: String? = nil
            if kind != .maker,
               let match = makerDrivers.first(where: {
                   $0.model.caseInsensitiveCompare(model) == .orderedSame
               }) {
                unused = match.model
            }
            out.append(MacPrinter(
                id: name,
                displayName: opts["printer-info"] ?? name,
                model: model,
                maker: maker,
                isDefault: dest.is_default != 0,
                isFax: type & 0x40000 != 0,
                accepting: opts["printer-is-accepting-jobs"] != "false",
                state: Int(opts["printer-state"] ?? "") ?? 3,
                stateReasons: (opts["printer-state-reasons"] ?? "")
                    .split(separator: ",").map(String.init)
                    .filter { $0 != "none" },
                driver: kind,
                driverName: ppd?.nickName ?? "no driver file",
                unusedMakerDriver: unused,
                mediaType: ppd?.option(matching: ["CNIJMediaType", "MediaType", "EPIJ_Medi", "HPMediaType", "BRMediaType"],
                                       labelHint: ["media type", "paper type"]),
                quality: ppd?.option(matching: ["CNIJPrintQuality", "cupsPrintQuality", "EPIJ_Qual", "HPPrintQuality", "BRResolution", "OutputMode"],
                                     labelHint: ["quality"]),
                pageSize: ppd?.options["PageSize"],
                duplex: ppd?.options["Duplex"]))
        }
        return out
    }

    private static func driverKind(_ ppd: PPDFile) -> DriverKind {
        let nick = ppd.nickName.lowercased()
        if ppd.isAirPrint || nick.contains("airprint")
            || nick.contains("ipp everywhere") {
            return .airPrint
        }
        if nick.contains("generic") || nick.contains("raw") {
            return .generic
        }
        return .maker
    }

    /// The maker drivers installed on this Mac, from CUPS's own list
    /// (lpinfo -m), leaving out CUPS's generic sample drivers.
    private static func installedMakerDrivers() -> [(path: String, model: String)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lpinfo")
        p.arguments = ["-m"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").map(String.init).compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let path = String(line[..<space])
            let model = String(line[line.index(after: space)...])
            if path.hasPrefix("drv:///") || path == "raw"
                || path == "everywhere" { return nil }
            return (path, model)
        }
    }

    // MARK: - The driver file (PPD)

    struct PPDFile {
        var nickName = ""
        var modelName: String?
        var manufacturer: String?
        var isAirPrint = false
        var options: [String: DriverOption] = [:]

        func option(matching keywords: [String],
                    labelHint: [String]) -> DriverOption? {
            for k in keywords {
                if let o = options[k] { return o }
                if let o = options.first(where: { $0.key.hasPrefix(k) })?.value {
                    return o
                }
            }
            return options.values.first { o in
                labelHint.contains { o.label.lowercased().contains($0) }
            }
        }
    }

    /// The queue's driver file: CUPS keeps a readable copy of it in
    /// /etc/cups/ppd. A queue with none there has no driver at all
    /// (a leftover entry), so nil.
    static func readPPD(queue: String) -> PPDFile? {
        let path = "/etc/cups/ppd/\(queue).ppd"
        guard let data = FileManager.default.contents(atPath: path)
        else { return nil }
        return parsePPD(String(decoding: data, as: UTF8.self))
    }

    static func parsePPD(_ text: String) -> PPDFile {
        var ppd = PPDFile()
        var current: (keyword: String, label: String)?
        var choices: [DriverOption.Choice] = []
        var defaults: [String: String] = [:]
        var built: [String: (String, [DriverOption.Choice])] = [:]

        func quoted(_ s: Substring) -> String {
            s.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard line.hasPrefix("*"), !line.hasPrefix("*%") else { continue }
            if line.hasPrefix("*OpenUI ") {
                // *OpenUI *CNIJMediaType/Media Type: PickOne
                let body = line.dropFirst("*OpenUI *".count)
                let head = body.split(separator: ":", maxSplits: 1).first ?? ""
                let parts = head.split(separator: "/", maxSplits: 1)
                let keyword = String(parts.first ?? "")
                current = (keyword, parts.count > 1 ? String(parts[1]) : keyword)
                choices = []
                continue
            }
            if line.hasPrefix("*CloseUI") {
                if let c = current { built[c.keyword] = (c.label, choices) }
                current = nil
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.index(after: line.startIndex)..<colon]
            let value = line[line.index(after: colon)...]
            switch key {
            case "NickName": ppd.nickName = quoted(value)
            case "ModelName": ppd.modelName = quoted(value)
            case "Manufacturer": ppd.manufacturer = quoted(value)
            case "APAirPrint": ppd.isAirPrint = quoted(value).lowercased() == "true"
            default:
                if key.hasPrefix("Default") {
                    defaults[String(key.dropFirst("Default".count))] = quoted(value)
                } else if let c = current, key.hasPrefix(c.keyword + " ") {
                    // *CNIJMediaType 28/Matte Photo Paper: ""
                    let spec = key.dropFirst(c.keyword.count + 1)
                    let parts = spec.split(separator: "/", maxSplits: 1)
                    let v = String(parts.first ?? "")
                    var choice = DriverOption.Choice(
                        value: v,
                        label: parts.count > 1 ? String(parts[1]) : v)
                    if c.keyword == "PageSize",
                       let m = value.range(of: #"PageSize\s*\[\s*([\d.]+)\s+([\d.]+)"#,
                                           options: .regularExpression) {
                        let nums = value[m].split(whereSeparator: { !"0123456789.".contains($0) })
                            .compactMap { Double($0) }
                        if nums.count >= 2 {
                            choice.size = CGSize(width: nums[0], height: nums[1])
                        }
                    }
                    choices.append(choice)
                }
            }
        }
        for (keyword, (label, list)) in built where !list.isEmpty {
            ppd.options[keyword] = DriverOption(
                keyword: keyword, label: label, choices: list,
                defaultValue: defaults[keyword])
        }
        return ppd
    }

    // MARK: - Paper presets

    /// A one-click paper choice: a media type and the best quality
    /// for it, from whatever this printer's driver lists.
    struct PaperPreset: Identifiable, Hashable {
        let label: String
        let hint: String
        let media: String?
        let quality: String?
        var id: String { label }
    }

    /// The Windows app's presets, matched to this driver's lists:
    /// Plain, Matte photo, Photo Paper Plus Glossy II, Glossy. With
    /// AirPrint the photo papers all come out as "photographic", so
    /// the sheet shows just Plain and Photo.
    static func presets(for printer: MacPrinter) -> [PaperPreset] {
        let media = printer.mediaType?.choices ?? []
        func find(_ test: (String) -> Bool) -> String? {
            media.first { test($0.label.lowercased()) }?.value
                ?? media.first { test($0.value.lowercased()) }?.value
        }
        let best = bestQuality(printer.quality)
        let normal = printer.quality?.choices.first {
            $0.label.lowercased() == "normal"
                || $0.value.lowercased() == "normal"
        }?.value ?? printer.quality?.defaultValue
        var list: [PaperPreset] = []
        func add(_ label: String, _ hint: String, _ m: String?, _ q: String?) {
            guard let m, !list.contains(where: { $0.media == m }) else { return }
            list.append(PaperPreset(label: label, hint: hint, media: m, quality: q))
        }
        add("Plain paper", "Everyday paper, normal quality",
            find { $0.contains("plain") || $0 == "stationery" }, normal)
        add("Matte photo", "Matte photo paper, best quality: the richest proxies",
            find { $0.contains("matte") }, best)
        add("Photo Paper Plus Glossy II", "Canon's glossy photo paper, best quality",
            find { $0.contains("plus glossy ii") }, best)
        add("Glossy photo", "Glossy photo paper, best quality",
            find { $0.contains("glossy") && !$0.contains("plus") }, best)
        add("Photo paper", "Any photo paper, best quality",
            find { $0.hasPrefix("photographic") || $0.contains("photo") }, best)
        return list
    }

    /// The driver's best quality: Super Fine, Best, High, or Fine.
    static func bestQuality(_ option: DriverOption?) -> String? {
        guard let choices = option?.choices else { return nil }
        for word in ["super fine", "highest", "best", "high", "fine"] {
            if let c = choices.first(where: {
                $0.label.lowercased().hasPrefix(word)
                    || $0.value.lowercased().hasPrefix(word)
            }) { return c.value }
        }
        return nil
    }

    // MARK: - Advice about the printer

    /// Something the person should know about a printer before
    /// printing, with what to do about it.
    struct Advice: Identifiable {
        enum Action { case openPrinterSettings, openURL(URL) }
        let id: String
        let text: String
        let isProblem: Bool
        let actionLabel: String?
        let action: Action?
    }

    static func advice(for p: MacPrinter) -> [Advice] {
        var out: [Advice] = []
        if p.isStopped {
            out.append(Advice(
                id: "stopped",
                text: "\(p.displayName) is stopped, so a job sent to it waits instead of printing. Open Printers & Scanners, then remove this printer and add it again, or pick another printer.",
                isProblem: true, actionLabel: "Open Printers & Scanners",
                action: .openPrinterSettings))
        } else if p.looksOffline {
            out.append(Advice(
                id: "offline",
                text: "\(p.displayName) looks offline or asleep. Make sure it's on and connected; the job waits until it is.",
                isProblem: false, actionLabel: nil, action: nil))
        }
        switch (p.driver, p.unusedMakerDriver) {
        case (.maker, _):
            break
        case (_, let installed?):
            out.append(Advice(
                id: "readd",
                text: "\(installed)'s own driver is installed on this Mac, but this printer was added with Apple's generic AirPrint driver, so it only offers basic paper types. Reinstalling the driver won't change that. In Printers & Scanners, remove the printer, click Add Printer, select it, and under Use pick \"\(installed)\" instead of AirPrint. Then choose the new printer here.",
                isProblem: false, actionLabel: "Open Printers & Scanners",
                action: .openPrinterSettings))
        case (.airPrint, nil):
            if let url = makerDriverPage(p.maker) {
                out.append(Advice(
                    id: "getdriver",
                    text: "\(p.displayName) uses Apple's generic AirPrint driver. It prints fine, but \(p.maker)'s own driver adds the exact paper types (like matte photo paper) and finer quality. Download it from \(p.maker), install it, then re-add the printer and pick \(p.maker)'s driver under Use.",
                    isProblem: false,
                    actionLabel: "Find \(p.maker)'s driver",
                    action: .openURL(url)))
            }
        default:
            break
        }
        return out
    }

    /// The maker's driver download page, opened in the web browser.
    static func makerDriverPage(_ maker: String) -> URL? {
        let m = maker.lowercased()
        let page: String
        if m.contains("canon") { page = "https://www.usa.canon.com/support/software-and-drivers" }
        else if m.contains("epson") { page = "https://epson.com/Support/sl/s" }
        else if m.contains("brother") { page = "https://support.brother.com/g/b/productsearch.aspx" }
        else if m.hasPrefix("hp") { page = "https://support.hp.com/drivers" }
        else { return nil }
        return URL(string: page)
    }

    static func openPrinterSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Print-Scanner-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Send a job

    /// The CUPS options for a job: copies, pages, the driver's paper
    /// size for the build's sheet, the chosen paper type and quality
    /// under the driver's own keywords, two sided or not, and always
    /// actual size (the pages already are the printed sheet).
    static func jobOptions(printer p: MacPrinter, pageSize: CGSize,
                           copies: Int, pages: ClosedRange<Int>?,
                           media: String?, quality: String?,
                           duplex: Bool) -> [String: String] {
        var o: [String: String] = [
            "copies": "\(copies)",
            "print-scaling": "none",
            "fit-to-page": "false",
            "sides": duplex ? "two-sided-long-edge" : "one-sided",
        ]
        if let pages { o["page-ranges"] = "\(pages.lowerBound)-\(pages.upperBound)" }
        if let size = p.pageSizeName(for: pageSize) { o["PageSize"] = size }
        if let k = p.mediaType?.keyword, let media { o[k] = media }
        if let k = p.quality?.keyword, let quality { o[k] = quality }
        if p.duplex != nil { o["Duplex"] = duplex ? "DuplexNoTumble" : "None" }
        #if DEBUG
        // Testing without paper: the job waits on hold until
        // cancelled.
        if ProcessInfo.processInfo.environment["PPG_PRINT_HOLD"] != nil {
            o["job-hold-until"] = "indefinite"
        }
        #endif
        return o
    }

    #if DEBUG
    /// Debug builds only, PPG_PRINT_SELFTEST_LOG set: writes what the
    /// sheet would see for every printer, and with PPG_PRINT_HOLD and
    /// PPG_PRINT_SELFTEST_PDF also sends that PDF to the first healthy
    /// printer on hold, with the best photo preset.
    static func selfTest() {
        let env = ProcessInfo.processInfo.environment
        guard let log = env["PPG_PRINT_SELFTEST_LOG"] else { return }
        var out: [String] = []
        let all = printers()
        for p in all {
            out.append("printer \(p.id) name=\(p.displayName) fax=\(p.isFax) stopped=\(p.isStopped) default=\(p.isDefault) driver=\(p.driver) (\(p.driverName)) unusedMakerDriver=\(p.unusedMakerDriver ?? "-")")
            out.append("  media \(p.mediaType?.keyword ?? "-"): \(p.mediaType?.choices.map(\.label) ?? [])")
            out.append("  quality \(p.quality?.keyword ?? "-"): \(p.quality?.choices.map(\.label) ?? []) best=\(bestQuality(p.quality) ?? "-")")
            out.append("  letter=\(p.pageSizeName(for: CGSize(width: 612, height: 792)) ?? "-") a4=\(p.pageSizeName(for: CGSize(width: 595.28, height: 841.89)) ?? "-")")
            out.append("  presets \(presets(for: p).map { "\($0.label)=\($0.media ?? "-")/\($0.quality ?? "-")" })")
            out.append("  advice \(advice(for: p).map(\.id))")
        }
        if let path = env["PPG_PRINT_SELFTEST_PPD"],
           let data = FileManager.default.contents(atPath: path) {
            let ppd = parsePPD(String(decoding: data, as: UTF8.self))
            let p = MacPrinter(
                id: "test", displayName: "test", model: ppd.modelName ?? "",
                maker: ppd.manufacturer ?? "", isDefault: false, isFax: false,
                accepting: true, state: 3, stateReasons: [],
                driver: driverKind(ppd), driverName: ppd.nickName,
                unusedMakerDriver: nil,
                mediaType: ppd.option(matching: ["CNIJMediaType", "MediaType"], labelHint: ["media type"]),
                quality: ppd.option(matching: ["CNIJPrintQuality", "cupsPrintQuality"], labelHint: ["quality"]),
                pageSize: ppd.options["PageSize"], duplex: ppd.options["Duplex"])
            out.append("ppd \(ppd.nickName) driver=\(p.driver) media=\(p.mediaType?.keyword ?? "-") quality=\(p.quality?.keyword ?? "-") best=\(bestQuality(p.quality) ?? "-") letter=\(p.pageSizeName(for: CGSize(width: 612, height: 792)) ?? "-")")
            out.append("  presets \(presets(for: p).map { "\($0.label)=\($0.media ?? "-")/\($0.quality ?? "-")" })")
            out.append("  options \(jobOptions(printer: p, pageSize: CGSize(width: 612, height: 792), copies: 1, pages: nil, media: presets(for: p).dropFirst().first?.media, quality: presets(for: p).dropFirst().first?.quality, duplex: true).sorted { $0.key < $1.key })")
        }
        if env["PPG_PRINT_HOLD"] != nil, let pdf = env["PPG_PRINT_SELFTEST_PDF"],
           let p = all.first(where: { !$0.isFax && !$0.isStopped }) {
            let preset = presets(for: p).last
            let opts = jobOptions(printer: p, pageSize: CGSize(width: 612, height: 792),
                                  copies: 2, pages: 1...1, media: preset?.media,
                                  quality: preset?.quality, duplex: false)
            out.append("submit to \(p.id) options \(opts.sorted { $0.key < $1.key })")
            do {
                let job = try submit(file: URL(fileURLWithPath: pdf), to: p.id,
                                     title: "PPG self-test", options: opts)
                out.append("job \(job)")
            } catch {
                out.append("error \(error.localizedDescription)")
            }
        }
        try? (out.joined(separator: "\n") + "\n").write(toFile: log, atomically: true, encoding: .utf8)
    }
    #endif

    struct PrintError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Sends a PDF straight to a CUPS queue with these options
    /// (copies, PageSize, media type, quality, Duplex, ...), the way
    /// lp does. Returns the job number.
    static func submit(file: URL, to queue: String, title: String,
                       options: [String: String]) throws -> Int32 {
        var opts: UnsafeMutablePointer<cups_option_t>? = nil
        var count: Int32 = 0
        for (k, v) in options {
            count = cupsAddOption(k, v, count, &opts)
        }
        defer { cupsFreeOptions(count, opts) }
        let job = cupsPrintFile2(nil, queue, file.path, title, count, opts)
        if job == 0 {
            let reason = cupsLastErrorString().map { String(cString: $0) }
                ?? "unknown error"
            throw PrintError(message: "The printer didn't take the job: \(reason)")
        }
        return job
    }
}

/// What the sheet remembers between prints: the printer and the
/// paper choices last used. Saved beside decks.json.
nonisolated struct MacPrintMemory: Codable {
    var printer: String?
    var preset: String?
    var media: String?
    var quality: String?

    private static var url: URL { AppData.folder.appendingPathComponent("print.json") }

    static func load() -> MacPrintMemory {
        guard let d = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(MacPrintMemory.self, from: d)
        else { return MacPrintMemory() }
        return m
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: AppData.folder, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(self) {
            try? d.write(to: Self.url, options: .atomic)
        }
    }
}
#endif
