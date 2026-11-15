//
//  Updater.swift
//  ProxyPrintGenerator
//
//  Optional updates from this app's GitHub Releases page, mirrored
//  from the Windows build's Updater.cs (Nov 14, 2026). Mac only.
//
//  Nothing is sent until the person allows it: either the launch
//  check they agreed to (UpdateSettings.checkAtStartup) or a click on
//  "Check for updates". A check reads the release list, and only a
//  release newer than this app that carries a Mac zip
//  (ProxyPrintGenerator-<version>-mac.zip) is offered. A Windows-only
//  release is passed over. Only an update the person approves is
//  downloaded, and before it replaces anything:
//    - every request stays on GitHub over HTTPS (redirects included),
//    - the zip must be the size and SHA-256 digest GitHub lists,
//    - the app inside must be this app (same bundle identifier, and
//      the same signing team when this copy has one), carry the
//      version the release names, and pass a code signature check.
//  Then the new ProxyPrintGenerator.app is swapped in for the running
//  one, in the same folder, and the app relaunches into it.
//
//  This needs the app outside the App Sandbox (a sandboxed app can't
//  replace its own bundle), and somewhere it can write: /Applications
//  is fine for an admin account. A copy macOS runs from a randomized
//  read-only spot (App Translocation, for an app opened straight out
//  of Downloads) can't update itself and offers the download page.
//

import Foundation
#if os(macOS)
import AppKit
import CryptoKit
import Security

/// major.minor.patch, compared numerically.
nonisolated struct AppVersion: Comparable, Hashable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    /// "v1.64.0", "1.64" or "1.62.01" as major.minor.patch.
    init?(_ text: String?) {
        var t = (text ?? "").trimmingCharacters(in: .whitespaces)
        while t.first == "v" || t.first == "V" { t.removeFirst() }
        if let cut = t.firstIndex(where: { "+- ".contains($0) }) {
            t = String(t[..<cut])
        }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        major = numbers[0]; minor = numbers[1]; patch = numbers[2]
    }

    var label: String { "\(major).\(minor).\(patch)" }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// A newer release: its version, what's new, and the zip to install.
nonisolated struct UpdateInfo: Identifiable, Sendable {
    let version: AppVersion
    let summary: String
    let highlights: [String]
    let pageURL: URL
    let zipURL: URL?
    let zipSize: Int64
    let sha256: String?
    var id: String { version.label }
}

