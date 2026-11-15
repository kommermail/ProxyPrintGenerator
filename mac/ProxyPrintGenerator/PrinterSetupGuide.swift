//
//  PrinterSetupGuide.swift
//  ProxyPrintGenerator
//
//  The printer setup guide (Nov 14, 2026): everything a person has to
//  do outside the app to print with their printer maker's own driver,
//  one short step at a time, and easy to skip. Each step can be
//  skipped, the whole guide closes with "Skip, print with what I
//  have", and steps the app can see are already done (a driver
//  installed, a printer already using it) are checked off and passed.
//
//  The app never downloads or installs a driver itself: the guide
//  opens the maker's page in the web browser, and the maker's own
//  installer does the installing.
//

#if os(macOS)
import SwiftUI
import AppKit

struct PrinterSetupGuide: View {
    /// The printer the guide is about; nil when no printer is set up.
    let printer: MacPrinter?
    /// Re-reads the printers and returns the same one fresh, so
    /// "Check again" can tick off a driver just installed.
    let recheck: () async -> MacPrinter?
    /// Closes the guide and runs the print sheet's Set it up for me.
    let setUpForMe: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var current: MacPrinter?
    @State private var step = 0
    @State private var checking = false
    @State private var skipped: Set<Int> = []

    private var p: MacPrinter? { current ?? printer }
    private var maker: String { p?.maker.isEmpty == false ? p!.maker : "your printer maker" }
    private var model: String { p?.model ?? "your printer" }

    private enum Step: Int, CaseIterable {
        case connect, download, install, connectDriver, print
    }

