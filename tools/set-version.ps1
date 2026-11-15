# set-version.ps1: sets the version for both apps at once, on the PC.
#
#   powershell -ExecutionPolicy Bypass -File tools\set-version.ps1 1.65.0
#
# Writes <Version> in ProxyPrintGenerator.csproj (Windows) and the app's
# MARKETING_VERSION in mac\ProxyPrintGenerator.xcodeproj (Mac). The Mac's
# twin is tools/set-version.sh. Commit and push afterwards.

param([Parameter(Mandatory)] [string] $Version)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Use major.minor.patch, like 1.65.0" }
$root = Split-Path -Parent $PSScriptRoot

$csproj = Join-Path $root 'ProxyPrintGenerator.csproj'
$text = [IO.File]::ReadAllText($csproj)
$text = [regex]::Replace($text, '<Version>[^<]*</Version>', "<Version>$Version</Version>")
[IO.File]::WriteAllText($csproj, $text)

# The app target's version; the test targets stay at 1.0.
$xc = Join-Path $root 'mac\ProxyPrintGenerator.xcodeproj\project.xcproj'
$text = [IO.File]::ReadAllText($xc)
$text = [regex]::Replace($text, '"MARKETING_VERSION": "(?!1\.0")[^"]*"', "`"MARKETING_VERSION`": `"$Version`"")
[IO.File]::WriteAllText($xc, $text)

Write-Host "Both apps are now $Version. Commit and push."
