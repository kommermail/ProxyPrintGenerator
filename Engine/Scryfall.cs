// Scryfall.cs
// Scryfall API access, ported from ScryfallClient.swift and
// PrintingsClient.swift:
//   - bulk identifiers lookup (POST /cards/collection, batches of 50)
//   - named lookup (GET /cards/named?exact=) for name-only lines
//   - printing search for the picker, free search for replace/add
//   - PNG face URL selection, including card_faces for two sided cards
//
// Every request carries a browser style User-Agent: the image CDN
// (cards.scryfall.io) drops connections from custom agents.

using System.Net;
using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ProxyPrintGenerator.Engine;

public sealed class PpgException(string message) : Exception(message);

/// One exact printing: (set, collector number), set lowercased and any
/// leading '#' stripped from the number.
public readonly record struct PrintingKey
{
    public string Set { get; }
    public string CollectorNumber { get; }
    public PrintingKey(string set, string collectorNumber)
    {
        Set = set.ToLowerInvariant();
        var n = collectorNumber.Trim();
        if (n.StartsWith('#')) n = n[1..].Trim();
        CollectorNumber = n;
    }
}

public sealed class ImageUris
{
    [JsonPropertyName("png")] public string? Png { get; set; }
    [JsonPropertyName("large")] public string? Large { get; set; }
    [JsonPropertyName("normal")] public string? Normal { get; set; }
    [JsonPropertyName("small")] public string? Small { get; set; }
}

public sealed class CardFace
{
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("image_uris")] public ImageUris? ImageUris { get; set; }
}

public enum FaceImageQuality { Small, Normal, Large }

/// A Scryfall card object (used both by the engine and the selector).
public sealed class ScryfallCard
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("set")] public string Set { get; set; } = "";
    [JsonPropertyName("collector_number")] public string CollectorNumber { get; set; } = "";
    [JsonPropertyName("layout")] public string Layout { get; set; } = "";
    [JsonPropertyName("type_line")] public string? TypeLine { get; set; }
    [JsonPropertyName("mana_cost")] public string? ManaCost { get; set; }
    [JsonPropertyName("image_uris")] public ImageUris? ImageUris { get; set; }
    [JsonPropertyName("card_faces")] public List<CardFace>? CardFaces { get; set; }

    public string Id => $"{Set}|{CollectorNumber}";
    public string SetAndNumber => $"{Set.ToUpperInvariant()} {CollectorNumber}";

    /// True when this printing has a real back face to flip to.
    public bool HasBackFace => ScryfallClient.TwoSidedLayouts.Contains(Layout) && (CardFaces?.Count ?? 0) > 1;

    public string? DisplayImageUrl => FaceImageUrl(0, FaceImageQuality.Normal);

    /// Image for one face (0 front, 1 back).
    public string? FaceImageUrl(int faceIndex, FaceImageQuality quality = FaceImageQuality.Large)
    {
        ImageUris? uris;
        if (CardFaces != null && faceIndex < CardFaces.Count && CardFaces[faceIndex].ImageUris != null)
            uris = CardFaces[faceIndex].ImageUris;
        else if (faceIndex == 0)
            uris = ImageUris ?? CardFaces?.FirstOrDefault()?.ImageUris;
        else
            uris = null;
        if (uris == null) return null;
        return quality switch
        {
            FaceImageQuality.Small => uris.Small ?? uris.Normal ?? uris.Large ?? uris.Png,
            FaceImageQuality.Normal => uris.Normal ?? uris.Large ?? uris.Png,
            _ => uris.Large ?? uris.Normal ?? uris.Png,
        };
    }
}

/// Shared retrying transport. Retries transport failures and 429/5xx.
public static class ScryfallTransport
{
    public const string BrowserUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36";

    public static readonly HttpClient Client = Create();