/// Whether to check at launch (nil until the person has been asked),
/// and a version they chose to skip. Saved beside decks.json.
nonisolated struct UpdateSettings: Codable {
    var checkAtStartup: Bool?
    var skippedVersion: String?
    /// "Don't ask again" on the Move to Applications prompt, for the
    /// copy at this path only: a new download asks again. (An earlier
    /// build kept a neverOfferMove that silenced every copy for good;
    /// it's no longer read, and drops out the next time this saves.)
    var declinedMovePath: String?

    private static var fileURL: URL {
        AppData.folder.appendingPathComponent("updates.json")
    }

    static func load() -> UpdateSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(UpdateSettings.self,
                                                from: data)
        else { return UpdateSettings() }
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: AppData.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

nonisolated struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

nonisolated enum Updater {
    static let repository = "kommermail/ProxyPrintGenerator"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    private static let releasesAPI = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!

    private static let maxAPIBytes = 4 * 1024 * 1024
    private static let maxZipBytes: Int64 = 512 * 1024 * 1024
    static let appName = "ProxyPrintGenerator.app"
    static let assetSuffix = "-mac.zip"

    /// This app's version, from its bundle.
    static var currentVersion: AppVersion {
        AppVersion(Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? AppVersion("0.0.0")!
    }

    /// Where updates are unpacked; cleared at every launch.
    private static var workFolder: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyPrintGenerator-update")
    }

    // MARK: - Can this copy replace itself?

    /// Why this copy can't install updates itself, or nil when it
    /// can. A copy that can't still offers the download page.
    static var cannotInstallReason: String? {
        let app = Bundle.main.bundleURL
        let path = app.path
        if isSandboxed {
            return "This build runs in the App Sandbox, which keeps it from replacing itself."
        }
        if path.contains("/AppTranslocation/") {
            return "macOS is running this copy from a temporary spot. Drag ProxyPrintGenerator into your Applications folder, open it from there, and it can update itself."
        }
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") {
            return "This copy was built by Xcode, so it isn't replaced. Download the new version from GitHub instead."
        }
        if app.pathExtension != "app" {
            return "This copy isn't an app bundle, so it can't replace itself."
        }
        let parent = app.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: parent)
            || !FileManager.default.isWritableFile(atPath: path) {
            return "The app can't write to its folder (\(parent)), so it can't update itself there. Move it to your Applications folder, or download the new version from GitHub."
        }
        return nil
    }

    static var canInstall: Bool { cannotInstallReason == nil }

    private static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    // MARK: - Network (GitHub over HTTPS only)

    /// github.com, api.github.com, and GitHub's download hosts
    /// (*.githubusercontent.com), over HTTPS.
    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
            || host.hasSuffix(".githubusercontent.com")
    }

    /// Refuses any redirect that would leave GitHub or HTTPS.
    private final class GitHubOnly: NSObject, URLSessionTaskDelegate,
                                    @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(Updater.isAllowed(request.url) ? request : nil)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.httpAdditionalHeaders = [
            "User-Agent": "ProxyPrintGenerator-mac/\(currentVersion.label)",
        ]
        return URLSession(configuration: config, delegate: GitHubOnly(),
                          delegateQueue: nil)
    }()

    private static func failure(_ status: Int) -> UpdateError {
        switch status {
        case 403, 429:
            return UpdateError("GitHub is limiting checks from your network right now. Try again in an hour.")
        default:
            return UpdateError("GitHub answered \(status).")
        }
    }

    // MARK: - Check

    /// The newest release with a Mac zip, when it is newer than this
    /// app; otherwise nil.
    static func check() async throws -> UpdateInfo? {
        #if DEBUG
        if let test = try testUpdate() { return test }
        #endif
        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json",
                         forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28",
                         forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              isAllowed(http.url) else {
            throw UpdateError("GitHub's reply came from somewhere else, so it was not used.")
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw failure(http.statusCode)
        }
        guard data.count <= maxAPIBytes else {
            throw UpdateError("GitHub's reply was far bigger than expected, so it was not used.")
        }
        let releases = try JSONDecoder().decode([GitHubRelease].self,
                                                from: data)
        let current = currentVersion
        let best = releases
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { release -> (AppVersion, GitHubRelease, GitHubAsset)? in
                guard let v = AppVersion(release.tagName), v > current,
                      let zip = release.assets?.first(where: {
                          $0.name.lowercased().hasSuffix(assetSuffix)
                      })
                else { return nil }
                return (v, release, zip)
            }
            .max { $0.0 < $1.0 }
        guard let (version, release, zip) = best else { return nil }

        var digest: String? = nil
        if let d = zip.digest, d.lowercased().hasPrefix("sha256:") {
            digest = String(d.dropFirst("sha256:".count)).lowercased()
        }
        let (summary, highlights) = parseNotes(release.body)
        let page = URL(string: release.htmlURL ?? "")
            .flatMap { isAllowed($0) ? $0 : nil } ?? releasesPage
        let zipURL = URL(string: zip.browserDownloadURL ?? "")
            .flatMap { isAllowed($0) ? $0 : nil }
        return UpdateInfo(version: version, summary: summary,
                          highlights: highlights, pageURL: page,
                          zipURL: zipURL, zipSize: zip.size,
                          sha256: digest)
    }

    /// The release notes' first line, and the bold lead of each
    /// bullet under its own headings (New, Fixed, Also), leaving out
    /// the sections every release repeats (Is it safe?, Check your
    /// download). The same reading as the Windows build.
    static func parseNotes(_ body: String?) -> (String, [String]) {
        let lines = (body ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var summary = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        if summary.lowercased().hasPrefix("**download") { summary = "" }
        var highlights: [String] = []
        var include = false
        for line in lines {
            if line.hasPrefix("#") {
                let heading = line.trimmingCharacters(
                    in: CharacterSet(charactersIn: "# ")).lowercased()
                include = !heading.contains("safe")
                    && !heading.contains("download")
                continue
            }
            guard include, line.hasPrefix("- ") || line.hasPrefix("* ")
            else { continue }
            var item = String(line.dropFirst(2))
                .trimmingCharacters(in: .whitespaces)
            if item.hasPrefix("**"),
               let end = item.range(of: "**",
                                    range: item.index(item.startIndex,
                                                      offsetBy: 2)..<item.endIndex) {
                item = String(item[item.index(item.startIndex,
                                              offsetBy: 2)..<end.lowerBound])
            }
            let text = plainText(item)
            if !text.isEmpty { highlights.append(text) }
            if highlights.count == 8 { break }
        }
        return (plainText(summary), highlights)
    }

    private static func plainText(_ s: String) -> String {
        s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#,
                               with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Install

    /// Downloads and checks the release zip, then swaps the new app in
    /// for the running one. Returns the app to relaunch.
    static func install(
        _ info: UpdateInfo,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        if let reason = cannotInstallReason { throw UpdateError(reason) }
        guard let zipURL = info.zipURL else {
            throw UpdateError("That release has no Mac zip to install.")
        }
        guard let sha = info.sha256, sha.count == 64 else {
            throw UpdateError("GitHub didn't list a checksum for that download, so it wasn't installed.")
        }
        guard info.zipSize > 0, info.zipSize <= maxZipBytes else {
            throw UpdateError("That download isn't a size the app expects, so it wasn't installed.")
        }

        let fm = FileManager.default
        try? fm.removeItem(at: workFolder)
        try fm.createDirectory(at: workFolder,
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workFolder) }

        let zipPath = workFolder.appendingPathComponent(
            "ProxyPrintGenerator-\(info.version.label)-mac.zip")
        try await download(zipURL, to: zipPath, size: info.zipSize,
                           sha256: sha, progress: progress)
        try Task.checkCancellation()

        let unpacked = workFolder.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zipPath.path, unpacked.path],
                failure: "The download couldn't be unpacked, so nothing was changed.")
        let fresh = try findApp(in: unpacked)
        try verify(fresh, version: info.version)
        // Files this app downloads aren't quarantined, but a zip made
        // on another Mac may carry the flag inside; clear it so the
        // relaunch isn't stopped by Gatekeeper.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", fresh.path],
                     failure: "")
        try Task.checkCancellation()
        return try swapIn(fresh)
    }

    private static func download(
        _ url: URL, to destination: URL, size: Int64, sha256: String,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        #if DEBUG
        if url.isFileURL {
            try FileManager.default.copyItem(at: url, to: destination)
            let data = try Data(contentsOf: destination)
            progress(Int64(data.count), size)
            let got = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
            guard Int64(data.count) == size, got == sha256 else {
                throw UpdateError("The test zip doesn't match its checksum.")
            }
            return
        }
        #endif
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream",
                         forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              isAllowed(http.url) else {
            throw UpdateError("The download came from somewhere other than GitHub, so it wasn't installed.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw failure(http.statusCode)
        }
        if http.expectedContentLength > 0,
           http.expectedContentLength != size {
            throw UpdateError("The download isn't the size GitHub lists for it, so it wasn't installed.")
        }
        FileManager.default.createFile(atPath: destination.path,
                                       contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var hasher = SHA256()
        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        var done: Int64 = 0
        var lastPercent = -1
        func flush() throws {
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        for try await byte in bytes {
            buffer.append(byte)
            done += 1
            if buffer.count >= 256 * 1024 {
                if done > size {
                    throw UpdateError("The download is bigger than GitHub lists for it, so it wasn't installed.")
                }
                try flush()
                try Task.checkCancellation()
                let percent = Int(done * 100 / size)
                if percent != lastPercent {
                    lastPercent = percent
                    progress(done, size)
                }
            }
        }
        try flush()
        progress(done, size)
        guard done == size else {
            throw UpdateError("The download ended early. Check your connection and try again.")
        }
        let got = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard got == sha256 else {
            throw UpdateError("The download doesn't match the checksum GitHub lists for it, so it wasn't installed.")
        }
    }

    /// The one ProxyPrintGenerator.app in the unpacked zip, at its
    /// top level or one folder down.
    private static func findApp(in folder: URL) throws -> URL {
        let fm = FileManager.default
        let direct = folder.appendingPathComponent(appName)
        if fm.fileExists(atPath: direct.path) { return direct }
        let children = (try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            let nested = child.appendingPathComponent(appName)
            if fm.fileExists(atPath: nested.path) { return nested }
        }
        throw UpdateError("The download has no \(appName) in it, so nothing was changed.")
    }

    /// The new app must be this app, at the version the release
    /// names, with an intact code signature from the same team.
    private static func verify(_ app: URL, version: AppVersion) throws {
        guard let bundle = Bundle(url: app) else {
            throw UpdateError("The downloaded app can't be read, so it wasn't installed.")
        }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download isn't ProxyPrintGenerator, so it wasn't installed.")
        }
        let stamped = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard AppVersion(stamped) == version else {
            throw UpdateError("The downloaded app says it is version \(stamped ?? "unknown"), not \(version.label), so it wasn't installed.")
        }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(
                code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures
                                 | kSecCSStrictValidate), nil) == errSecSuccess
        else {
            throw UpdateError("The downloaded app's signature is damaged, so it wasn't installed.")
        }
        if let mine = teamIdentifier(of: Bundle.main.bundleURL) {
            guard teamIdentifier(of: app) == mine else {
                throw UpdateError("The downloaded app was signed by someone else, so it wasn't installed.")
            }
        }
    }

    private static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation),
                &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Moves the new app beside the running one, then swaps them, so
    /// the running app is replaced in one step. The old copy goes to
    /// the Trash.
    private static func swapIn(_ fresh: URL) throws -> URL {
        let fm = FileManager.default
        let installed = Bundle.main.bundleURL
        let parent = installed.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(
            ".ProxyPrintGenerator-update-\(UUID().uuidString).app")
        do {
            try fm.copyItem(at: fresh, to: staged)
        } catch {
            throw UpdateError("The app can't write to its folder (\(parent.path)), so it can't update itself there. Download the new version from GitHub instead.")
        }
        do {
            var trashed: NSURL?
            let backup = parent.appendingPathComponent(
                ".ProxyPrintGenerator-old-\(UUID().uuidString).app")
            try fm.moveItem(at: installed, to: backup)
            do {
                try fm.moveItem(at: staged, to: installed)
            } catch {
                try? fm.moveItem(at: backup, to: installed)
                throw error
            }
            if (try? fm.trashItem(at: backup,
                                  resultingItemURL: &trashed)) == nil {
                try? fm.removeItem(at: backup)
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw UpdateError("The new version couldn't be moved into place, so nothing was changed. \(error.localizedDescription)")
        }
        return installed
    }

    /// Opens the app at `url` once this process has quit, then quits.
    @MainActor static func relaunch(_ url: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, url.path]
        try? helper.run()
        // An open sheet (the update or move window) keeps AppKit from
        // quitting, which left the old copy running and the new one
        // never opened. Close the sheets, ask to quit, and if the app is
        // still here a moment later, exit: decks and settings are
        // already saved, each time they change.
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        NSApp.terminate(nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { exit(0) }
    }

    /// At launch: removes anything a half finished update left.
    static func cleanUpAfterUpdate() {
        try? FileManager.default.removeItem(at: workFolder)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String],
                            failure: String) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 && !failure.isEmpty {
            throw UpdateError(failure)
        }
        return p.terminationStatus
    }

    #if DEBUG
    /// Debug builds only: PPG_UPDATE_TEST_ZIP (a local -mac.zip) and
    /// PPG_UPDATE_TEST_VERSION stand in for a GitHub release, so the
    /// download, checks, swap and relaunch can be tried without
    /// publishing anything.
    private static func testUpdate() throws -> UpdateInfo? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PPG_UPDATE_TEST_ZIP"],
              let version = AppVersion(env["PPG_UPDATE_TEST_VERSION"]),
              version > currentVersion else { return nil }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let sha = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        return UpdateInfo(version: version, summary: "Local test update.",
                          highlights: [], pageURL: releasesPage,
                          zipURL: url, zipSize: Int64(data.count),
                          sha256: sha)
    }
    #endif

    private struct GitHubRelease: Decodable {
        let tagName: String?
        let htmlURL: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [GitHubAsset]?
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", htmlURL = "html_url", body, draft,
                 prerelease, assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let size: Int64
        let digest: String?
        let browserDownloadURL: String?
        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }
}
#endif

/// The folder the app keeps decks and settings in:
/// ~/Library/Application Support/ProxyPrint.
nonisolated enum AppData {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("ProxyPrint")
    }

    #if os(macOS)
    /// Builds before Nov 14, 2026 ran in the App Sandbox, which kept
    /// decks in the app's container. The first unsandboxed launch
    /// copies that folder to the normal place (copies, never moves,
    /// so the old copy stays as a backup). Does nothing once the
    /// normal folder has a decks.json.
    static func migrateFromSandboxContainer() {
        let fm = FileManager.default
        let decks = folder.appendingPathComponent("decks.json")
        guard !fm.fileExists(atPath: decks.path),
              let id = Bundle.main.bundleIdentifier else { return }
        let old = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(id)/Data/Library/Application Support/ProxyPrint")
        guard old.standardizedFileURL != folder.standardizedFileURL,
              fm.fileExists(atPath: old.appendingPathComponent("decks.json").path)
        else { return }
        try? fm.createDirectory(at: folder,
                                withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(
            at: old, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            let target = folder.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: target.path) {
                try? fm.copyItem(at: item, to: target)
            }
        }
    }
    #endif
}
