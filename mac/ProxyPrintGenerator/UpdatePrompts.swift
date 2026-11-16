//
//  UpdatePrompts.swift
//  ProxyPrintGenerator
//
//  The update sheets, mirrored from the Windows build (Nov 14,
//  2026): the one time question about checking GitHub for new
//  versions, the "new version" sheet that installs one when asked,
//  and the controls under the version at the bottom of the Deck
//  Library. Updater.swift does the network and the install. Mac only.
//

#if os(macOS)
import SwiftUI
import AppKit
import Combine

@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    /// The one time question is showing.
    @Published var askingPermission = false
    /// The Move to Applications prompt is showing.
    @Published var offeringMove = false
    @Published var moveError: String?
    /// A newer version to offer.
    @Published var offer: UpdateInfo?
    @Published var checkAtStartup: Bool = UpdateSettings.load().checkAtStartup == true
    /// The last manual check's result line, for the library.
    @Published var manualResult: String?
    @Published var checking = false

    private var started = false

    /// At launch: tidy up after an update, ask once, then check if
    /// allowed.
    func onStartup() {
        guard !started else { return }
        started = true
        Updater.cleanUpAfterUpdate()
        #if DEBUG
        if let log = ProcessInfo.processInfo
            .environment["PPG_UPDATE_SELFTEST_LOG"] {
            Task { await selfTest(log: log) }
            return
        }
        #endif
        #if DEBUG
        // Debug builds only: runs a small real build and logs how often
        // the main thread got to run meanwhile (a frozen window scores
        // near zero) and the progress stages it saw.
        if let log = ProcessInfo.processInfo.environment["PPG_BUILD_SELFTEST_LOG"] {
            Task { @MainActor in
                var ticks = 0
                let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    MainActor.assumeIsolated { ticks += 1 }
                }
                let model = PrintJobModel()
                model.deckText = "1 Sol Ring\n1 Lightning Bolt\n1 Counterspell\n1 Llanowar Elves\n1 Swords to Plowshares\n1 Dark Ritual\n1 Giant Growth\n1 Brainstorm\n1 Path to Exile\n1 Island"
                model.scale = 2
                model.format = .pdf
                model.outputName = "ppg-build-selftest"
                let start = Date()
                var stages: [String] = []
                model.start()
                while model.isRunning || (model.result == nil && model.errorText == nil) {
                    let entry = "\(model.stageText) \(Int(model.fraction * 100))%"
                    if stages.last != entry { stages.append(entry) }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    if Date().timeIntervalSince(start) > 300 { break }
                }
                timer.invalidate()
                let elapsed = Date().timeIntervalSince(start)
                let lines = [
                    String(format: "elapsed %.1fs, main-thread ticks %d (about %d if never blocked)", elapsed, ticks, Int(elapsed * 10)),
                    "result: \(model.result?.outputURL.lastPathComponent ?? "none") error: \(model.errorText ?? "none")",
                    "progress seen (\(stages.count) distinct): " + stages.prefix(40).joined(separator: " | "),
                ]
                if let url = model.result?.outputURL { try? FileManager.default.removeItem(at: url) }
                try? (lines.joined(separator: "\n") + "\n").write(toFile: log, atomically: true, encoding: .utf8)
            }
            return
        }
        // Debug builds only: moves the app (into PPG_MOVE_TEST_DEST)
        // with no clicks and logs each step, for testing.
        if let log = ProcessInfo.processInfo.environment["PPG_MOVE_SELFTEST_LOG"] {
            func write(_ line: String) {
                let entry = "\(line)\n"
                if let h = FileHandle(forWritingAtPath: log) {
                    h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close()
                } else { try? entry.write(toFile: log, atomically: true, encoding: .utf8) }
            }
            write("running from \(Bundle.main.bundleURL.path) translocated=\(AppMover.isTranslocated) offer=\(AppMover.shouldOffer)")
            if AppMover.shouldOffer {
                do { let moved = try AppMover.move(); write("moved to \(moved.path); relaunching"); Updater.relaunch(moved) }
                catch { write("error: \(error.localizedDescription)") }
            }
            return
        }
        #endif
        #if DEBUG
        // Debug builds only: shows the move prompt, then clicks Move
        // itself after two seconds, the way a person would.
        if ProcessInfo.processInfo.environment["PPG_MOVE_CLICK_TEST"] != nil, AppMover.shouldOffer {
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                offeringMove = true
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                moveToApplications()
            }
            return
        }
        #endif
        // A copy outside Applications offers to move there first: from
        // anywhere else it can't update itself.
        if AppMover.shouldOffer {
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                offeringMove = true
            }
            return
        }
        continueStartup()
    }

    /// The update question and launch check, after the move prompt.
    func continueStartup() {
        let settings = UpdateSettings.load()
        if settings.checkAtStartup == nil {
            Task {
                // Let the window settle first.
                try? await Task.sleep(nanoseconds: 700_000_000)
                askingPermission = true
            }
        } else if settings.checkAtStartup == true {
            Task { await check(manual: false) }
        }
    }

    /// Moves the app into Applications and reopens it from there.
    func moveToApplications() {
        moveError = nil
        do {
            let moved = try AppMover.move()
            offeringMove = false
            Updater.relaunch(moved)
        } catch {
            moveError = error.localizedDescription
        }
    }

    func declineMove(forever: Bool) {
        if forever {
            var s = UpdateSettings.load()
            s.declinedMovePath = AppMover.declineKey
            s.save()
        }
        offeringMove = false
        continueStartup()
    }

    func setCheckAtStartup(_ on: Bool) {
        var s = UpdateSettings.load()
        s.checkAtStartup = on
        s.save()
        checkAtStartup = on
    }

    func answerPermission(_ yes: Bool) {
        askingPermission = false
        setCheckAtStartup(yes)
        if yes { Task { await check(manual: false) } }
    }

    /// Checks GitHub and offers a newer version when one is out. A
    /// launch check stays silent otherwise and passes over a skipped
    /// version; a manual check leaves a line in manualResult.
    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        if manual { manualResult = "Checking GitHub…" }
        defer { checking = false }
        do {
            let info = try await Updater.check()
            let current = Updater.currentVersion.label
            guard let info else {
                if manual { manualResult = "You have the newest version (\(current))." }
                return
            }
            if !manual,
               UpdateSettings.load().skippedVersion == info.version.label {
                return
            }
            offer = info
            if manual { manualResult = "Version \(info.version.label) is available." }
        } catch {
            if manual {
                manualResult = "Couldn't check for updates. \(error.localizedDescription)"
            }
        }
    }

    #if DEBUG
    /// Debug builds only: checks, installs and relaunches with no
    /// clicks, writing each step to the log file.
    private func selfTest(log: String) async {
        func write(_ line: String) {
            let entry = "\(Date()) [\(Updater.currentVersion.label)] \(line)\n"
            if let h = FileHandle(forWritingAtPath: log) {
                h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close()
            } else {
                try? entry.write(toFile: log, atomically: true, encoding: .utf8)
            }
        }
        write("launched from \(Bundle.main.bundleURL.path)")
        write("cannotInstallReason: \(Updater.cannotInstallReason ?? "none")")
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(Bundle.main.bundleIdentifier ?? "")/Data/Library/Application Support/ProxyPrint")
        let listing = (try? FileManager.default.contentsOfDirectory(
            atPath: container.path)) ?? ["<unreadable>"]
        write("container: \(listing); data folder: \((try? FileManager.default.contentsOfDirectory(atPath: AppData.folder.path)) ?? [])")
        do {
            guard let info = try await Updater.check() else {
                write("check: no newer version")
                return
            }
            write("check: offers \(info.version.label)")
            let app = try await Updater.install(info) { _, _ in }
            write("installed; relaunching \(app.path)")
            Updater.relaunch(app)
        } catch {
            write("error: \(error.localizedDescription)")
        }
    }
    #endif

    func skip(_ info: UpdateInfo) {
        var s = UpdateSettings.load()
        s.skippedVersion = info.version.label
        s.save()
        offer = nil
    }
}

