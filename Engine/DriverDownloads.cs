// DriverDownloads.cs
// "Get the driver for me": downloads a printer maker's own driver
// installer and runs it, only when the person clicks, and only after
// four checks that don't depend on any one party:
//
//   1. The driver must be listed in drivers.json in this app's GitHub
//      repository, which names the exact file: its download address,
//      size and SHA-256 checksum. Nothing is fetched from GitHub until
//      the person clicks, so the app still connects to nothing on its
//      own.
//   2. The download address must be on that maker's own download
//      server, over HTTPS, every redirect included. The servers are
//      written into the app, not taken from the list.
//   3. The file must be exactly the size and checksum the list names.
//   4. The installer must carry a valid Windows code signature
//      (Authenticode) from that maker, by the publisher name written
//      into the app: "Canon Inc.", "Seiko Epson Corporation"...
//
// Then the maker's installer runs as the maker built it, and Windows
// shows its own administrator prompt for it. The app never installs
// anything itself. Nov 15, 2026.

using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ProxyPrintGenerator.Engine;

public sealed record PrinterMaker(string Name, string[] Aliases, string[] Publishers, string[] Hosts, string? DriverPage);

/// One driver from drivers.json.
public sealed class DriverPackage
{
    [JsonPropertyName("maker")] public string Maker { get; set; } = "";
    [JsonPropertyName("models")] public List<string> Models { get; set; } = [];
    /// The driver's name once installed, as Windows lists it.
    [JsonPropertyName("driver")] public string Driver { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("url")] public string Url { get; set; } = "";
    [JsonPropertyName("size")] public long Size { get; set; }
    [JsonPropertyName("sha256")] public string Sha256 { get; set; } = "";

    public string Host => Uri.TryCreate(Url, UriKind.Absolute, out var u) ? u.IdnHost : "";
}

public static class DriverDownloads
{
    public const string ManifestUrl = "https://raw.githubusercontent.com/kommermail/ProxyPrintGenerator/main/drivers.json";

    /// The printer makers the app recognizes, written into the app: the
    /// names a printer may go by, the publisher names on their Windows
    /// code signing certificates, their download servers (for drivers.json
    /// entries) and their driver page (opened in the web browser).
    /// An installer counts as a real printer maker's only when Windows
    /// trusts its signature and the certificate names one of these
    /// publishers; certificate authorities verify that name before they
    /// issue the certificate, so nobody else can carry it.
    public static readonly PrinterMaker[] PrinterMakers =
    [
        new("Canon", ["Canon"], ["Canon Inc."], ["gdlp01.c-wss.com"], "https://www.usa.canon.com/support/software-and-drivers"),
        new("Epson", ["Epson", "Seiko Epson"], ["Seiko Epson Corporation"], ["ftp.epson.com", "download.ebz.epson.net", "download3.ebz.epson.net"], "https://epson.com/Support/sl/s"),
        new("HP", ["HP", "Hewlett-Packard", "Hewlett Packard", "Samsung"], ["HP Inc.", "HP Inc", "Hewlett-Packard Company", "Hewlett Packard Enterprise Company"], ["ftp.hp.com", "ftp.ext.hp.com"], "https://support.hp.com/drivers"),
        new("Brother", ["Brother"], ["Brother Industries, Ltd.", "Brother Industries Ltd."], ["download.brother.com"], "https://support.brother.com/g/b/productsearch.aspx"),
        new("Xerox", ["Xerox", "Fuji Xerox", "FUJIFILM"], ["Xerox Corporation", "FUJIFILM Business Innovation Corp."], [], "https://www.support.xerox.com"),
        new("Lexmark", ["Lexmark"], ["Lexmark International, Inc.", "Lexmark International Inc."], [], "https://support.lexmark.com"),
        new("Kyocera", ["Kyocera"], ["KYOCERA Document Solutions Inc."], [], "https://www.kyoceradocumentsolutions.com/download/"),
        new("Ricoh", ["Ricoh"], ["Ricoh Company, Ltd.", "RICOH COMPANY, LTD."], [], "https://support.ricoh.com"),
        new("Sharp", ["Sharp"], ["Sharp Corporation"], [], "https://global.sharp/business/print/"),
        new("Konica Minolta", ["Konica", "Konica Minolta"], ["Konica Minolta, Inc.", "KONICA MINOLTA, INC."], [], "https://www.konicaminolta.com/global-en/support/"),
        new("OKI", ["OKI"], ["Oki Electric Industry Co., Ltd.", "OKI Data Corporation"], [], "https://www.oki.com/printing/support/"),
        new("Pantum", ["Pantum"], ["Zhuhai Pantum Electronics Co., Ltd."], [], "https://global.pantum.com/support/"),
    ];

