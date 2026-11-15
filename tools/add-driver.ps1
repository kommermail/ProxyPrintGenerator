# add-driver.ps1
# Developer tool: the app's users never run this. Every printer works
# without a list entry (the app opens the maker's page, finds the
# download in the Downloads folder and checks the maker's signature);
# an entry only makes "Get the driver for me" download by itself.
#
# Adds a printer driver to drivers.json, the list the Windows app's
# "Get the driver for me" button may download from. Run it on Windows:
#
#   powershell -ExecutionPolicy Bypass -File tools\add-driver.ps1 `
#       -Maker Canon -Models "Canon MB5400 series" `
#       -Url "https://gdlp01.c-wss.com/gds/.../mb54-win-....exe" `
#       -Title "MB5400 series MP Drivers"
#
# It downloads the installer once, and only writes the entry if the
# address is on the maker's own server and the file carries a valid
# signature from that maker, the same checks the app makes. The entry
# pins the file's size and SHA-256, so the app downloads exactly this
# file and nothing else. Commit and push drivers.json afterwards.
#
# -Driver is the driver's name once installed, as Windows lists it
# (Settings > Printers & scanners > Print server properties > Drivers);
# it defaults to the first model name.

param(
    [Parameter(Mandatory)] [ValidateSet('Canon', 'Epson', 'Brother', 'HP')] [string] $Maker,  # makers with download servers in DriverDownloads.PrinterMakers
    [Parameter(Mandatory)] [string[]] $Models,
    [Parameter(Mandatory)] [string] $Url,
    [string] $Driver = '',
    [string] $Title = ''
)
$ErrorActionPreference = 'Stop'

# Keep these the same as DriverDownloads.Makers in Engine\DriverDownloads.cs.
$makers = @{
    Canon   = @{ Hosts = @('gdlp01.c-wss.com'); Publisher = 'Canon Inc.' }
    Epson   = @{ Hosts = @('ftp.epson.com', 'download.ebz.epson.net', 'download3.ebz.epson.net'); Publisher = 'Seiko Epson Corporation' }
    Brother = @{ Hosts = @('download.brother.com'); Publisher = 'Brother Industries, Ltd.' }
    HP      = @{ Hosts = @('ftp.hp.com', 'ftp.ext.hp.com'); Publisher = 'HP Inc.' }
}
$m = $makers[$Maker]
$uri = [Uri]$Url
if ($uri.Scheme -ne 'https') { throw "The address must be https." }
if ($m.Hosts -notcontains $uri.Host) { throw "$($uri.Host) isn't one of $Maker's download servers the app accepts: $($m.Hosts -join ', ')." }
$ext = [IO.Path]::GetExtension($uri.AbsolutePath).ToLowerInvariant()
if ($ext -notin '.exe', '.msi') { throw "The app only runs .exe or .msi installers." }

$file = Join-Path $env:TEMP ("ppg-driver" + $ext)
Write-Host "Downloading $Url"
Invoke-WebRequest -Uri $Url -OutFile $file -UseBasicParsing -MaximumRedirection 5

$sig = Get-AuthenticodeSignature $file
if ($sig.Status -ne 'Valid') { throw "The installer's signature isn't valid ($($sig.Status))." }
$subject = $sig.SignerCertificate.Subject
if ($subject -notmatch ('(^|, )(O|CN)=' + [regex]::Escape($m.Publisher) + '(,|$)') -and
    $subject -notmatch ('(^|, )(O|CN)="' + [regex]::Escape($m.Publisher) + '"(,|$)')) {
    throw "The installer is signed by '$subject', not $($m.Publisher)."
}

$entry = [ordered]@{
    maker  = $Maker
    models = @($Models)
    driver = $(if ($Driver) { $Driver } else { $Models[0] })
    title  = $Title
    url    = $Url
    size   = (Get-Item $file).Length
    sha256 = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
}
Remove-Item $file

$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'drivers.json'
$list = Get-Content $path -Raw | ConvertFrom-Json
$kept = @($list.drivers | Where-Object { $_.url -ne $Url })
$list.drivers = @($kept) + [pscustomobject]$entry
$list | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding utf8
Write-Host "Added $($entry.driver): $($entry.size) bytes, sha256 $($entry.sha256), signed by $($m.Publisher)."
Write-Host "Commit and push drivers.json so the app can find it."
