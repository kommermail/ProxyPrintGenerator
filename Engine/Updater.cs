// Updater.cs
// Optional updates from this app's GitHub Releases page.
//
// Nothing is sent until the person allows it: either the launch check
// they agreed to (UpdateSettings.CheckAtStartup) or a click on "Check for
// updates". A check reads only the latest release's version number, and
// only a version newer than this one is offered. Only an update the
// person approves is downloaded, and before it replaces anything:
//   - every request stays on GitHub over HTTPS (redirects included),
//   - the zip must be the size and SHA-256 digest GitHub lists for it,
//   - the exe inside must carry the version the release names.
// Windows lets a running exe be renamed but not overwritten, so the new
// exe is unpacked beside the old one, the old one is renamed out of the
// way, and the app restarts into the new one. The renamed old exe is
// deleted on the next launch.

using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace ProxyPrintGenerator.Engine;

/// A newer release: its version, what's new, and the zip to install.
public sealed record UpdateInfo(
    Version Version, string Summary, IReadOnlyList<string> Highlights, string PageUrl,
    string? ZipUrl, long ZipSize, string? Sha256);

/// Whether to check at launch (null until the person has been asked),
/// and a version they chose to skip.
public sealed class UpdateSettings
{
    public bool? CheckAtStartup { get; set; }
    public string? SkippedVersion { get; set; }

    private static string FilePath => Path.Combine(
        Environment.GetEnvironmentVariable("PPG_DATA_DIR") is { Length: > 0 } custom ? custom
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ProxyPrintGenerator"),
        "updates.json");

    public static UpdateSettings Load()
    {
        try { return JsonSerializer.Deserialize<UpdateSettings>(File.ReadAllText(FilePath)) ?? new(); }
        catch { return new(); }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this));
        }
        catch { /* best effort */ }
    }
}

public static partial class Updater
{
    public const string Repository = "kommermail/ProxyPrintGenerator";
    public const string ReleasesPage = $"https://github.com/{Repository}/releases/latest";
    private const string LatestReleaseApi = $"https://api.github.com/repos/{Repository}/releases/latest";

    private const long MaxApiBytes = 2L * 1024 * 1024;
    private const long MaxZipBytes = 512L * 1024 * 1024;
    private const string ExeName = "ProxyPrintGenerator.exe";

