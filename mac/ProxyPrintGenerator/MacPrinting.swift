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
    /// That driver's file, as CUPS lists it
    /// (Library/Printers/PPDs/Contents/Resources/....ppd.gz).
    var unusedMakerDriverPPD: String? = nil
    /// Another printer entry for this same model that already uses
    /// the maker's driver, by display name.
    var makerDriverTwin: String? = nil
    /// Every option the driver has, with its default choice, so a job
    /// can set each one itself instead of leaving any to a default
    /// saved on this Mac, in the driver, or on the printer.
    var driverDefaults: [String: String] = [:]
    /// The driver's paper source list (Canon: Cassette (Auto Select),
    /// Cassette 1, Cassette 2).
    var paperSource: DriverOption? = nil
    /// What each cassette is registered as holding, by cassette number:
    /// the paper type value, as the printer reports it (Canon's
    /// com.canon.ijprinter-media-info-<cassette>-<type>-<size>).
    var trayPaper: [Int: String] = [:]

    /// The paper source that holds this paper type: the cassette the
    /// printer says is loaded with it. Nil when no cassette reports it.
    func source(holding media: String?) -> String? {
        guard let media, let choices = paperSource?.choices else { return nil }
        for tray in trayPaper.keys.sorted() where trayPaper[tray] == media {
            if let c = choices.first(where: {
                let l = $0.label.lowercased()
                return l.contains("cassette") && l.hasSuffix(" \(tray)")
                    || l.contains("tray") && l.hasSuffix(" \(tray)")
            }) { return c.value }
        }
        return nil
    }

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
            var unusedPPD: String? = nil
            if kind != .maker,
               let match = makerDrivers.first(where: {
                   $0.model.caseInsensitiveCompare(model) == .orderedSame
               }) {
                unused = match.model
                unusedPPD = match.path
            }
            var printer = MacPrinter(
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
                                     labelHint: ["quality"]).map(withoutCanonSuperFine),
                pageSize: ppd?.options["PageSize"],
                duplex: ppd?.options["Duplex"],
                unusedMakerDriverPPD: unusedPPD)
            printer.driverDefaults = ppd?.options.compactMapValues(\.defaultValue) ?? [:]
            printer.paperSource = ppd?.option(matching: ["CNIJMediaSupply", "InputSlot"],
                                              labelHint: ["paper source", "media source"])
            for reason in (opts["printer-state-reasons"] ?? "").split(separator: ",") {
                let parts = reason.split(separator: "-")
                // com.canon.ijprinter-media-info-1-63-13
                if reason.hasPrefix("com.canon.ijprinter-media-info-"), parts.count >= 6,
                   let tray = Int(parts[parts.count - 3]) {
                    printer.trayPaper[tray] = String(parts[parts.count - 2])
                }
            }
            out.append(printer)
        }
        // A model already set up with the maker's driver elsewhere
        // needs no setup, just choosing that printer.
        for i in out.indices where out[i].unusedMakerDriver != nil {
            out[i].makerDriverTwin = out.first {
                $0.driver == .maker && !$0.isFax
                    && $0.model.caseInsensitiveCompare(out[i].model) == .orderedSame
            }?.displayName
        }
        return out
    }

    /// Canon's quality list without Super Fine (0), which Canon's own
    /// dialog doesn't pair with photo paper.
    private static func withoutCanonSuperFine(_ o: DriverOption) -> DriverOption {
        guard o.keyword == "CNIJPrintQuality" else { return o }
        return DriverOption(keyword: o.keyword, label: o.label,
                            choices: o.choices.filter { $0.value != "0" },
                            defaultValue: o.defaultValue)
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

    /// A tip for papers we know, shown under the Paper list (the same
    /// tips as the Windows build).
    static func paperHint(_ label: String) -> String? {
        let l = label.lowercased()
        if l.contains("plain") || l == "stationery" {
            return "Plain paper: fine for test sheets and playtest proxies. Don't use it for photo paper: it lays down too much ink and smears."
        }
        if l.contains("luster") {
            return "Photo Paper Pro Luster: print on the smooth, bright white side (not the side with the logo). Let prints dry 10+ minutes before cutting or stacking."
        }
        if l.contains("matte") {
            return "Matte photo paper: no glare, and it takes a sleeve well. Print on the brighter white side."
        }
        if l.contains("plus glossy ii") {
            return "Photo Paper Plus Glossy II: the richest color and deepest blacks. Let prints dry a few minutes before cutting."
        }
        if l.contains("semi-gloss") {
            return "Semi-gloss photo paper: print on the shiny side. Let prints dry a few minutes before cutting."
        }
        if l.contains("glossy") || l.hasPrefix("photographic") {
            return "Glossy photo paper: print on the shiny side. Let prints dry a few minutes before cutting."
        }
        return nil
    }

    /// The driver's best quality: Super Fine, Best, High, or Fine.
    static func bestQuality(_ option: DriverOption?) -> String? {
        guard let choices = option?.choices else { return nil }
        // Canon: Fine (5) with High print mode is the best its own dialog
        // uses for photo paper; Super Fine is left out of the list.
        if option?.keyword == "CNIJPrintQuality", choices.contains(where: { $0.value == "5" }) {
            return "5"
        }
        for word in ["super fine", "highest", "best", "high", "fine"] {
            if let c = choices.first(where: {
                $0.label.lowercased().hasPrefix(word)
                    || $0.value.lowercased().hasPrefix(word)
            }) { return c.value }
        }
        return nil
    }

    /// Every setting Canon's print dialog put on a Pro Luster job that
    /// printed right (Preview, MB5400, Nov 16, 2026), less the paper type,
    /// quality and two sided, which each job sets. Canon drivers get
    /// exactly this set, and nothing else.
    static let canonDialogSettings: [String: String] = [
        "AP_ColorMatchingMode": "AP_VendorColorMatching",
        "CNIJAmountOfExtension": "10",
        "CNIJBalanceC": "0", "CNIJBalanceM": "0", "CNIJBalanceY": "0",
        "CNIJBanner": "5",
        "CNIJCartridge": "1",
        "CNIJClearFormID": "",
        "CNIJClearInkMode": "0",
        "CNIJColorPatternCheckBox": "0",
        "CNIJContrast": "0",
        "CNIJDebugLog": "0",
        "CNIJDensity": "0",
        "CNIJDitherPattern": "2560",
        "CNIJGamma2": "18",
        "CNIJGrayScale": "0",
        "CNIJGrayScaleCheckBox": "0",
        "CNIJHalfToneRadio": "1",
        "CNIJIntent2": "1",
        "CNIJMarginType": "0",
        "CNIJMediaSupply": "46",
        "CNIJMediaType": "0",
        "CNIJPDEEnable": "1",
        "CNIJPQualitySlider": "3",
        "CNIJPZVividPosiProcess": "0",
        "CNIJPaperGapCommand": "10",
        "CNIJPreviewSampleType": "1",
        "CNIJPrintMode": "1",
        "CNIJPrintMode2": "1",
        "CNIJPrintQuality": "5",
        "CNIJSpecialMode": "0",
        "CNIJStapleMargin": "0",
        "CNIJStapleSide": "1",
        "Duplex": "None",
        "Resolution": "600x600dpi",
        "cupsBorderlessScalingFactor": "1",
    ]

    // MARK: - Advice about the printer

    /// Something the person should know about a printer before
    /// printing, with what to do about it.
    struct Advice: Identifiable {
        enum Action { case openPrinterSettings, openURL(URL), setUpDriver, choose(String) }
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
            if let twin = p.makerDriverTwin {
                out.append(Advice(
                    id: "twin",
                    text: "\(p.displayName) uses Apple's generic AirPrint driver, but \(twin) is the same printer set up with \(installed)'s own driver, which has the exact paper types. Print with that one.",
                    isProblem: false, actionLabel: "Use \(twin)",
                    action: .choose(twin)))
            } else {
                out.append(Advice(
                    id: "readd",
                    text: "\(installed)'s own driver is installed on this Mac, but this printer was added with Apple's generic AirPrint driver, so it only offers basic paper types. The app can add this printer again with \(p.maker)'s driver for you. Your current printer stays as it is.",
                    isProblem: false, actionLabel: "Set it up for me",
                    action: .setUpDriver))
            }
        case (.airPrint, nil):
            if let url = makerDriverPage(p.maker) {
                out.append(Advice(
                    id: "getdriver",
                    text: "\(p.displayName) uses Apple's generic AirPrint driver. It prints fine, but \(p.maker)'s own driver adds the exact paper types (like matte photo paper) and finer quality. Show me how walks you through getting it, or just print.",
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

    // MARK: - Setting a printer up with its maker's driver

    /// What "Set it up for me" will add: a new printer entry for the
    /// same printer, on the connection macOS's own discovery found,
    /// with the maker's driver from the Mac's driver folder.
    struct DriverSetupPlan: Sendable {
        let queueName: String
        let displayName: String
        let deviceURI: String
        let ppd: String
        let connection: String
    }

    /// A device CUPS's discovery (lpinfo -l -v) reported.
    struct DiscoveredDevice: Sendable {
        let uri: String
        let makeAndModel: String
        let info: String
    }

    /// Works out the setup for a printer added with AirPrint while
    /// its maker's driver is installed. Every value comes from macOS
    /// itself and must pass the same checks for every maker:
    ///   - the connection is one discovery found for this exact model,
    ///     over USB, standard network printing on the local network,
    ///     or a connection type the maker's driver package installed
    ///     in the system's protected printer folders;
    ///   - the driver is one CUPS lists for this exact model, a file
    ///     directly in /Library/Printers/PPDs/Contents/Resources that
    ///     only the system can change.
    static func planDriverSetup(for p: MacPrinter) throws -> DriverSetupPlan {
        guard let ppd = p.unusedMakerDriverPPD,
              let driverModel = p.unusedMakerDriver else {
            throw PrintError(message: "No maker driver for \(p.model) is installed on this Mac.")
        }
        guard isSafeDriverPath(ppd) else {
            throw PrintError(message: "The installed driver isn't in the Mac's protected driver folder, so the app won't use it. Set the printer up in Printers & Scanners instead.")
        }
        let devices = try discoverDevices()
        let mine = devices.filter {
            $0.makeAndModel.caseInsensitiveCompare(p.model) == .orderedSame
                || $0.info.caseInsensitiveCompare(p.model) == .orderedSame
        }
        let ranked = mine.compactMap { d -> (Int, DiscoveredDevice, String)? in
            guard let (rank, connection) = connectionRank(d.uri) else { return nil }
            return (rank, d, connection)
        }.sorted { $0.0 < $1.0 }
        guard let (rank, device, generic) = ranked.first else {
            throw PrintError(message: "The app couldn't find \(p.model) on a connection it can set up. Make sure the printer is on, then try again, or set it up in Printers & Scanners.")
        }
        // The maker's connection by the name its driver gives it
        // ("Canon IJ Network"), as Printers & Scanners shows it.
        var connection = generic
        if rank == 0, let scheme = URL(string: device.uri)?.scheme,
           let named = devices.first(where: { $0.uri == scheme })?.info,
           !named.isEmpty {
            connection = named
        }
        var name = safeQueueName(driverModel)
        let taken = Set(printers().map(\.id))
        var n = 2
        let base = name
        while taken.contains(name) { name = "\(base)_\(n)"; n += 1 }
        return DriverSetupPlan(queueName: name, displayName: driverModel,
                               deviceURI: device.uri, ppd: ppd,
                               connection: connection)
    }

    /// Adds the printer: lpadmin with the plan's values as separate
    /// arguments (no shell). macOS decides whether this account may
    /// add printers; the app never asks for a password.
    static func runDriverSetup(_ plan: DriverSetupPlan) throws {
        guard isSafeDriverPath(plan.ppd), connectionRank(plan.deviceURI) != nil,
              plan.queueName == safeQueueName(plan.queueName) else {
            throw PrintError(message: "The setup didn't pass its safety checks, so nothing was added.")
        }
        let (status, output) = run("/usr/sbin/lpadmin", [
            "-p", plan.queueName,
            "-D", plan.displayName,
            "-E",
            "-v", plan.deviceURI,
            "-m", plan.ppd,
            "-o", "printer-is-shared=false",
        ], timeout: 60)
        guard status == 0 else {
            let reason = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if reason.lowercased().contains("forbidden")
                || reason.lowercased().contains("password")
                || reason.lowercased().contains("not authorized") {
                throw PrintError(message: "This Mac account isn't allowed to add printers. An administrator can set it up in Printers & Scanners: Add Printer, select it, and under Use pick \(plan.displayName).")
            }
            throw PrintError(message: "macOS didn't add the printer\(reason.isEmpty ? "." : ": " + reason)")
        }
        // Check it took: the new entry must use the maker's driver.
        guard let added = readPPD(queue: plan.queueName),
              driverKind(added) == .maker else {
            throw PrintError(message: "The printer was added but isn't using the maker's driver. Check it in Printers & Scanners.")
        }
    }

    /// CUPS's own discovery of the printers it can reach.
    static func discoverDevices() throws -> [DiscoveredDevice] {
        let (status, text) = run("/usr/sbin/lpinfo", ["-l", "--timeout", "10", "-v"], timeout: 60)
        guard status == 0 else {
            throw PrintError(message: "macOS wouldn't list nearby printers for this account. An administrator can set the printer up in Printers & Scanners.")
        }
        return parseDevices(text)
    }

    static func parseDevices(_ text: String) -> [DiscoveredDevice] {
        var out: [DiscoveredDevice] = []
        var uri: String?
        var fields: [String: String] = [:]
        func flush() {
            if let uri {
                out.append(DiscoveredDevice(uri: uri,
                                            makeAndModel: fields["make-and-model"] ?? "",
                                            info: fields["info"] ?? ""))
            }
            uri = nil; fields = [:]
        }
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("Device: uri = ") {
                flush()
                uri = String(line.dropFirst("Device: uri = ".count))
            } else if let eq = line.range(of: " = ") {
                let key = line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
                fields[key] = String(line[eq.upperBound...])
            }
        }
        flush()
        return out
    }

    /// Whether a device address is one the setup may use, and how
    /// good it is (lower is better): the maker's own connection,
    /// then USB, then standard network printing. Nil for anything
    /// else. The same rule for every maker.
    static func connectionRank(_ uri: String) -> (Int, String)? {
        guard uri.count < 1024,
              uri.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }),
              let url = URL(string: uri), let scheme = url.scheme?.lowercased(),
              url.host?.isEmpty == false
        else { return nil }
        switch scheme {
        case "usb":
            return (1, "USB")
        case "dnssd":
            // Bonjour names only ever point at the local network.
            guard url.host?.hasSuffix(".local.") == true
                    || url.host?.hasSuffix(".local") == true else { return nil }
            return (2, "the network (Bonjour)")
        case "ipp", "ipps", "http", "https", "socket", "lpd", "smb", "file":
            return nil
        default:
            guard isMakerBackend(scheme) else { return nil }
            return (0, "\(scheme) (the maker's own connection)")
        }
    }

    /// A connection type a maker's driver package installed: CUPS's
    /// backend for it is a link into /Library/Printers, and the file
    /// it points to and every folder above it belong to the system
    /// and can't be changed by other accounts.
    static func isMakerBackend(_ scheme: String) -> Bool {
        guard scheme.range(of: "^[a-z][a-z0-9+.-]{0,31}$", options: .regularExpression) != nil
        else { return false }
        let link = "/usr/libexec/cups/backend/\(scheme)"
        let resolved = URL(fileURLWithPath: link).resolvingSymlinksInPath().path
        guard resolved != link, resolved.hasPrefix("/Library/Printers/") else { return false }
        return isSystemProtected(resolved)
    }

    /// A driver file directly in the Mac's printer driver folder,
    /// given as CUPS lists it, that only the system can change.
    static func isSafeDriverPath(_ ppd: String) -> Bool {
        let folder = "Library/Printers/PPDs/Contents/Resources/"
        guard ppd.hasPrefix(folder) else { return false }
        let file = String(ppd.dropFirst(folder.count))
        guard !file.isEmpty, !file.contains("/"), !file.hasPrefix("."),
              file.range(of: #"^[A-Za-z0-9 _+.()-]+\.ppd(\.gz)?$"#, options: .regularExpression) != nil
        else { return false }
        return isSystemProtected("/" + ppd)
    }

    /// The path and every folder above it are owned by root and not
    /// writable by group or others, and the path isn't a link.
    private static func isSystemProtected(_ path: String) -> Bool {
        let fm = FileManager.default
        var current = path
        var first = true
        while current != "/" && !current.isEmpty {
            guard let attrs = try? fm.attributesOfItem(atPath: current),
                  (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
                  let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
            else { return false }
            if first, attrs[.type] as? FileAttributeType == .typeSymbolicLink { return false }
            if perms & 0o022 != 0 {
                // /Library/Printers is root:admin 775 on some Macs:
                // allow group write only for the admin group above
                // the driver itself.
                let group = (attrs[.groupOwnerAccountID] as? NSNumber)?.intValue
                if first || perms & 0o002 != 0 || group != 80 { return false }
            }
            first = false
            current = (current as NSString).deletingLastPathComponent
        }
        return true
    }

    /// A CUPS queue name from a model: letters, digits and _.
    static func safeQueueName(_ model: String) -> String {
        let mapped = model.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_"
        }
        let name = String(mapped).replacingOccurrences(of: "__+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String((name.isEmpty ? "Printer" : name).prefix(100))
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "") }
        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global().async {
            while p.isRunning && Date() < deadline { usleep(100_000) }
            if p.isRunning { p.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: - Send a job

    /// Everything a print job carries: copies, pages, the driver's paper
    /// size for the build's sheet, the chosen paper type and quality under
    /// the driver's own keywords, and two sided or not. Pages are already
    /// the printed sheet, so nothing is scaled.
    struct JobSettings: Sendable {
        var copies = 1
        var pages: ClosedRange<Int>? = nil
        /// The driver's PageSize name, like "Letter".
        var paperName: String? = nil
        /// Driver options by keyword: "CNIJMediaType": "63" and so on.
        var driverOptions: [String: String] = [:]
        var duplex = false
        /// Debug only: the job waits on hold until cancelled.
        var hold = false
    }

    static func jobSettings(printer p: MacPrinter, pageSize: CGSize,
                            copies: Int, pages: ClosedRange<Int>?,
                            media: String?, quality: String?,
                            source: String? = nil,
                            duplex: Bool) -> JobSettings {
        let paper = p.pageSizeName(for: pageSize)
        var s = JobSettings(copies: copies, pages: pages, paperName: paper,
                            duplex: duplex && p.duplex != nil)
        var o: [String: String] = [:]
        if p.driverDefaults.keys.contains(where: { $0.hasPrefix("CNIJ") }) {
            // A Canon inkjet driver: send exactly what Canon's own print
            // dialog sends, and change only what the person chose. Extra
            // settings, or a quality Canon's dialog never pairs with photo
            // paper (Super Fine), made the printer report "the paper in the
            // printer is different from the setting requested", while the
            // same page printed from Preview with Canon's dialog worked
            // (Nov 16, 2026).
            o = canonDialogSettings
            if let media { o["CNIJMediaType"] = media }
            let q = quality ?? "5"
            o["CNIJPrintQuality"] = q
            // Canon's dialog pairs Fine (5) and finer with High print mode.
            let high = (Int(q) ?? 10) <= 5
            o["CNIJPrintMode"] = high ? "1" : "2"
            o["CNIJPrintMode2"] = high ? "1" : "2"
            o["Duplex"] = s.duplex ? "DuplexNoTumble" : "None"
            if let source { o["CNIJMediaSupply"] = source }
        } else {
            // Any other driver: the paper size, the choices made in the
            // print window, and two sided; everything else as the driver
            // and printer have it.
            if let paper { o["PageSize"] = paper }
            if p.duplex != nil { o["Duplex"] = s.duplex ? "DuplexNoTumble" : "None" }
            if let k = p.mediaType?.keyword, let media { o[k] = media }
            if let k = p.quality?.keyword, let quality { o[k] = quality }
            if let k = p.paperSource?.keyword, let source { o[k] = source }
        }
        s.driverOptions = o
        #if DEBUG
        s.hold = ProcessInfo.processInfo.environment["PPG_PRINT_HOLD"] != nil
        #endif
        return s
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
        if env["PPG_SETUP_SELFTEST"] != nil {
            for p in all where p.unusedMakerDriver != nil {
                do {
                    let plan = try planDriverSetup(for: p)
                    out.append("plan for \(p.id): queue=\(plan.queueName) name=\(plan.displayName) via=\(plan.connection) uri=\(plan.deviceURI.prefix(40))… ppd=\(plan.ppd)")
                } catch {
                    out.append("plan for \(p.id): error \(error.localizedDescription)")
                }
            }
            let uris = ["canonijnetwork://Canon/Canon%20MB5400%20series?x=1",
                        "usb://Canon/MB5400%20series?serial=123",
                        "dnssd://Canon%20MB5400%20series._ipp._tcp.local./?uuid=1",
                        "dnssd://evil.example.com./", "ipp://10.0.0.5/ipp/print",
                        "socket://10.0.0.5", "file:///etc/passwd", "evilbackend://x/y",
                        "usb://Canon/MB5400 series", "canonijnetwork://Canon/a;rm -rf ~",
                        "smb://host/share"]
            for u in uris { out.append("uri \(u) -> \(connectionRank(u).map { "ok rank \($0.0) (\($0.1))" } ?? "refused")") }
            let ppds = ["Library/Printers/PPDs/Contents/Resources/CanonIJMB5400series.ppd.gz",
                        "Library/Printers/PPDs/Contents/Resources/../../../../tmp/x.ppd",
                        "/tmp/evil.ppd", "Library/Printers/PPDs/Contents/Resources/sub/x.ppd",
                        "Library/Printers/PPDs/Contents/Resources/Missing.ppd.gz", "drv:///sample.drv/generic.ppd"]
            for d in ppds { out.append("ppd \(d) -> \(isSafeDriverPath(d) ? "ok" : "refused")") }
            out.append("queue name: \(safeQueueName("Canon MB5400 series; rm -rf ~"))")
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
            out.append("  job \(jobSettings(printer: p, pageSize: CGSize(width: 612, height: 792), copies: 1, pages: nil, media: presets(for: p).dropFirst().first?.media, quality: presets(for: p).dropFirst().first?.quality, duplex: true))")
        }
        if env["PPG_PRINT_HOLD"] != nil, let pdf = env["PPG_PRINT_SELFTEST_PDF"],
           let p = all.first(where: { !$0.isFax && !$0.isStopped }) {
            let preset = presets(for: p).first { ($0.media ?? "").contains("63") || $0.label.lowercased().contains("photo") } ?? presets(for: p).last
            // Canon's Photo Paper Pro Luster at its best quality when the
            // driver lists it: the job that printed A4 plain before.
            let luster = p.mediaType?.choices.contains { $0.value == "63" } == true
            let job = jobSettings(printer: p, pageSize: CGSize(width: 612, height: 792),
                                  copies: 2, pages: nil,
                                  media: luster ? "63" : preset?.media,
                                  quality: luster ? bestQuality(p.quality) : preset?.quality,
                                  duplex: false)
            out.append("submit to \(p.id): \(job)")
            do {
                try submit(file: URL(fileURLWithPath: pdf), to: p.id,
                           title: "PPG self-test", settings: job)
                out.append("sent")
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

    /// Sends a PDF to a printer through Apple's print system (Core
    /// Printing), the way Preview's Print does, with the job's settings
    /// on its print ticket. Some makers' drivers (Canon's, Nov 15, 2026)
    /// read their settings only from that ticket: a job sent straight to
    /// CUPS with the same settings as plain options printed on the
    /// driver's defaults, A4 plain paper, instead of Letter Pro Luster.
    static func submit(file: URL, to queue: String, title: String,
                       settings job: JobSettings) throws {
        func fail(_ what: String, _ status: OSStatus) -> PrintError {
            PrintError(message: "The print system couldn't \(what) (error \(status)).")
        }
        guard let printer = PMPrinterCreateFromPrinterID(queue as CFString) else {
            throw PrintError(message: "\(queue) isn't set up on this Mac any more.")
        }
        defer { PMRelease(PMObject(printer)) }

        var sessionOut: PMPrintSession?
        guard PMCreateSession(&sessionOut) == noErr, let session = sessionOut else {
            throw PrintError(message: "The print system didn't start.")
        }
        defer { PMRelease(PMObject(session)) }
        var status = PMSessionSetCurrentPMPrinter(session, printer)
        guard status == noErr else { throw fail("pick that printer", status) }

        var settingsOut: PMPrintSettings?
        guard PMCreatePrintSettings(&settingsOut) == noErr, let settings = settingsOut else {
            throw PrintError(message: "The print system didn't start.")
        }
        defer { PMRelease(PMObject(settings)) }
        PMSessionDefaultPrintSettings(session, settings)
        PMPrintSettingsSetJobName(settings, title as CFString)
        PMSetCopies(settings, UInt32(clamping: max(1, job.copies)), false)
        if let pages = job.pages {
            PMSetFirstPage(settings, UInt32(clamping: max(1, pages.lowerBound)), false)
            PMSetLastPage(settings, UInt32(clamping: max(1, pages.upperBound)), false)
        } else {
            PMSetFirstPage(settings, 1, false)
            // kPMPrintAllPages is -1, which Core Printing reads as the
            // largest page number. Converted with UInt32(...) it crashed
            // every all-pages print (1.64.2 build, Nov 15, 2026); this keeps
            // its bits, as C does.
            PMSetLastPage(settings, UInt32(truncatingIfNeeded: kPMPrintAllPages), false)
        }
        PMSetDuplex(settings, PMDuplexMode(job.duplex ? kPMDuplexNoTumble : kPMDuplexNone))
        // The driver's own options go on the ticket under their keywords,
        // where the driver looks for them (and CUPS gets them too).
        for (key, value) in job.driverOptions {
            PMPrintSettingsSetValue(settings, key as CFString, value as CFString, false)
        }
        if job.hold {
            PMPrintSettingsSetValue(settings, "job-hold-until" as CFString, "indefinite" as CFString, false)
        }

        // The page format: the driver's paper for the build's sheet.
        var formatOut: PMPageFormat?
        if let name = job.paperName, let paper = paper(named: name, on: printer) {
            status = PMCreatePageFormatWithPMPaper(&formatOut, paper)
        } else {
            status = PMCreatePageFormat(&formatOut)
            if status == noErr, let f = formatOut { PMSessionDefaultPageFormat(session, f) }
        }
        guard status == noErr, let format = formatOut else { throw fail("set the paper size", status) }
        defer { PMRelease(PMObject(format)) }
        PMSetScale(format, 100)
        PMSessionValidatePrintSettings(session, settings, nil)
        PMSessionValidatePageFormat(session, format, nil)

        status = PMPrinterPrintWithFile(printer, settings, format, "application/pdf" as CFString, file as CFURL)
        guard status == noErr else { throw fail("send the job", status) }
    }

    /// The printer's paper whose driver name is this ("Letter").
    private static func paper(named name: String, on printer: PMPrinter) -> PMPaper? {
        var listOut: Unmanaged<CFArray>?
        guard PMPrinterGetPaperList(printer, &listOut) == noErr,
              let list = listOut?.takeUnretainedValue() else { return nil }
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let paper: PMPaper = OpaquePointer(raw)
            var ppdName: Unmanaged<CFString>?
            if PMPaperGetPPDPaperName(paper, &ppdName) == noErr,
               ppdName?.takeUnretainedValue() as String? == name {
                return paper
            }
        }
        return nil
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
