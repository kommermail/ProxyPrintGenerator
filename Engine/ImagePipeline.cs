// ImagePipeline.cs
// Prepares one card face at a time for the page builders, ported from
// ImagePipeline.swift: download the PNG scan (with retries), sample the
// card's own border color, flatten transparency onto that color,
// Lanczos upscale by the scale factor with a gentle unsharp pass, then
// apply ink calibration, midtone lift and vibrance. Every stage is
// cached on disk, so reruns are decode-only.
//
// Memory rule: a PreparedFace is handed to the caller, drawn, and
// released. The pipeline never keeps a deck of upscaled images alive.

using System.IO;
using System.Net;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ProxyPrintGenerator.Engine;

/// 8 bit RGB color.
public readonly record struct RgbColor(int R, int G, int B);

/// Per channel ink compensation. A factor above 1 deepens that ink.
public readonly record struct InkCalibration(double Cyan, double Magenta, double Yellow)
{
    public static readonly InkCalibration None = new(1, 1, 1);
    public bool IsIdentity => Cyan == 1 && Magenta == 1 && Yellow == 1;

    /// channel' = 255 - min(255, (255 - v) * f)
    public RgbColor Boosted(RgbColor c)
    {
        static int Boost(int v, double f) => f == 1 ? v : 255 - Math.Min(255, (int)Math.Round((255 - v) * f));
        return new RgbColor(Boost(c.R, Cyan), Boost(c.G, Magenta), Boost(c.B, Yellow));
    }
}

/// A packed RGB24 image (3 bytes per pixel, rows tightly packed).
public sealed class RgbImage(int width, int height, byte[] pixels)
{
    public int Width { get; } = width;
    public int Height { get; } = height;
    public byte[] Pixels { get; } = pixels;
    public int Stride => Width * 3;
}

public sealed class PreparedFace(RgbImage image, RgbColor borderColor)
{
    public RgbImage Image { get; } = image;
    /// The sampled border color, NOT yet calibration boosted.
    public RgbColor BorderColor { get; } = borderColor;
}

