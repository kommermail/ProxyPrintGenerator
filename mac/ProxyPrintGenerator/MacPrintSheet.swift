//
//  MacPrintSheet.swift
//  ProxyPrintGenerator
//
//  The app's own print window on the Mac, mirrored from the Windows
//  build's print sheet (Nov 14, 2026): printer, copies and page range,
//  one-click paper presets, the driver's paper type and quality lists,
//  and a page preview. It always prints at actual size, tells the
//  printer the paper size the pages were built for, and sends the job
//  straight to the printer (MacPrinting.submit). Apple's own print
//  dialog is still one click away under More options.
//
//  It also says what's wrong with a printer before you print: stopped
//  queues, and printers added with Apple's generic AirPrint driver when
//  the maker's driver would offer the real paper types.
//

#if os(macOS)
import SwiftUI
import AppKit
import PDFKit

/// One print job for the sheet: the whole build, or the one sided
/// pages or the two sided sheets of a back to back build.
struct MacPrintRequest: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let jobName: String
    let duplex: Bool
    /// The printer the cards were fitted to (Print options > Safe
    /// area > Fit to my printer), by display name.
    let fittedPrinter: String?
}

struct MacPrintSheet: View {
    let request: MacPrintRequest
    let onDone: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var printers: [MacPrinter] = []
    @State private var loaded = false
    @State private var printerID: String?
    @State private var preset: String?
    @State private var media: String?
    @State private var quality: String?
    @State private var copies = 1
    @State private var allPages = true
    @State private var fromPage = 1
    @State private var toPage = 1
    @State private var pageCount = 1
    @State private var pageSize: CGSize = .zero
    @State private var preview: NSImage?
    @State private var sending = false
    @State private var errorText: String?

    private var choosable: [MacPrinter] { printers.filter { !$0.isFax } }
    private var printer: MacPrinter? { printers.first { $0.id == printerID } }
    private var presets: [MacPrinting.PaperPreset] {
        printer.map(MacPrinting.presets) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlaqueTitleText(text: request.title, size: 28)
                .fixedSize()
            HStack(alignment: .top, spacing: 20) {
                previewPane
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !loaded {
                            ProgressView("Asking your printers…")
                        } else if choosable.isEmpty {
                            line("No printers are set up on this Mac. Add one in Printers & Scanners.", 17)
                            Button("Open Printers & Scanners") {
                                MacPrinting.openPrinterSettings()
                            }
                        } else {
                            settings
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let errorText {
                line(errorText, 16)
                    .foregroundStyle(Color(red: 1, green: 0.54, blue: 0.48))
            }
            buttons
        }
        .padding(24)
        .frame(width: 820, height: 640)
        .background(LeatherBackground())
        .task { await load() }
    }

    // MARK: - Pieces

    private var previewPane: some View {
        VStack(spacing: 8) {
            Group {
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .background(Color.white)
                        .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
                } else {
                    Rectangle().fill(Color.white.opacity(0.15))
                }
            }
            .frame(width: 230, height: 300)
            line("\(pageCount) \(pageCount == 1 ? "page" : "pages") · \(paperLabel)", 15)
                .opacity(0.8)
            line("Always prints at actual size", 15)
                .opacity(0.8)
        }
        .frame(width: 240)
    }