    private static HttpClient Create()
    {
        var handler = new SocketsHttpHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            MaxConnectionsPerServer = 8,
        };
        var c = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(180) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd(BrowserUserAgent);
        c.DefaultRequestHeaders.Accept.ParseAdd("*/*");
        return c;
    }

    /// Sends with retries; baseDelay * (attempt+1) seconds between tries.
    public static async Task<(byte[] Data, HttpStatusCode Status)> SendAsync(
        Func<HttpRequestMessage> makeRequest, int attempts, double baseDelay, CancellationToken ct)
    {
        Exception? last = null;
        for (var attempt = 0; attempt < attempts; attempt++)
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                using var req = makeRequest();
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cts.CancelAfter(TimeSpan.FromSeconds(60));
                using var resp = await Client.SendAsync(req, cts.Token).ConfigureAwait(false);
                var code = (int)resp.StatusCode;
                if (code == 429 || code >= 500)
                    last = new PpgException($"HTTP {code} for {req.RequestUri}");
                else
                    return (await resp.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false), resp.StatusCode);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception e) { last = e; }
            if (attempt < attempts - 1)
                await Task.Delay(TimeSpan.FromSeconds(baseDelay * (attempt + 1)), ct).ConfigureAwait(false);
        }
        throw last ?? new PpgException("Request failed.");
    }

    public static Task<(byte[] Data, HttpStatusCode Status)> GetAsync(string url, int attempts, double baseDelay, CancellationToken ct)
        => SendAsync(() => new HttpRequestMessage(HttpMethod.Get, url), attempts, baseDelay, ct);
}

public static class ScryfallClient
{
    /// Layouts that truly print a back face.
    public static readonly HashSet<string> TwoSidedLayouts = ["transform", "modal_dfc", "reversible_card"];

    public const string CardBackImageUrl = "https://cards.scryfall.io/back.png";

    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

    private sealed class CollectionResponse
    {
        [JsonPropertyName("data")] public List<ScryfallCard> Data { get; set; } = [];
        [JsonPropertyName("not_found")] public List<Dictionary<string, JsonElement>> NotFound { get; set; } = [];
    }

    private sealed class SearchPage
    {
        [JsonPropertyName("data")] public List<ScryfallCard> Data { get; set; } = [];
        [JsonPropertyName("has_more")] public bool HasMore { get; set; }
        [JsonPropertyName("next_page")] public string? NextPage { get; set; }
    }

    /// Looks up exact printings in batches of 50. With strict set, throws
    /// if Scryfall reports any identifier as not found.
    public static async Task<Dictionary<PrintingKey, ScryfallCard>> LookupPrintingsAsync(
        IReadOnlyList<PrintingKey> keys, bool strict, CancellationToken ct)
    {
        var output = new Dictionary<PrintingKey, ScryfallCard>();
        for (var index = 0; index < keys.Count; index += 50)
        {
            var batch = keys.Skip(index).Take(50).ToList();
            var body = new { identifiers = batch.Select(k => new { set = k.Set, collector_number = k.CollectorNumber }) };
            var (data, status) = await ScryfallTransport.SendAsync(() => new HttpRequestMessage(HttpMethod.Post,
                "https://api.scryfall.com/cards/collection") { Content = JsonContent.Create(body) }, 4, 3, ct).ConfigureAwait(false);
            if (status != HttpStatusCode.OK)
                throw new PpgException($"[PPG:CARD-LOOKUP] Scryfall collection lookup failed: HTTP {(int)status}");
            var decoded = JsonSerializer.Deserialize<CollectionResponse>(data, Json)!;
            foreach (var card in decoded.Data)
                output[new PrintingKey(card.Set, card.CollectorNumber)] = card;
            if (strict && decoded.NotFound.Count > 0)
            {
                var nf = decoded.NotFound[0];
                string Get(string k) => nf.TryGetValue(k, out var v) ? v.ToString() : "?";
                throw new PpgException($"[PPG:CARD-LOOKUP] Scryfall could not find: ({Get("set")}) {Get("collector_number")}");
            }
            if (index + 50 < keys.Count) await Task.Delay(300, ct).ConfigureAwait(false);
        }
        return output;
    }

