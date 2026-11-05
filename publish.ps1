# publish.ps1
# Builds the release: one self-contained ProxyPrintGenerator.exe (no .NET
# install needed) plus a zip ready to attach to a GitHub release.
#
#   powershell -ExecutionPolicy Bypass -File publish.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$version = ([xml](Get-Content "$here\ProxyPrintGenerator.csproj")).Project.PropertyGroup.Version | Select-Object -First 1
$out = Join-Path $here "..\release\ProxyPrintGenerator"
$zip = Join-Path $here "..\release\ProxyPrintGenerator-$version-win-x64.zip"

dotnet publish "$here\ProxyPrintGenerator.csproj" -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true -p:DebugType=none -o $out
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

Copy-Item "$here\READ ME.txt" $out -Force
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path "$out\*" -DestinationPath $zip
Write-Host "Built $zip"
