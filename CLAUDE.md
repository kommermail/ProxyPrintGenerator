# ProxyPrintGenerator

One app, two builds, one repository, worked on from two computers:

| | Windows app | Mac app |
|---|---|---|
| Code | C# / WPF at the repo root (`Engine/`, `Views/`, `Controls/`, `*.xaml`) | Swift / SwiftUI in `mac/` (`mac/ProxyPrintGenerator/`, engine in `mac/MyTool/`) |
| Built on | the Windows PC | the Mac |
| Release script | `publish.ps1 -Upload` | `mac/publish-mac.sh --upload` |

The two apps mirror each other: a feature added to one usually belongs in the other (comments say "Mirrored from the Mac app" / "Windows build" with a date). When you change one, say whether the other needs the same change.

## The two computers

Both computers have a git clone of `github.com/kommermail/ProxyPrintGenerator`. GitHub is the only place they meet, so:

1. **Before starting**, get the other computer's work: `git pull`
2. **When done**, send yours: `git add -A`, `git commit -m "what changed"`, `git push`
3. **Never** upload files or edit the version through GitHub's website. The other computer won't know about it, and the next pull stops with "Your local changes would be overwritten".

Where the clones are:
- **Mac:** `~/development/proxyprintgenerator/ProxyPrintGenerator-github`. The old Xcode folder next to it (`~/development/proxyprintgenerator/ProxyPrintGenerator`) is an earlier, unconnected copy; don't work there.
- **PC:** the folder `publish.ps1` is run from.

If `git pull` stops because of local changes, don't discard them: `git stash push --include-untracked -m "why"`, pull, then look at what was set aside (`git stash list`) before dropping anything. A stash can be turned into a branch to push and merge: `git stash branch some-name 'stash@{0}'`.

### Windows PowerShell gotchas (the PC)
- `&&` doesn't work in Windows PowerShell 5.1. Give PC commands one per line, or join them with `;`.
- Braces are code in PowerShell: quote git references like `'stash@{0}'`.
- Repo scripts run with `powershell -ExecutionPolicy Bypass -File <script>.ps1`. That only lets Windows run this repo's own scripts; users never need it.
- A program's stderr, when redirected, becomes a PowerShell error, which `$ErrorActionPreference = 'Stop'` makes fatal. Check a native command's exit code without redirecting its stderr into the error stream (see `Test-Gh` in `publish.ps1`).

## Building and checking

**Windows app, on the PC:** `dotnet build`, then run it.

**Windows app, on the Mac (compiles only; WPF can't run on a Mac):**
```
dotnet build ProxyPrintGenerator.csproj -p:EnableWindowsTargeting=true -o /tmp/ppg-winbuild
rm -rf bin obj
```
Say plainly when Windows code was only compiled, not run.

**Mac app, on the Mac:** the command line tools are selected instead of Xcode, so point at Xcode:
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project mac/ProxyPrintGenerator.xcodeproj -scheme ProxyPrintGenerator -configuration Debug build
```
The Xcode project is the new folder-based format: new `.swift` files in `mac/ProxyPrintGenerator/` join the app by themselves. The project also lists iOS, whose build was already broken (older code in `PrintJobModel.swift`); the Mac build is what ships.

**Mac Debug-only self-tests** (launch with `open -n --env NAME=value <app>`, so the app is its own process and can read its data):
- `PPG_UPDATE_SELFTEST_LOG=<file>`: logs a live update check; with `PPG_UPDATE_TEST_ZIP=<zip>` and `PPG_UPDATE_TEST_VERSION=<x.y.z>` it installs that local zip and relaunches, without GitHub.
- `PPG_PRINT_SELFTEST_LOG=<file>`: logs every printer, its driver, presets and advice. Add `PPG_SETUP_SELFTEST=1` for the Set it up for me plan and the safety checks; `PPG_PRINT_HOLD=1` with `PPG_PRINT_SELFTEST_PDF=<pdf>` sends a job that waits on hold (cancel it with `cancel <job>`), so nothing prints.

## Versions and releases

Both apps carry the same version number, and a release holds both zips.

1. Set it everywhere at once: Mac `./tools/set-version.sh 1.65.0`, PC `powershell -ExecutionPolicy Bypass -File tools\set-version.ps1 1.65.0`. Commit and push; pull on the other computer.
2. PC: `powershell -ExecutionPolicy Bypass -File publish.ps1 -Upload` builds the Windows zip and attaches it to release `v<version>`, making a draft release if there isn't one.
3. Mac: `./mac/publish-mac.sh --upload` adds the Mac zip to the same release.
4. On GitHub, write the notes and click Publish. Publishing runs the Windows release check, and both apps' update checks start offering it.

Both apps read the release notes in their update window: the first line is the summary, and the bold lead of each `- **Bullet**` under a heading is a highlight. Headings with "safe" or "download" in them are left out. Keep the "Is it safe?" and "Check your download" sections (with each zip's SHA-256) from earlier releases. The app updaters look for `ProxyPrintGenerator-<version>-win-x64.zip` and `ProxyPrintGenerator-<version>-mac.zip`; keep those names.

The GitHub CLI (`gh`) is signed in on both computers for the upload steps.

## Promises the app makes (keep them true)

These are in both readmes; change the readmes if the behavior changes.
- **Network:** Scryfall for card data. GitHub only for update checks the person allowed, or a click on Check for updates. On Windows, a printer maker's download server only on a Get the driver for me click, and only for an installer listed in `drivers.json`. Everything else (driver pages, Ko-fi, Moxfield) opens in the web browser. Downloads are HTTPS with every redirect checked against an allowlist written into the app.
- **Installing:** the apps update themselves only when asked, after checking the size and SHA-256 GitHub lists (Mac: also the bundle ID, version and code signature team). A printer driver installer runs only if Windows trusts its Authenticode signature and the publisher is one of the printer makers in `DriverDownloads.PrinterMakers`, and only on a click.
- **Printers:** Set it up for me adds a printer only after asking (Windows: UAC). Every value comes from the system's own discovery and is re-checked; commands run without a shell.
- **No personal data** is collected or sent.

## Notes

- The Mac app is not sandboxed (a sandboxed app can't replace itself to update). Decks live in `~/Library/Application Support/ProxyPrint/`; the first unsandboxed launch copied them over from the old sandbox container.
- `drivers.json` is optional: every printer works without an entry. `tools/add-driver.ps1` is a developer tool for adding one; users never run it.
- Windows 11 sets most home printers up with Microsoft's IPP Class Driver, and a Mac with AirPrint. Both are generic. Installing a maker's driver never changes printers already added, which is why the apps offer Set it up for me.
- Liam reads replies in the Claude desktop app and runs PC commands by hand: give PowerShell-safe commands, one per block.