    /// This app's version, as major.minor.patch.
    public static Version CurrentVersion { get; } = Normalize(Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0, 0));

    public static string Label(Version v) => v.ToString(3);

    /// The running exe, when it is the published single file build: the
    /// only kind that can swap itself out. A build run from source has
    /// its ProxyPrintGenerator.dll beside the exe and is left alone.
    private static string? InstalledExe =>
        Environment.ProcessPath is { Length: > 0 } exe
        && !File.Exists(Path.Combine(Path.GetDirectoryName(exe)!, "ProxyPrintGenerator.dll"))
            ? exe : null;

    public static bool CanInstall => InstalledExe != null;

    private static string WorkFolder => Path.Combine(ProxyPrintEngine.AppDataRoot, "update");

    // MARK: - Network (GitHub over HTTPS only)

    private static readonly HttpClient Client = CreateClient();

    private static HttpClient CreateClient()
    {
        var handler = new SocketsHttpHandler
        {
            // Redirects are followed by hand so each hop can be checked.
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        };
        var c = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        c.DefaultRequestHeaders.UserAgent.ParseAdd($"ProxyPrintGenerator/{Label(CurrentVersion)}");
        return c;
    }

    /// github.com, api.github.com, and GitHub's download host
    /// (release-assets.githubusercontent.com), over HTTPS.
    public static bool IsAllowed(Uri? uri)
    {
        if (uri is not { IsAbsoluteUri: true } || uri.Scheme != Uri.UriSchemeHttps) return false;
        var host = uri.IdnHost;
        return host.Equals("github.com", StringComparison.OrdinalIgnoreCase)
            || host.EndsWith(".github.com", StringComparison.OrdinalIgnoreCase)
            || host.EndsWith(".githubusercontent.com", StringComparison.OrdinalIgnoreCase);
    }

    /// A GET whose every hop, redirects included, stays on GitHub over HTTPS.
    private static async Task<HttpResponseMessage> GetAsync(string url, string accept, CancellationToken ct)
    {
        var uri = new Uri(url);
        for (var hop = 0; hop <= 5; hop++)
        {
            if (!IsAllowed(uri))
                throw new UnsafeResponseException($"[PPG:BLOCKED-URL] Refused to download from {uri}: updates only come from GitHub over HTTPS.");
            using var req = new HttpRequestMessage(HttpMethod.Get, uri);
            req.Headers.Accept.ParseAdd(accept);
            if (uri.IdnHost.Equals("api.github.com", StringComparison.OrdinalIgnoreCase))
                req.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
            using var headers = CancellationTokenSource.CreateLinkedTokenSource(ct);
            headers.CancelAfter(TimeSpan.FromSeconds(30));
            HttpResponseMessage resp;
            try { resp = await Client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, headers.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new PpgException("GitHub took too long to answer."); }
            if ((int)resp.StatusCode is >= 300 and < 400 && resp.Headers.Location is { } next)
            {
                resp.Dispose();
                uri = next.IsAbsoluteUri ? next : new Uri(uri, next);
                continue;
            }
            return resp;
        }
        throw new PpgException("GitHub redirected too many times.");
    }

    private static async Task<byte[]> ReadLimitedAsync(HttpContent content, long max, CancellationToken ct)
    {
        if (content.Headers.ContentLength > max) throw new UnsafeResponseException("[PPG:TOO-BIG] GitHub's reply was far bigger than expected, so it was not used.");
        await using var stream = await content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        using var ms = new MemoryStream();
        var buffer = new byte[81920];
        int n;
        while ((n = await stream.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
        {
            if (ms.Length + n > max) throw new UnsafeResponseException("[PPG:TOO-BIG] GitHub's reply was far bigger than expected, so it was not used.");
            ms.Write(buffer, 0, n);
        }
        return ms.ToArray();
    }

    private static PpgException HttpFailure(HttpResponseMessage resp) => (int)resp.StatusCode switch
    {
        403 or 429 => new PpgException("GitHub is limiting checks from your network right now. Try again in an hour."),
        _ => new PpgException($"GitHub answered {(int)resp.StatusCode} {resp.ReasonPhrase}."),
    };

    // MARK: - Check

    /// The latest release when it is newer than this app; otherwise null.
    public static async Task<UpdateInfo?> CheckAsync(CancellationToken ct)
    {
        using var resp = await GetAsync(LatestReleaseApi, "application/vnd.github+json", ct).ConfigureAwait(false);
        if (resp.StatusCode == HttpStatusCode.NotFound) return null; // no releases yet
        if (!resp.IsSuccessStatusCode) throw HttpFailure(resp);
        var release = JsonSerializer.Deserialize<GitHubRelease>(await ReadLimitedAsync(resp.Content, MaxApiBytes, ct).ConfigureAwait(false));
        if (release is null || release.Draft || release.Prerelease) return null;
        if (!TryParseVersion(release.TagName, out var latest) || latest <= CurrentVersion) return null;

        var zip = release.Assets?.FirstOrDefault(a => a.Name.EndsWith("-win-x64.zip", StringComparison.OrdinalIgnoreCase));
        var digest = zip?.Digest is { } d && d.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) ? d["sha256:".Length..] : null;
        var (summary, highlights) = ParseNotes(release.Body);
        var page = Uri.TryCreate(release.HtmlUrl, UriKind.Absolute, out var p) && IsAllowed(p) ? p.ToString() : ReleasesPage;
        return new UpdateInfo(latest, summary, highlights, page, zip?.BrowserDownloadUrl, zip?.Size ?? 0, digest);
    }

    /// "v1.60.0" or "1.60" as major.minor.patch.
    public static bool TryParseVersion(string? text, out Version version)
    {
        version = new Version(0, 0, 0);
        var t = (text ?? "").Trim().TrimStart('v', 'V');
        var plus = t.IndexOfAny(['+', '-', ' ']);
        if (plus >= 0) t = t[..plus];
        if (!Version.TryParse(t, out var v)) return false;
        version = Normalize(v);
        return true;
    }

    private static Version Normalize(Version v) => new(v.Major, v.Minor, Math.Max(0, v.Build));

    /// The release notes' first line, and the bold lead of each bullet
    /// under its own headings (New, Fixed, Also), leaving out the
    /// sections every release repeats (Is it safe?, Check your download).
    public static (string Summary, List<string> Highlights) ParseNotes(string? body)
    {
        var lines = (body ?? "").Replace("\r\n", "\n").Split('\n');
        var summary = lines.Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0 && !l.StartsWith('#')) ?? "";
        if (summary.StartsWith("**Download", StringComparison.OrdinalIgnoreCase)) summary = "";
        var highlights = new List<string>();
        var include = false;
        foreach (var line in lines)
        {
            if (line.StartsWith('#'))
            {
                var heading = line.TrimStart('#').Trim();
                include = !heading.Contains("safe", StringComparison.OrdinalIgnoreCase)
                          && !heading.Contains("download", StringComparison.OrdinalIgnoreCase);
                continue;
            }
            if (!include || !(line.StartsWith("- ") || line.StartsWith("* "))) continue;
            var item = line[2..].Trim();
            var bold = BoldLead().Match(item);
            var text = PlainText(bold.Success ? bold.Groups[1].Value : item);
            if (text.Length > 0) highlights.Add(text);
            if (highlights.Count == 8) break;
        }
        return (PlainText(summary), highlights);
    }

    [GeneratedRegex(@"^\*\*(.+?)\*\*")] private static partial Regex BoldLead();
    [GeneratedRegex(@"\[([^\]]*)\]\([^)]*\)")] private static partial Regex MarkdownLink();

    private static string PlainText(string s)
        => MarkdownLink().Replace(s, "$1").Replace("**", "").Replace("`", "").Trim();

    // MARK: - Install

    /// Downloads and checks the release zip, then swaps the new exe in
    /// for the running one. Returns the exe to start.
    public static async Task<string> InstallAsync(UpdateInfo info, IProgress<(long Done, long Total)>? progress, CancellationToken ct)
    {
        var exe = InstalledExe ?? throw new PpgException("This copy of the app can't update itself. Download the new version from GitHub instead.");
        if (info.ZipUrl == null) throw new PpgException("That release has no Windows zip to install.");
        if (info.Sha256 is not { Length: 64 }) throw new PpgException("GitHub didn't list a checksum for that download, so it wasn't installed.");
        if (info.ZipSize is <= 0 or > MaxZipBytes) throw new PpgException("That download isn't a size the app expects, so it wasn't installed.");

        Directory.CreateDirectory(WorkFolder);
        var zipPath = Path.Combine(WorkFolder, $"ProxyPrintGenerator-{Label(info.Version)}.zip");
        try
        {
            await DownloadAsync(info, zipPath, progress, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            return SwapIn(info, zipPath, exe);
        }
        finally { TryDelete(zipPath); }
    }

    private static async Task DownloadAsync(UpdateInfo info, string zipPath, IProgress<(long Done, long Total)>? progress, CancellationToken ct)
    {
        using var resp = await GetAsync(info.ZipUrl!, "application/octet-stream", ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode) throw HttpFailure(resp);
        if (resp.Content.Headers.ContentLength is { } length && length != info.ZipSize)
            throw new PpgException("The download isn't the size GitHub lists for it, so it wasn't installed.");

        await using var body = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        await using var file = File.Create(zipPath);
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var buffer = new byte[81920];
        long done = 0;
        var lastPercent = -1;
        while (true)
        {
            stall.CancelAfter(TimeSpan.FromSeconds(45));
            int n;
            try { n = await body.ReadAsync(buffer, stall.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new PpgException("The download stopped moving. Check your connection and try again."); }
            if (n == 0) break;
            done += n;
            if (done > info.ZipSize) throw new PpgException("The download is bigger than GitHub lists for it, so it wasn't installed.");
            sha.AppendData(buffer, 0, n);
            await file.WriteAsync(buffer.AsMemory(0, n), ct).ConfigureAwait(false);
            var percent = (int)(done * 100 / info.ZipSize);
            if (percent != lastPercent) { lastPercent = percent; progress?.Report((done, info.ZipSize)); }
        }
        if (done != info.ZipSize) throw new PpgException("The download ended early. Check your connection and try again.");
        if (!Convert.ToHexString(sha.GetHashAndReset()).Equals(info.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new PpgException("The download doesn't match the checksum GitHub lists for it, so it wasn't installed.");
    }

    private static string SwapIn(UpdateInfo info, string zipPath, string exe)
    {
        var folder = Path.GetDirectoryName(exe)!;
        var fresh = exe + ".new";
        using var archive = ZipFile.OpenRead(zipPath);
        var entry = archive.Entries.FirstOrDefault(e => e.FullName.Equals(ExeName, StringComparison.OrdinalIgnoreCase))
            ?? throw new PpgException("The download has no ProxyPrintGenerator.exe in it, so nothing was changed.");
        try { entry.ExtractToFile(fresh, true); }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException)
        {
            TryDelete(fresh);
            throw new PpgException($"The app can't write to its folder ({folder}), so it can't update itself there. Download the new version from GitHub, or move the app to a folder you own, such as Documents.");
        }

        // The exe must be the version the release names.
        var stamped = FileVersionInfo.GetVersionInfo(fresh).FileVersion;
        if (!TryParseVersion(stamped, out var got) || got != info.Version)
        {
            TryDelete(fresh);
            throw new PpgException($"The downloaded app says it is version {stamped ?? "unknown"}, not {Label(info.Version)}, so it wasn't installed.");
        }

        // Rename the running exe out of the way, then move the new one in.
        var old = exe + ".old";
        TryDelete(old);
        if (File.Exists(old)) old = $"{exe}.{Guid.NewGuid():N}.old";
        File.Move(exe, old);
        try { File.Move(fresh, exe); }
        catch
        {
            File.Move(old, exe);
            TryDelete(fresh);
            throw;
        }

        // The read me travels with the app; best effort.
        if (archive.Entries.FirstOrDefault(e => e.FullName.Equals("READ ME.txt", StringComparison.OrdinalIgnoreCase)) is { } readme)
            try { readme.ExtractToFile(Path.Combine(folder, readme.FullName), true); } catch { }
        return exe;
    }

    /// At launch: removes the exe an update replaced (once it has exited)
    /// and any half finished download.
    public static void CleanUpAfterUpdate()
    {
        try { if (Directory.Exists(WorkFolder)) Directory.Delete(WorkFolder, true); } catch { }
        if (InstalledExe is not { } exe) return;
        _ = Task.Run(async () =>
        {
            for (var attempt = 0; attempt < 15; attempt++)
            {
                var left = 0;
                try
                {
                    var folder = Path.GetDirectoryName(exe)!;
                    var name = Path.GetFileName(exe);
                    foreach (var f in Directory.EnumerateFiles(folder, name + "*.old").Concat(Directory.EnumerateFiles(folder, name + ".new")))
                        try { File.Delete(f); } catch { left++; }
                }
                catch { return; }
                if (left == 0) return;
                await Task.Delay(1000).ConfigureAwait(false);
            }
        });
    }

    private static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }

    private sealed class GitHubRelease
    {
        [JsonPropertyName("tag_name")] public string? TagName { get; set; }
        [JsonPropertyName("html_url")] public string? HtmlUrl { get; set; }
        [JsonPropertyName("body")] public string? Body { get; set; }
        [JsonPropertyName("draft")] public bool Draft { get; set; }
        [JsonPropertyName("prerelease")] public bool Prerelease { get; set; }
        [JsonPropertyName("assets")] public List<GitHubAsset>? Assets { get; set; }
    }

    private sealed class GitHubAsset
    {
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("size")] public long Size { get; set; }
        [JsonPropertyName("digest")] public string? Digest { get; set; }
        [JsonPropertyName("browser_download_url")] public string? BrowserDownloadUrl { get; set; }
    }
}