/// Hangs the update sheets on the app's root view.
struct UpdateSheets: ViewModifier {
    @ObservedObject private var updates = UpdateController.shared

    func body(content: Content) -> some View {
        content
            .onAppear { updates.onStartup() }
            .sheet(isPresented: $updates.offeringMove) {
                MoveToApplicationsSheet()
            }
            .sheet(isPresented: $updates.askingPermission) {
                UpdatePermissionSheet()
            }
            .sheet(item: $updates.offer) { info in
                UpdateOfferSheet(info: info)
            }
    }
}

private struct MoveToApplicationsSheet: View {
    @ObservedObject private var updates = UpdateController.shared

    private var folderName: String {
        AppMover.destinationFolder.path == "/Applications"
            ? "Applications" : AppMover.destinationFolder.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlaqueTitleText(text: "Move to \(folderName)?", size: 28)
                .fixedSize()
            note("ProxyPrintGenerator is running from \(AppMover.isTranslocated ? "your Downloads folder" : "outside your Applications folder"). From there it can't update itself, so every new version would mean downloading it again and approving it in System Settings.", 18)
            note("Move it to \(folderName) and it reopens from there. After that, new versions install with one click, with no more approvals. The downloaded copy goes to the Trash; your decks and settings stay as they are.", 17)
            if let error = updates.moveError {
                note(error, 16)
                    .foregroundStyle(Color(red: 1, green: 0.54, blue: 0.48))
            }
            HStack {
                Button {
                    updates.declineMove(forever: true)
                } label: {
                    Text("Don't ask again")
                        .font(Theme.fellFont(size: 16))
                        .underline()
                        .foregroundStyle(Theme.parchment.opacity(0.75))
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Not now") { updates.declineMove(forever: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Move to \(folderName)") { updates.moveToApplications() }
                    .keyboardShortcut(.defaultAction)
            }
            .font(Theme.fellFont(size: 17))
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 620)
        .background(LeatherBackground())
        .interactiveDismissDisabled()
    }
}