    /// Steps the app can see are already done.
    private func isDone(_ s: Step) -> Bool {
        guard let p else { return false }
        switch s {
        case .connect: return true
        case .download, .install:
            return p.driver == .maker || p.unusedMakerDriver != nil
        case .connectDriver:
            return p.driver == .maker || p.makerDriverTwin != nil
        case .print: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                PlaqueTitleText(text: "Printer setup guide", size: 26)
                    .fixedSize()
                Spacer()
                Button("Skip, print with what I have") { dismiss() }
                    .help("Close the guide. Everything prints fine without it; the maker's driver just adds exact paper types and finer quality.")
            }
            line("About five minutes, once. It gets you \(maker)'s own driver, with the exact paper types (like matte photo paper) and its finest quality. Skip any step you've already done.", 16)
                .opacity(0.85)
            progressDots
            Divider().overlay(Theme.gold.opacity(0.5))
            ScrollView { stepView.frame(maxWidth: .infinity, alignment: .leading) }
            Divider().overlay(Theme.gold.opacity(0.5))
            navigation
        }
        .padding(24)
        .frame(width: 680, height: 560)
        .background(LeatherBackground())
        .onAppear { step = firstOpenStep() }
    }

    private func firstOpenStep() -> Int {
        Step.allCases.first { !isDone($0) }?.rawValue ?? Step.print.rawValue
    }

    // MARK: - Pieces

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                let done = isDone(s)
                Button {
                    step = s.rawValue
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: done ? "checkmark.circle.fill"
                              : (skipped.contains(s.rawValue) ? "arrow.right.circle"
                                 : (s.rawValue == step ? "circle.inset.filled" : "circle")))
                            .foregroundStyle(done ? Color.green : Theme.gold)
                        Text(title(s))
                            .font(Theme.fellFont(size: 14))
                            .foregroundStyle(Theme.parchment.opacity(s.rawValue == step ? 1 : 0.7))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                if s != .print {
                    Rectangle().fill(Theme.gold.opacity(0.4)).frame(width: 10, height: 1)
                }
            }
        }
    }

    private func title(_ s: Step) -> String {
        switch s {
        case .connect: return "Connect"
        case .download: return "Get driver"
        case .install: return "Install"
        case .connectDriver: return "Use driver"
        case .print: return "Print"
        }
    }

    @ViewBuilder private var stepView: some View {
        let s = Step(rawValue: step) ?? .connect
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                KingdomText(text: "Step \(step + 1). \(heading(s))", size: 22)
                if isDone(s) {
                    Label("Already done", systemImage: "checkmark.circle.fill")
                        .font(Theme.fellFont(size: 15))
                        .foregroundStyle(Color.green)
                }
            }
            switch s {
            case .connect:
                bullet("Turn the printer on and connect it to the same Wi-Fi as this Mac, or plug it in with a USB cable.")
                bullet("If it isn't in this app's printer list, add it: open Printers & Scanners, click **Add Printer, Scanner, or Fax…**, pick it, and click **Add**.")
                Button("Open Printers & Scanners") { MacPrinting.openPrinterSettings() }
            case .download:
                bullet("Open \(maker)'s support page, search for **\(searchName)**, and pick the **macOS** downloads.")
                bullet("Download the **printer driver**. Canon calls it the **CUPS Printer Driver**. Skip the scanner driver and the extra utilities; they aren't needed for printing.")
                if let url = MacPrinting.makerDriverPage(maker) {
                    Button("Open \(maker)'s driver page") { openURL(url) }
                        .help("Opens \(url.host ?? "the page") in your web browser")
                }
                line("The page opens in your web browser. This app doesn't download anything from it.", 14.5)
                    .opacity(0.7)
            case .install:
                bullet("Open your **Downloads** folder and double-click the file you just downloaded, then the installer inside it.")
                bullet("Click through the installer. When it asks for your Mac password, that's macOS asking for the installer, not this app.")
                bullet("When it says the installation was successful, come back here and click **Check again**.")
                checkAgain
            case .connectDriver:
                if let twin = p?.makerDriverTwin {
                    bullet("You already have **\(twin)** using \(maker)'s driver. Pick it in the print window and you're set.")
                } else {
                    bullet("Your printer needs to be added again with \(maker)'s driver. Installing the driver doesn't change printers that were already added; macOS picks Apple's AirPrint driver unless told otherwise.")
                    bullet("**Set it up for me** finds the printer and adds it with \(maker)'s driver. Your current printer stays as it is.")
                    HStack(spacing: 10) {
                        Button("Set it up for me") {
                            dismiss()
                            setUpForMe()
                        }
                        .disabled(p?.unusedMakerDriver == nil)
                        checkAgain
                    }
                    if p?.unusedMakerDriver == nil {
                        line("The app doesn't see \(maker)'s driver for \(model) yet. Install it (step 3), then click Check again.", 14.5)
                            .foregroundStyle(Color(red: 1, green: 0.72, blue: 0.45))
                    }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 6) {
                            bullet("Open Printers & Scanners and click **Add Printer, Scanner, or Fax…**.")
                            bullet("Pick your printer. If it's listed twice, pick the one whose Kind names \(maker), like **Canon IJ Network**, or the **USB** one.")
                            bullet("Under **Use**, choose **\(p?.unusedMakerDriver ?? model)**, not AirPrint, and click **Add**.")
                            Button("Open Printers & Scanners") { MacPrinting.openPrinterSettings() }
                        }
                        .padding(.top, 6)
                    } label: {
                        line("Rather do it yourself?", 15.5)
                    }
                }
            case .print:
                bullet("In the print window, pick the printer that uses \(maker)'s driver.")
                bullet("Click a paper button, like **Matte photo**, to match the paper in the tray. It sets the best quality too.")
                bullet("Click **Print**. Cards always print at actual size.")
            }
        }
    }

    private var checkAgain: some View {
        Button(checking ? "Checking…" : "Check again") {
            checking = true
            Task {
                current = await recheck()
                checking = false
                if isDone(.install), step <= Step.install.rawValue {
                    step = Step.connectDriver.rawValue
                }
            }
        }
        .disabled(checking)
    }

    private var navigation: some View {
        HStack {
            Button("Back") { step = max(0, step - 1) }
                .disabled(step == 0)
            Spacer()
            if step < Step.print.rawValue {
                Button("Skip this step") {
                    skipped.insert(step)
                    step += 1
                }
                Button("Next") { step += 1 }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(Theme.fellFont(size: 17))
    }

    private func heading(_ s: Step) -> String {
        switch s {
        case .connect: return "Connect your printer"
        case .download: return "Get \(maker)'s driver"
        case .install: return "Install it"
        case .connectDriver: return "Use the driver with your printer"
        case .print: return "Print"
        }
    }

    /// "MB5400" from "Canon MB5400 series", for the maker's search box.
    private var searchName: String {
        var words = model.split(separator: " ").map(String.init)
        if let first = words.first, first.caseInsensitiveCompare(maker) == .orderedSame {
            words.removeFirst()
        }
        if words.last?.lowercased() == "series" { words.removeLast() }
        return words.isEmpty ? model : words.joined(separator: " ")
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(Theme.gold)
            Text(TutorialSheet.styled(text))
                .font(Theme.fellFont(size: 17))
                .foregroundStyle(Theme.parchment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ text: String, _ size: CGFloat) -> some View {
        Text(text)
            .font(Theme.fellFont(size: size))
            .foregroundStyle(Theme.parchment)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