public sealed class ImagePipeline(string cacheDirectory, InkCalibration calibration,
    double vibrance = 0, double midtoneLift = 0)
{
    private static string F(double v) => v.ToString("0.######", System.Globalization.CultureInfo.InvariantCulture);

    public async Task<PreparedFace> PrepareFaceAsync(string url, string set, string collector,
        int faceIndex, int scale, CancellationToken ct)
    {
        Directory.CreateDirectory(cacheDirectory);
        static string Safe(string s) => string.Concat(s.Select(ch => Path.GetInvalidFileNameChars().Contains(ch) || ch == '.' ? '_' : ch));
        var baseStem = $"{Safe(set)}_{Safe(collector)}_f{faceIndex}_x{scale}";
        var destStem = baseStem;
        if (!calibration.IsIdentity) destStem += $"_c{F(calibration.Cyan)}_m{F(calibration.Magenta)}_y{F(calibration.Yellow)}";
        if (vibrance > 0) destStem += $"_v{F(vibrance)}";
        if (midtoneLift > 0) destStem += $"_l{F(midtoneLift)}";

        var dest = Path.Combine(cacheDirectory, destStem + ".png");
        var destMeta = Path.Combine(cacheDirectory, destStem + ".json");
        var cached = LoadCached(dest, destMeta);
        if (cached != null) return cached;

        var basePath = Path.Combine(cacheDirectory, baseStem + ".png");
        var baseMeta = Path.Combine(cacheDirectory, baseStem + ".json");

        RgbImage processed;
        RgbColor color;
        var baseCached = LoadCached(basePath, baseMeta);
        if (baseCached != null)
        {
            processed = baseCached.Image;
            color = baseCached.BorderColor;
        }
        else
        {
            var (data, status) = await ScryfallTransport.GetAsync(url, 4, 2, ct).ConfigureAwait(false);
            if (status != HttpStatusCode.OK)
                throw new PpgException($"[PPG:FACE-DOWNLOAD] Image download failed: HTTP {(int)status} for {url}");
            ct.ThrowIfCancellationRequested();
            (processed, color) = await Task.Run(() =>
            {
                var (w, h, bgra) = DecodeBgra(data) ?? throw new PpgException($"[PPG:FACE-DECODE] Downloaded image could not be decoded: {url}");
                var c = SampleBorderColor(w, h, bgra);
                var flat = Flatten(w, h, bgra, c);
                if (scale != 1)
                {
                    flat = ImageOps.LanczosResize(flat, w * scale, h * scale);
                    ImageOps.UnsharpMask(flat, 2.2, 0.58);
                }
                return (flat, c);
            }, ct).ConfigureAwait(false);
            SavePng(processed, basePath, scale);
            WriteMeta(color, baseMeta);
            await Task.Delay(100, ct).ConfigureAwait(false); // courtesy pause after a fresh download
        }

        var adjusted = !calibration.IsIdentity || vibrance > 0 || midtoneLift > 0;
        if (!adjusted) return new PreparedFace(processed, color);

        await Task.Run(() =>
        {
            if (!calibration.IsIdentity) ImageOps.ApplyCalibration(processed, calibration);
            if (midtoneLift > 0) ImageOps.ApplyGamma(processed, 1.0 - midtoneLift);
            if (vibrance > 0) ImageOps.ApplySaturation(processed, 1.0 + vibrance);
        }, ct).ConfigureAwait(false);
        SavePng(processed, dest, scale);
        WriteMeta(color, destMeta);
        return new PreparedFace(processed, color);
    }

    // MARK: - Decoding and border sampling

    /// Scryfall card PNGs are 745 x 1040; nothing real comes close to this.
    public const int MaxImageSide = 4096;

    /// Reads only the image header and checks the size before anything is
    /// fully decoded, so an oversized or broken file is turned away early.
    public static bool HasSafeSize(byte[] data)
    {
        try
        {
            using var ms = new MemoryStream(data);
            var dec = BitmapDecoder.Create(ms, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
            if (dec.Frames.Count < 1) return false;
            var f = dec.Frames[0];
            return f.PixelWidth is > 0 and <= MaxImageSide && f.PixelHeight is > 0 and <= MaxImageSide;
        }
        catch { return false; }
    }

    private static (int W, int H, byte[] Bgra)? DecodeBgra(byte[] data)
    {
        if (!HasSafeSize(data)) return null;
        try
        {
            using var ms = new MemoryStream(data);
            var dec = BitmapDecoder.Create(ms, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            BitmapSource frame = dec.Frames[0];
            if (frame.Format != PixelFormats.Bgra32)
                frame = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
            var w = frame.PixelWidth; var h = frame.PixelHeight;
            var px = new byte[w * h * 4];
            frame.CopyPixels(px, w * 4, 0);
            return (w, h, px);
        }
        catch { return null; }
    }

    /// Median of border pixels just inside the card's edges: x at 1.6% from
    /// each side, y at 1.2%, crossed with the quarter points. Only opaque
    /// samples (alpha > 200) count.
    public static RgbColor SampleBorderColor(int w, int h, byte[] bgra)
    {
        if (w <= 4 || h <= 4) return new RgbColor(0, 0, 0);
        int[] xs = [Math.Max(1, (int)(w * 0.016)), w - 1 - (int)(w * 0.016)];
        int[] ys = [Math.Max(1, (int)(h * 0.012)), h - 1 - (int)(h * 0.012)];
        var points = new List<(int X, int Y)>();
        foreach (var x in xs) foreach (var fy in new[] { 0.25, 0.5, 0.75 }) points.Add((x, (int)(h * fy)));
        foreach (var y in ys) foreach (var fx in new[] { 0.25, 0.5, 0.75 }) points.Add(((int)(w * fx), y));
        List<int> rs = [], gs = [], bs = [];
        foreach (var (x, y) in points)
        {
            var i = (y * w + x) * 4;
            if (bgra[i + 3] > 200) { bs.Add(bgra[i]); gs.Add(bgra[i + 1]); rs.Add(bgra[i + 2]); }
        }
        if (rs.Count == 0) return new RgbColor(0, 0, 0);
        static int Median(List<int> v)
        {
            v.Sort();
            var mid = v.Count / 2;
            return v.Count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2;
        }
        return new RgbColor(Median(rs), Median(gs), Median(bs));
    }

    /// Composites the scan over its own border color, dropping alpha.
    private static RgbImage Flatten(int w, int h, byte[] bgra, RgbColor c)
    {
        var rgb = new byte[w * h * 3];
        for (int i = 0, o = 0; i < bgra.Length; i += 4, o += 3)
        {
            int a = bgra[i + 3], ia = 255 - a;
            rgb[o] = (byte)((bgra[i + 2] * a + c.R * ia + 127) / 255);
            rgb[o + 1] = (byte)((bgra[i + 1] * a + c.G * ia + 127) / 255);
            rgb[o + 2] = (byte)((bgra[i] * a + c.B * ia + 127) / 255);
        }
        return new RgbImage(w, h, rgb);
    }

    // MARK: - Cache files

    private sealed class FaceMeta { public int[] color { get; set; } = []; }

    private static PreparedFace? LoadCached(string image, string meta)
    {
        if (!File.Exists(image) || !File.Exists(meta)) return null;
        try
        {
            var m = JsonSerializer.Deserialize<FaceMeta>(File.ReadAllBytes(meta));
            if (m?.color is not { Length: 3 }) return null;
            var img = LoadPng(image);
            return img == null ? null : new PreparedFace(img, new RgbColor(m.color[0], m.color[1], m.color[2]));
        }
        catch { return null; }
    }

    private static void WriteMeta(RgbColor c, string path)
        => File.WriteAllText(path, JsonSerializer.Serialize(new FaceMeta { color = [c.R, c.G, c.B] }));

    public static RgbImage? LoadPng(string path)
    {
        using var fs = File.OpenRead(path);
        var dec = BitmapDecoder.Create(fs, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
        BitmapSource frame = dec.Frames[0];
        if (frame.Format != PixelFormats.Rgb24)
            frame = new FormatConvertedBitmap(frame, PixelFormats.Rgb24, null, 0);
        var px = new byte[frame.PixelWidth * frame.PixelHeight * 3];
        frame.CopyPixels(px, frame.PixelWidth * 3, 0);
        return new RgbImage(frame.PixelWidth, frame.PixelHeight, px);
    }

    private static void SavePng(RgbImage img, string path, int scale)
    {
        // Our own streaming PNG writer: fast, and handles any size.
        var tmp = path + ".tmp";
        using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
        using (var png = new StitchedPngWriter(fs, img.Width, img.Height, 300.0 * scale, System.IO.Compression.CompressionLevel.Fastest))
        {
            for (var y = 0; y < img.Height; y++) png.WriteRow(img.Pixels, y * img.Stride);
        }
        File.Move(tmp, path, true);
    }
}