    /// Resolves a name-only line to a concrete printing.
    public static async Task<ScryfallCard> LookupNamedAsync(string name, string? set, CancellationToken ct, int maxAttempts = 6)
    {
        // Politeness pause: a deck of bare names would otherwise burst.
        await Task.Delay(150, ct).ConfigureAwait(false);
        var url = "https://api.scryfall.com/cards/named?exact=" + Uri.EscapeDataString(name)
                  + (set != null ? "&set=" + Uri.EscapeDataString(set) : "");
        var (data, status) = await ScryfallTransport.GetAsync(url, maxAttempts, 4, ct).ConfigureAwait(false);
        if (status == HttpStatusCode.NotFound)
            throw new PpgException($"[PPG:CARD-LOOKUP] Scryfall could not find a card named: {name}");
        if (status != HttpStatusCode.OK)
            throw new PpgException($"[PPG:CARD-LOOKUP] Scryfall named lookup failed: HTTP {(int)status}");
        return JsonSerializer.Deserialize<ScryfallCard>(data, Json)!;
    }

    /// PNG scan URLs for every printable face: two for a true two sided
    /// card (front, back), one for everything else.
    public static List<string> FacePngUrls(ScryfallCard card)
    {
        List<string?> strings = TwoSidedLayouts.Contains(card.Layout) && card.CardFaces is { Count: > 0 }
            ? card.CardFaces.Select(f => f.ImageUris?.Png).ToList()
            : [card.ImageUris?.Png];
        var result = new List<string>();
        for (var i = 0; i < strings.Count; i++)
        {
            if (string.IsNullOrEmpty(strings[i]))
                throw new PpgException($"[PPG:FACE-URL] No PNG image for {card.Name} face {i}");
            result.Add(strings[i]!);
        }
        return result;
    }

    private static async Task<List<ScryfallCard>> SearchAsync(string query, string unique, string? order,
        int maxPages, int maxResults, bool notFoundIsEmpty, CancellationToken ct)
    {
        var url = "https://api.scryfall.com/cards/search?q=" + Uri.EscapeDataString(query) + "&unique=" + unique
                  + (order != null ? "&order=" + order : "");
        var options = new List<ScryfallCard>();
        var pages = 0;
        string? next = url;
        while (next != null && pages < maxPages && options.Count < maxResults)
        {
            if (pages > 0) await Task.Delay(150, ct).ConfigureAwait(false);
            var (data, status) = await ScryfallTransport.GetAsync(next, 4, 3, ct).ConfigureAwait(false);
            if (status == HttpStatusCode.NotFound && notFoundIsEmpty) return options;
            if (status != HttpStatusCode.OK)
                throw new PpgException($"Scryfall search failed: HTTP {(int)status}");
            var page = JsonSerializer.Deserialize<SearchPage>(data, Json)!;
            options.AddRange(page.Data);
            next = page.HasMore ? page.NextPage : null;
            pages++;
        }
        return options;
    }

    /// All printings of the named card, oldest first.
    public static Task<List<ScryfallCard>> AllPrintingsAsync(string cardName, CancellationToken ct = default)
        => SearchAsync($"!\"{cardName}\"", "prints", "released", 20, int.MaxValue, false, ct);

    /// Free form card search for the replace / add sheets, capped at 150.
    public static Task<List<ScryfallCard>> SearchCardsAsync(string query, CancellationToken ct = default)
        => SearchAsync(query, "cards", "name", 3, 150, true, ct);

    /// Resolves many names in a few OR-query searches.
    public static async Task<Dictionary<string, ScryfallCard>> ResolveByNamesAsync(IReadOnlyList<string> names, CancellationToken ct = default)
    {
        var output = new Dictionary<string, ScryfallCard>(StringComparer.OrdinalIgnoreCase);
        for (var start = 0; start < names.Count; start += 20)
        {
            if (start > 0) await Task.Delay(150, ct).ConfigureAwait(false);
            var q = string.Join(" or ", names.Skip(start).Take(20).Select(n => $"name:\"{n}\""));
            foreach (var card in await SearchAsync(q, "cards", null, 5, int.MaxValue, true, ct).ConfigureAwait(false))
                output[card.Name] = card;
        }
        return output;
    }
}