    /// The maker a printer or model name belongs to ("HP DeskJet 2800"
    /// is HP), or null.
    public static PrinterMaker? MakerFor(string name)
    {
        var n = name.Trim();
        return PrinterMakers.FirstOrDefault(m => m.Aliases.Any(a =>
            n.StartsWith(a + " ", StringComparison.OrdinalIgnoreCase) || n.Equals(a, StringComparison.OrdinalIgnoreCase)));
    }

    private const long MaxManifestBytes = 512 * 1024;
    private const long MaxInstallerBytes = 1024L * 1024 * 1024;

    private static string WorkFolder => Path.Combine(ProxyPrintEngine.AppDataRoot, "drivers");

    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.All,
    })
    { Timeout = Timeout.InfiniteTimeSpan };

    // MARK: - The list

    /// The listed driver for a printer model, or null. Reads drivers.json
    /// from GitHub: called only when the person clicks.
    public static async Task<DriverPackage?> FindAsync(string model, CancellationToken ct)
    {
        using var resp = await GetAsync(ManifestUrl, h => h.Equals("raw.githubusercontent.com", StringComparison.OrdinalIgnoreCase), ct);
        if (resp.StatusCode == HttpStatusCode.NotFound) return null;
        if (!resp.IsSuccessStatusCode) throw new PpgException($"GitHub answered {(int)resp.StatusCode} for the driver list.");
        var bytes = await ReadLimitedAsync(resp.Content, MaxManifestBytes, ct);
        var list = JsonSerializer.Deserialize<DriverList>(bytes);
        return list?.Drivers.FirstOrDefault(d => Valid(d) && d.Models.Any(m => Views.PrinterDrivers.SameModel(m, model)));
    }

    /// An entry the app may use: a known maker, an HTTPS address on that
    /// maker's server, a sane size and a full checksum.
    public static bool Valid(DriverPackage d) =>
        MakerFor(d.Maker) is { } maker
        && Uri.TryCreate(d.Url, UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps
        && maker.Hosts.Contains(u.IdnHost, StringComparer.OrdinalIgnoreCase)
        && d.Size is > 0 and <= MaxInstallerBytes
        && d.Sha256.Length == 64 && d.Sha256.All(Uri.IsHexDigit)
        && d.Driver.Length is > 0 and < 200
        && Path.GetExtension(u.AbsolutePath).ToLowerInvariant() is ".exe" or ".msi";

    private sealed class DriverList
    {
        [JsonPropertyName("drivers")] public List<DriverPackage> Drivers { get; set; } = [];
    }

    // MARK: - Download and check

    /// Downloads the installer and checks its size, checksum and
    /// signature. Returns the checked file's path.
    public static async Task<string> DownloadAsync(DriverPackage d, IProgress<(long Done, long Total)>? progress, CancellationToken ct)
    {
        if (!Valid(d)) throw new PpgException("That driver entry didn't pass the app's checks, so nothing was downloaded.");
        var maker = MakerFor(d.Maker)!;
        var hosts = maker.Hosts;
        Directory.CreateDirectory(WorkFolder);
        var ext = Path.GetExtension(new Uri(d.Url).AbsolutePath).ToLowerInvariant();
        var path = Path.Combine(WorkFolder, $"{d.Sha256[..16]}{ext}");
        try
        {
            using var resp = await GetAsync(d.Url, h => hosts.Contains(h, StringComparer.OrdinalIgnoreCase), ct);
            if (!resp.IsSuccessStatusCode) throw new PpgException($"{d.Maker}'s server answered {(int)resp.StatusCode}.");
            if (resp.Content.Headers.ContentLength is { } len && len != d.Size)
                throw new PpgException("The download isn't the size the driver list names, so it wasn't used.");
            await using (var body = await resp.Content.ReadAsStreamAsync(ct))
            await using (var file = File.Create(path))
            {
                using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                var buffer = new byte[81920];
                long done = 0;
                int n;
                while ((n = await body.ReadAsync(buffer, ct)) > 0)
                {
                    done += n;
                    if (done > d.Size) throw new PpgException("The download is bigger than the driver list says, so it wasn't used.");
                    sha.AppendData(buffer, 0, n);
                    await file.WriteAsync(buffer.AsMemory(0, n), ct);
                    progress?.Report((done, d.Size));
                }
                if (done != d.Size) throw new PpgException("The download ended early. Check your connection and try again.");
                if (!Convert.ToHexString(sha.GetHashAndReset()).Equals(d.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new PpgException("The download doesn't match the checksum in the driver list, so it wasn't used.");
            }
            if (SignedByMaker(path) != maker)
                throw new PpgException($"The installer isn't signed by {maker.Name}, so it wasn't run.");
            return path;
        }
        catch
        {
            TryDelete(path);
            throw;
        }
    }

    /// Runs the maker's installer and waits for it. Windows shows its own
    /// administrator prompt; the installer then does its own setup.
    public static async Task<int> RunInstallerAsync(string path, PrinterMaker maker)
    {
        // Checked again right before it runs.
        if (SignedByMaker(path) != maker) throw new PpgException($"The installer isn't signed by {maker.Name}, so it wasn't run.");
        var start = Path.GetExtension(path).Equals(".msi", StringComparison.OrdinalIgnoreCase)
            ? new ProcessStartInfo("msiexec.exe") { UseShellExecute = true, ArgumentList = { "/i", path } }
            : new ProcessStartInfo(path) { UseShellExecute = true };
        Process? proc;
        try { proc = Process.Start(start); }
        catch (System.ComponentModel.Win32Exception e) when (e.NativeErrorCode == 1223)
        { throw new PpgException("Windows didn't get permission, so the driver wasn't installed."); }
        if (proc == null) throw new PpgException("The installer didn't start.");
        await proc.WaitForExitAsync();
        return proc.ExitCode;
    }

    public static void CleanUp()
    {
        try { if (Directory.Exists(WorkFolder)) Directory.Delete(WorkFolder, true); } catch { }
    }

    // MARK: - Code signature

    /// The printer maker whose valid, Windows-trusted Authenticode
    /// signature the file carries, or null: the signing certificate's
    /// organization (or common name) must be one of a maker's publishers.
    public static PrinterMaker? SignedByMaker(string path)
    {
        var publisher = TrustedPublisher(path);
        if (publisher == null) return null;
        static string Norm(string s) => s.Trim().TrimEnd('.').Replace(",", "").ToUpperInvariant();
        return PrinterMakers.FirstOrDefault(m => m.Publishers.Any(p => Norm(p) == Norm(publisher)));
    }

    /// Who signed the file, when Windows trusts the signature: the
    /// certificate's organization, else its common name. Null when the
    /// file is unsigned, altered, or signed by an untrusted certificate.
    public static string? TrustedPublisher(string path)
    {
        if (!VerifyTrust(path)) return null;
        try
        {
#pragma warning disable SYSLIB0057
            using var cert = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
            var org = cert.SubjectName.EnumerateRelativeDistinguishedNames()
                .Where(r => r.GetSingleElementType().FriendlyName == "O")
                .Select(r => r.GetSingleElementValue()).FirstOrDefault();
            return org ?? cert.GetNameInfo(X509NameType.SimpleName, false);
        }
        catch { return null; }
    }

    private static bool VerifyTrust(string path)
    {
        var file = new WINTRUST_FILE_INFO
        {
            cbStruct = (uint)Marshal.SizeOf<WINTRUST_FILE_INFO>(),
            pcwszFilePath = path,
        };
        var filePtr = Marshal.AllocHGlobal(Marshal.SizeOf<WINTRUST_FILE_INFO>());
        try
        {
            Marshal.StructureToPtr(file, filePtr, false);
            var data = new WINTRUST_DATA
            {
                cbStruct = (uint)Marshal.SizeOf<WINTRUST_DATA>(),
                dwUIChoice = 2,            // WTD_UI_NONE
                // No online revocation check, which would reach out to
                // certificate servers; the chain must still lead to a
                // root Windows trusts, and the file must be unaltered.
                fdwRevocationChecks = 0,   // WTD_REVOKE_NONE
                dwUnionChoice = 1,         // WTD_CHOICE_FILE
                pFile = filePtr,
                dwStateAction = 0,         // WTD_STATEACTION_IGNORE
                dwProvFlags = 0,
            };
            var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE"); // WINTRUST_ACTION_GENERIC_VERIFY_V2
            return WinVerifyTrust(IntPtr.Zero, ref action, ref data) == 0;
        }
        finally
        {
            Marshal.DestroyStructure<WINTRUST_FILE_INFO>(filePtr);
            Marshal.FreeHGlobal(filePtr);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WINTRUST_FILE_INFO
    {
        public uint cbStruct;
        public string pcwszFilePath;
        public IntPtr hFile;
        public IntPtr pgKnownSubject;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WINTRUST_DATA
    {
        public uint cbStruct;
        public IntPtr pPolicyCallbackData;
        public IntPtr pSIPClientData;
        public uint dwUIChoice;
        public uint fdwRevocationChecks;
        public uint dwUnionChoice;
        public IntPtr pFile;
        public uint dwStateAction;
        public IntPtr hWVTStateData;
        public IntPtr pwszURLReference;
        public uint dwProvFlags;
        public uint dwUIContext;
        public IntPtr pSignatureSettings;
    }

    [DllImport("wintrust.dll", CharSet = CharSet.Unicode)]
    private static extern int WinVerifyTrust(IntPtr hwnd, ref Guid pgActionID, ref WINTRUST_DATA pWVTData);

    // MARK: - HTTPS with checked redirects

    private static async Task<HttpResponseMessage> GetAsync(string url, Func<string, bool> hostAllowed, CancellationToken ct)
    {
        var uri = new Uri(url);
        for (var hop = 0; hop <= 5; hop++)
        {
            if (uri.Scheme != Uri.UriSchemeHttps || !hostAllowed(uri.IdnHost))
                throw new UnsafeResponseException($"Refused to download from {uri.Host}: drivers only come from the maker's own server over HTTPS.");
            using var req = new HttpRequestMessage(HttpMethod.Get, uri);
            req.Headers.UserAgent.ParseAdd($"ProxyPrintGenerator/{Updater.Label(Updater.CurrentVersion)}");
            using var headers = CancellationTokenSource.CreateLinkedTokenSource(ct);
            headers.CancelAfter(TimeSpan.FromSeconds(30));
            var resp = await Client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, headers.Token);
            if ((int)resp.StatusCode is >= 300 and < 400 && resp.Headers.Location is { } next)
            {
                resp.Dispose();
                uri = next.IsAbsoluteUri ? next : new Uri(uri, next);
                continue;
            }
            return resp;
        }
        throw new PpgException("The server redirected too many times.");
    }

    private static async Task<byte[]> ReadLimitedAsync(HttpContent content, long max, CancellationToken ct)
    {
        await using var stream = await content.ReadAsStreamAsync(ct);
        using var ms = new MemoryStream();
        var buffer = new byte[16384];
        int n;
        while ((n = await stream.ReadAsync(buffer, ct)) > 0)
        {
            if (ms.Length + n > max) throw new UnsafeResponseException("The driver list was far bigger than expected, so it was not used.");
            ms.Write(buffer, 0, n);
        }
        return ms.ToArray();
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}
