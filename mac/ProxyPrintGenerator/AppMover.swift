//
//  AppMover.swift
//  ProxyPrintGenerator
//
//  "Move to Applications" (Nov 15, 2026). An app opened straight from
//  Downloads after a browser download is run by macOS from a hidden,
//  read-only copy (App Translocation), so Update now can't replace it.
//  The person then fetches every new version in the browser, and each
//  browser download needs approving in System Settings again.
//
//  So at launch, a copy that isn't in an Applications folder offers to
//  move itself there and reopen. From Applications, Update now installs
//  new versions itself, and macOS doesn't ask about files an app
//  downloads on its own.
//
//  The moved copy has its "downloaded from the internet" flag cleared.
//  That isn't skipping a check: this exact app is already running, which
//  means the person has already approved it.
//

#if os(macOS)
import Foundation
import AppKit
import Security

nonisolated enum AppMover {

    private static var current: URL { Bundle.main.bundleURL }

    /// Run by macOS from a hidden read-only copy.
    static var isTranslocated: Bool { current.path.contains("/AppTranslocation/") }

    /// Built by Xcode: never moved.
    static var isDevBuild: Bool {
        let p = current.path
        return p.contains("/DerivedData/") || p.contains("/Build/Products/")
    }

    /// Already in /Applications or ~/Applications (or a folder inside one).
    static var isInApplications: Bool {
        guard !isTranslocated else { return false }
        let p = current.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix("/Applications/") || p.hasPrefix(home + "/Applications/")
    }

    /// Whether to offer the move: a copy outside Applications that isn't
    /// an Xcode build, unless the person said not to ask again.
    static var shouldOffer: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PPG_MOVE_TEST_DEST"] != nil { return !isInDestination }
        #endif
        return !isDevBuild && !isInApplications && UpdateSettings.load().neverOfferMove != true
    }

    /// Where the app goes: /Applications when this account can write
    /// there (admins can), else ~/Applications.
    static var destinationFolder: URL {
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["PPG_MOVE_TEST_DEST"] {
            return URL(fileURLWithPath: test)
        }
        #endif
        if FileManager.default.isWritableFile(atPath: "/Applications") {
            return URL(fileURLWithPath: "/Applications")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    private static var isInDestination: Bool {
        current.deletingLastPathComponent().standardizedFileURL.path
            == destinationFolder.standardizedFileURL.path
    }

    /// Copies the app into the Applications folder, replacing an older
    /// copy there (which goes to the Trash), and moves the downloaded
    /// copy to the Trash. Returns the new copy to reopen.
    static func move() throws -> URL {
        let fm = FileManager.default
        let folder = destinationFolder
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(Updater.appName)
        let staged = folder.appendingPathComponent(".ProxyPrintGenerator-moving-\(UUID().uuidString).app")

        // Copy first, so nothing is lost if anything below fails.
        do {
            try fm.copyItem(at: current, to: staged)
        } catch {
            throw UpdateError("The app couldn't copy itself into \(folder.path). Drag ProxyPrintGenerator there in Finder instead.")
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        guard Bundle(url: staged)?.bundleIdentifier == Bundle.main.bundleIdentifier,
              signatureIsValid(staged) else {
            try? fm.removeItem(at: staged)
            throw UpdateError("The copy didn't check out, so nothing was moved.")
        }

        // An older copy already in Applications goes to the Trash.
        if fm.fileExists(atPath: target.path) {
            do {
                try fm.trashItem(at: target, resultingItemURL: nil)
            } catch {
                try? fm.removeItem(at: staged)
                throw UpdateError("There's already a ProxyPrintGenerator in \(folder.path) that the app couldn't replace. Quit it if it's open, or drag this one there in Finder.")
            }
        }
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            try? fm.removeItem(at: staged)
            throw UpdateError("The app couldn't finish moving into \(folder.path). Drag it there in Finder instead.")
        }

        // The downloaded copy goes to the Trash (the real file, not the
        // hidden read-only copy macOS ran it from).
        if let original = originalLocation(), original.standardizedFileURL != target.standardizedFileURL {
            try? fm.trashItem(at: original, resultingItemURL: nil)
        }
        return target
    }

    /// The app's real location: for a translocated copy, the file in
    /// Downloads macOS is running it for.
    static func originalLocation() -> URL? {
        guard isTranslocated else { return current }
        typealias CreateOriginal = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let create = unsafeBitCast(sym, to: CreateOriginal.self)
        return create(current as CFURL, nil)?.takeRetainedValue() as URL?
    }

    private static func signatureIsValid(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
#endif