    @ViewBuilder private var settings: some View {
        row("Printer") {
            Picker("", selection: $printerID) {
                ForEach(choosable) { p in
                    Text(p.displayName + (p.isStopped ? " (stopped)" : ""))
                        .tag(Optional(p.id))
                }
            }
            .labelsHidden()
            .frame(width: 300)
        }
        if let printer {
            ForEach(MacPrinting.advice(for: printer)) { a in
                adviceBox(a)
            }
            if !presets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    KingdomText(text: "Paper", size: 19)
                    HStack(spacing: 8) {
                        ForEach(presets) { p in
                            Button(p.label) { apply(p) }
                                .buttonStyle(.bordered)
                                .tint(preset == p.label ? Theme.gold : nil)
                                .help(p.hint)
                        }
                    }
                }
            }
            if let option = printer.mediaType {
                optionRow(option, selection: $media)
            }
            if let option = printer.quality {
                optionRow(option, selection: $quality)
            }
            row("Copies") {
                Stepper(value: $copies, in: 1...99) {
                    Text("\(copies)").monospacedDigit()
                }
            }
            row("Pages") {
                Picker("", selection: $allPages) {
                    Text("All").tag(true)
                    Text("Range").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                if !allPages {
                    Stepper("From \(fromPage)", value: $fromPage, in: 1...max(1, toPage))
                    Stepper("to \(toPage)", value: $toPage, in: fromPage...max(fromPage, pageCount))
                }
            }
            ForEach(warnings(for: printer), id: \.self) { w in
                line(w, 15.5)
                    .foregroundStyle(Color(red: 1, green: 0.72, blue: 0.45))
            }
        }
    }

    private var buttons: some View {
        HStack {
            Button("More options…") { moreOptions() }
                .help("Apple's print dialog, with every setting your printer's driver has")
                .disabled(sending)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(sending ? "Sending…" : "Print") { send() }
                .keyboardShortcut(.defaultAction)
                .disabled(sending || printer == nil)
        }
        .font(Theme.fellFont(size: 17))
    }

    private func row<Content: View>(_ title: String,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            KingdomText(text: title, size: 19)
                .frame(width: 110, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func optionRow(_ option: DriverOption,
                           selection: Binding<String?>) -> some View {
        row(Self.friendly(option.label)) {
            Picker("", selection: Binding(
                get: { selection.wrappedValue },
                set: { selection.wrappedValue = $0; preset = nil })) {
                ForEach(option.choices, id: \.value) { c in
                    Text(Self.friendly(c.label)).tag(Optional(c.value))
                }
            }
            .labelsHidden()
            .frame(width: 300)
        }
    }

    private func adviceBox(_ a: MacPrinting.Advice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            line(a.text, 15.5)
            if let label = a.actionLabel, let action = a.action {
                Button(label) {
                    switch action {
                    case .openPrinterSettings: MacPrinting.openPrinterSettings()
                    case .openURL(let url): openURL(url)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((a.isProblem ? Color.red : Color.black).opacity(0.25)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(a.isProblem ? Color(red: 1, green: 0.5, blue: 0.4)
                                          : Theme.gold.opacity(0.6),
                              lineWidth: 1))
    }

    private func line(_ text: String, _ size: CGFloat) -> some View {
        Text(text)
            .font(Theme.fellFont(size: size))
            .foregroundStyle(Theme.parchment)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "MediaType" and "stationery" read better as "Paper type" and
    /// "Stationery".
    static func friendly(_ s: String) -> String {
        switch s {
        case "MediaType", "Media Type": return "Paper type"
        case "stationery": return "Plain paper (stationery)"
        case "photographic": return "Photo paper"
        case "any": return "Any"
        default:
            return s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    // MARK: - State

    private var paperLabel: String {
        if let name = printer?.pageSize?.choices.first(where: {
            $0.value == printer?.pageSizeName(for: pageSize)
        })?.label { return name }
        let w = pageSize.width / 72, h = pageSize.height / 72
        return String(format: "%.1f × %.1f in", w, h)
    }

    private func warnings(for p: MacPrinter) -> [String] {
        var out: [String] = []
        if p.pageSize != nil, p.pageSizeName(for: pageSize) == nil {
            out.append("\(p.displayName) doesn't list this paper size (\(paperLabel)). It may shrink or crop the page; pick a paper size it takes under Paper in the print settings and build again.")
        }
        if request.duplex, p.duplex?.choices.contains(where: { $0.value == "DuplexNoTumble" }) != true {
            out.append("\(p.displayName) doesn't print two sided by itself. Print, then put the stack back in face down with the top edge first and print the backs with Pages set to the even pages.")
        }
        if let fitted = request.fittedPrinter,
           fitted.caseInsensitiveCompare(p.displayName) != .orderedSame {
            out.append("The cards were fitted to \(fitted)'s reach, not this printer's. If an edge gets clipped, pick this printer under Print options > Safe area and build again.")
        }
        return out
    }

    private func load() async {
        if let doc = PDFDocument(url: request.url) {
            pageCount = max(1, doc.pageCount)
            toPage = pageCount
            if let page = doc.page(at: 0) {
                pageSize = page.bounds(for: .mediaBox).size
                preview = page.thumbnail(of: CGSize(width: 460, height: 600),
                                         for: .mediaBox)
            }
        }
        let found = await Task.detached { MacPrinting.printers() }.value
        printers = found
        let memory = MacPrintMemory.load()
        let usable = found.filter { !$0.isFax }
        let healthy = usable.filter { !$0.isStopped }
        let pick = healthy.first { $0.id == memory.printer }
            ?? healthy.first { $0.isDefault }
            ?? healthy.first { $0.driver == .maker }
            ?? healthy.first ?? usable.first
        printerID = pick?.id
        if let pick { choosePaper(for: pick, memory: memory) }
        loaded = true
    }

    /// The printer's own defaults, then what was used last time,
    /// when this printer offers it.
    private func choosePaper(for p: MacPrinter, memory: MacPrintMemory) {
        media = p.mediaType?.defaultValue
        quality = p.quality?.defaultValue
        preset = nil
        if let name = memory.preset,
           let match = MacPrinting.presets(for: p).first(where: { $0.label == name }) {
            apply(match)
        } else {
            if let m = memory.media, p.mediaType?.choices.contains(where: { $0.value == m }) == true {
                media = m
            }
            if let q = memory.quality, p.quality?.choices.contains(where: { $0.value == q }) == true {
                quality = q
            }
        }
    }

    private func apply(_ p: MacPrinting.PaperPreset) {
        preset = p.label
        if let m = p.media { media = m }
        if let q = p.quality { quality = q }
    }

    private func jobOptions(for p: MacPrinter) -> [String: String] {
        MacPrinting.jobOptions(
            printer: p, pageSize: pageSize, copies: copies,
            pages: allPages ? nil : fromPage...toPage,
            media: media, quality: quality, duplex: request.duplex)
    }

    private func send() {
        guard let p = printer else { return }
        sending = true
        errorText = nil
        let options = jobOptions(for: p)
        let url = request.url, title = request.jobName, queue = p.id
        Task {
            do {
                let job = try await Task.detached {
                    try MacPrinting.submit(file: url, to: queue, title: title, options: options)
                }.value
                MacPrintMemory(printer: p.id, preset: preset,
                               media: media, quality: quality).save()
                let paper = p.mediaType?.choices.first { $0.value == media }?.label
                var message = "Sent to \(p.displayName) (job \(job))"
                if let paper { message += " on \(Self.friendly(paper))" }
                onDone(message + ".")
                dismiss()
            } catch {
                sending = false
                errorText = error.localizedDescription
            }
        }
    }

    private func moreOptions() {
        let request = request, name = printer?.displayName
        let done = onDone
        dismiss()
        // Apple's dialog opens once this sheet is gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            done(PrintJobModel.presentPrintPanel(
                url: request.url, jobName: request.jobName,
                duplex: request.duplex, printerName: name))
        }
    }
}
#endif
