# publish.ps1
# Builds the release: one self-contained ProxyPrintGenerator.exe (no .NET
# install needed) plus a zip ready to attach to a GitHub release.
#
#   powershell -ExecutionPolicy Bypass -File publish.ps1           build the zip
#   powershell -ExecutionPolicy Bypass -File publish.ps1 -Upload   build it and attach it to release v<version>
#
# -Upload needs the GitHub CLI, signed in once: winget install GitHub.cli,
# then gh auth login. It replaces a Windows zip of the same name already on
# the release. If there's no release v<version> yet, it makes a draft one
# (the Mac script, mac/publish-mac.sh --upload, attaches to the same
# release); write the notes and publish it on GitHub. Publishing starts
# the release check and lets the apps' update checks see it.
#
# Keep <Version> in ProxyPrintGenerator.csproj the same as the Mac app's
# version (Xcode: target > General > Version).

param([switch] $Upload)

$ErrorActionPreference = 'Stop'

# Runs a gh command only for its exit code. Windows PowerShell turns
# anything a program writes to stderr into an error when it's redirected,
# which 'Stop' then makes fatal; "release not found" is a normal answer.
function Test-Gh([string[]] $GhArgs) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & gh @GhArgs 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
    return ($LASTEXITCODE -eq 0)
}
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$version = ([xml](Get-Content "$here\ProxyPrintGenerator.csproj")).Project.PropertyGroup.Version | Select-Object -First 1
$out = Join-Path $here "..\release\ProxyPrintGenerator"
$zip = Join-Path $here "..\release\ProxyPrintGenerator-$version-win-x64.zip"

if ($Upload) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "Install the GitHub CLI first: winget install GitHub.cli, then gh auth login" }
    if (-not (Test-Gh @('auth', 'status'))) { throw "Sign in to GitHub first: gh auth login" }
}

# A fresh output folder, so nothing from an older build ends up in the zip.
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
dotnet publish "$here\ProxyPrintGenerator.csproj" -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true -p:DebugType=none -o $out
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

Copy-Item "$here\READ ME.txt" $out -Force
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path "$out\*" -DestinationPath $zip
Write-Host "Built $zip"
Write-Host ("SHA-256 " + (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant())

if ($Upload) {
    $repo = 'kommermail/ProxyPrintGenerator'
    $tag = "v$version"
    if (Test-Gh @('release', 'view', $tag, '-R', $repo)) {
        gh release upload $tag $zip -R $repo --clobber
        if ($LASTEXITCODE -ne 0) { throw "Upload failed" }
        Write-Host "Attached to release ${tag}: https://github.com/$repo/releases/tag/$tag"
    }
    else {
        gh release create $tag $zip -R $repo --draft --target main `
            --title "ProxyPrintGenerator $version" `
            --notes "ProxyPrintGenerator $version for Windows and Mac."
        if ($LASTEXITCODE -ne 0) { throw "Making the release failed" }
        Write-Host "Made a draft release $tag with the Windows zip. Write the notes, then publish it:"
        Write-Host "  https://github.com/$repo/releases"
    }
}