private struct UpdatePermissionSheet: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlaqueTitleText(text: "Check for updates?", size: 28)
                .fixedSize()
            note("ProxyPrintGenerator can check its GitHub page for a newer version each time it opens.", 19)
            note("It only asks GitHub for the newest version number. Nothing about you or your decks is sent. If you already have the newest version, you won't see anything. If there's a newer one, the app shows what's new and asks you before it downloads or installs anything.", 17)
            note("You can change this anytime, or check by hand, at the bottom of the Deck Library.", 16)
                .opacity(0.7)
            HStack {
                Spacer()
                Button("No thanks") { updates.answerPermission(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Yes, check for updates") {
                    updates.answerPermission(true)
                }
                .keyboardShortcut(.defaultAction)
            }
            .font(Theme.fellFont(size: 17))
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 620)
        .background(LeatherBackground())
        .interactiveDismissDisabled()
    }
}

private struct UpdateOfferSheet: View {
    let info: UpdateInfo
    @ObservedObject private var updates = UpdateController.shared
    @Environment(\.openURL) private var openURL

    @State private var installing = false
    @State private var fraction: Double = 0
    @State private var status: String?
    @State private var errorText: String?
    @State private var failed = false
    @State private var task: Task<Void, Never>?

    private var canInstall: Bool {
        !failed && Updater.canInstall && info.zipURL != nil
            && info.sha256 != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PlaqueTitleText(text: "Version \(info.version.label) is ready",
                            size: 28)
                .fixedSize()
            note("You have version \(Updater.currentVersion.label).", 17)
                .opacity(0.75)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !info.summary.isEmpty {
                        note(info.summary, 19)
                    }
                    ForEach(info.highlights, id: \.self) { line in
                        note("•  " + line, 17)
                            .padding(.leading, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            Button {
                openURL(info.pageURL)
            } label: {
                Text("Full release notes on GitHub")
                    .font(Theme.fellFont(size: 16))
                    .underline()
                    .foregroundStyle(Theme.gold)
            }
            .buttonStyle(.plain)
            .help(info.pageURL.absoluteString)

            if installing {
                ProgressView(value: fraction)
                    .tint(Theme.gold)
                    .padding(.top, 10)
            }
            if let status {
                note(status, 16).opacity(0.85)
            }
            if let errorText {
                note(errorText, 16)
                    .foregroundStyle(Color(red: 1, green: 0.54, blue: 0.48))
            }
            if !canInstall, !installing,
               let reason = Updater.cannotInstallReason {
                note(reason, 15).opacity(0.7)
                if !AppMover.isDevBuild, !AppMover.isInApplications {
                    Button("Move to Applications, then update") {
                        // Reopens from Applications, where the launch
                        // check (or Check for updates) offers it again.
                        updates.moveToApplications()
                    }
                    if let error = updates.moveError {
                        note(error, 15)
                            .foregroundStyle(Color(red: 1, green: 0.54, blue: 0.48))
                    }
                }
            }

            HStack {
                Button {
                    updates.skip(info)
                } label: {
                    Text("Skip this version")
                        .font(Theme.fellFont(size: 16))
                        .underline()
                        .foregroundStyle(Theme.parchment.opacity(0.75))
                }
                .buttonStyle(.plain)
                .disabled(installing)
                .help("Don't remind me about this version")
                Spacer()
                Button(installing ? "Cancel" : "Not now") {
                    task?.cancel()
                    updates.offer = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(canInstall ? "Update now" : "Get it on GitHub") {
                    updateTapped()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(installing)
            }
            .font(Theme.fellFont(size: 17))
            .padding(.top, 10)
            if canInstall {
                note("Your decks and settings stay as they are. The app restarts when the update is in.", 15)
                    .opacity(0.65)
            }
        }
        .padding(24)
        .frame(width: 660)
        .background(LeatherBackground())
        .interactiveDismissDisabled(installing)
        .onDisappear { task?.cancel() }
    }

    private func updateTapped() {
        guard canInstall else {
            openURL(info.pageURL)
            updates.offer = nil
            return
        }
        installing = true
        errorText = nil
        fraction = 0
        status = "Starting the download…"
        let latest = info.version.label
        let info = info
        task = Task {
            do {
                let app = try await Updater.install(info) { done, total in
                    Task { @MainActor in
                        fraction = Double(done) / Double(max(total, 1))
                        status = String(
                            format: "Downloading version %@: %.0f of %.0f MB",
                            latest, Double(done) / 1_048_576,
                            Double(total) / 1_048_576)
                    }
                }
                status = "Version \(latest) is in. Restarting…"
                try? await Task.sleep(nanoseconds: 500_000_000)
                Updater.relaunch(app)
            } catch is CancellationError {
                installing = false
                status = nil
            } catch {
                installing = false
                status = nil
                failed = true
                errorText = "The update didn't install, and nothing was changed. \(error.localizedDescription)"
            }
        }
    }
}

/// Under the version at the bottom of the Deck Library: check
/// GitHub now, and the launch check switch.
struct UpdateControls: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        VStack(spacing: 6) {
            Button("Check for updates") {
                Task { await updates.check(manual: true) }
            }
            .disabled(updates.checking)
            .help("Ask GitHub whether a newer version is out")
            if let line = updates.manualResult {
                KingdomText(text: line, size: 16)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }
            Toggle(isOn: Binding(
                get: { updates.checkAtStartup },
                set: { updates.setCheckAtStartup($0) })) {
                KingdomText(text: "Check for updates when the app opens",
                            size: 16)
            }
            .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity)
    }
}

private func note(_ text: String, _ size: CGFloat) -> some View {
    Text(text)
        .font(Theme.fellFont(size: size))
        .foregroundStyle(Theme.parchment)
        .fixedSize(horizontal: false, vertical: true)
}
#endif
