// Builders.cs
// Page assembly, ported from PDFBuilder.swift:
//   - PdfBuilder: a hand written, file backed PDF. Each unique face is
//     written once as an image XObject and referenced by every
//     placement, so memory stays flat and the file stays small.
//   - ImagePageBuilder: renders the same pages to full resolution
//     pixels and stitches them into one tall PNG (streamed straight to
//     disk, then verified by re-inflating it) or one tall JPEG.

using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.IO.MemoryMappedFiles;
using System.Text;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ProxyPrintGenerator.Engine;

public enum OutputFormat { Pdf, Png, Jpeg }

public static class OutputFormatExtensions
{
    public static string Label(this OutputFormat f) => f switch { OutputFormat.Pdf => "PDF", OutputFormat.Png => "PNG", _ => "JPEG" };
    public static string FileExtension(this OutputFormat f) => f switch { OutputFormat.Pdf => "pdf", OutputFormat.Png => "png", _ => "jpg" };
}

public interface IPageBuilder : IDisposable
{
    Action<int, int>? OnFaceDrawn { get; set; }
    void Begin(int totalPlacements, int pageCount);
    void BeginPage();
    Task DrawCardAsync(int slot, FaceRef face, Func<Task<PreparedFace>> load);
    void EndPage();
    void Finish();
}

// MARK: - PDF

public sealed class PdfBuilder(string outputPath, PrintSettings settings, string title) : IPageBuilder
{
    public Action<int, int>? OnFaceDrawn { get; set; }

    private FileStream? _fs;
    private readonly List<long> _offsets = [0, 0, 0]; // 0 unused, 1 catalog, 2 pages
    private readonly List<int> _pageIds = [];
    private readonly Dictionary<FaceRef, (int Obj, RgbColor Border)> _images = [];
    private StringBuilder _content = new();
    private readonly HashSet<int> _pageImages = [];
    private int _placed, _total;

    private static string N(double v) => v.ToString("0.####", CultureInfo.InvariantCulture);

    private void Write(string s) { var b = Encoding.ASCII.GetBytes(s); _fs!.Write(b, 0, b.Length); }

    private int NewObject()
    {
        _offsets.Add(0);
        return _offsets.Count - 1;
    }

    private void BeginObject(int id) { _offsets[id] = _fs!.Position; Write($"{id} 0 obj\n"); }

    private void WriteStreamObject(int id, string dict, byte[] data)
    {
        BeginObject(id);
        Write($"<< {dict} /Length {data.Length} >>\nstream\n");
        _fs!.Write(data, 0, data.Length);
        Write("\nendstream\nendobj\n");
    }

    private static byte[] Deflate(byte[] data, int offset, int count, CompressionLevel level)
    {
        using var ms = new MemoryStream();
        using (var z = new ZLibStream(ms, level, true)) z.Write(data, offset, count);
        return ms.ToArray();
    }

    public void Begin(int totalPlacements, int pageCount)
    {
        _total = totalPlacements;
        _fs = new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
        Write("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");
    }

    public void BeginPage()
    {
        _content = new StringBuilder();
        _pageImages.Clear();
    }

    public async Task DrawCardAsync(int slot, FaceRef face, Func<Task<PreparedFace>> load)
    {
        if (!_images.TryGetValue(face, out var img))
        {
            var prepared = await load().ConfigureAwait(false);
            var id = NewObject();
            var data = await Task.Run(() => Deflate(prepared.Image.Pixels, 0, prepared.Image.Pixels.Length, CompressionLevel.Optimal)).ConfigureAwait(false);
            WriteStreamObject(id, $"/Type /XObject /Subtype /Image /Width {prepared.Image.Width} /Height {prepared.Image.Height} " +
                                  "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Interpolate true /Filter /FlateDecode", data);
            img = (id, prepared.BorderColor);
            _images[face] = img;
        }
        _pageImages.Add(img.Obj);

        var (x, top, w, h) = settings.SlotRectFromTop(slot);
        var y = settings.PageHeightPoints - top - h; // PDF origin at lower left
        var buf = settings.BufferMM * PageGeometry.PointsPerMM;
        var cal = settings.Calibration;
        var bc = cal.Boosted(img.Border);
        var c = _content;
        c.Append($"{N(bc.R / 255.0)} {N(bc.G / 255.0)} {N(bc.B / 255.0)} rg {N(x - buf)} {N(y - buf)} {N(w + 2 * buf)} {N(h + 2 * buf)} re f\n");
        c.Append($"q {N(w)} 0 0 {N(h)} {N(x)} {N(y)} cm /Im{img.Obj} Do Q\n");
        if (settings.ShowGuides)
        {
            var g = cal.Boosted(PageGeometry.GuideColor);
            var lw = settings.ThickGuides ? 2.2 : 0.7;
            var dash = settings.ThickGuides ? "[3.2 2.2]" : "[1.6 1.6]";
            c.Append($"q {N(g.R / 255.0)} {N(g.G / 255.0)} {N(g.B / 255.0)} RG {N(lw)} w {dash} 0 d\n");
            AppendRoundedRect(c, x, y, w, h, PageGeometry.CardCornerRadiusPoints);
            c.Append("S Q\n");
        }
        _placed++;
        OnFaceDrawn?.Invoke(_placed, _total);
    }

    private static void AppendRoundedRect(StringBuilder c, double x, double y, double w, double h, double r)
    {
        const double k = 0.5522847498;
        var kr = k * r;
        c.Append($"{N(x + r)} {N(y)} m\n");
        c.Append($"{N(x + w - r)} {N(y)} l\n");
        c.Append($"{N(x + w - r + kr)} {N(y)} {N(x + w)} {N(y + r - kr)} {N(x + w)} {N(y + r)} c\n");
        c.Append($"{N(x + w)} {N(y + h - r)} l\n");
        c.Append($"{N(x + w)} {N(y + h - r + kr)} {N(x + w - r + kr)} {N(y + h)} {N(x + w - r)} {N(y + h)} c\n");
        c.Append($"{N(x + r)} {N(y + h)} l\n");
        c.Append($"{N(x + r - kr)} {N(y + h)} {N(x)} {N(y + h - r + kr)} {N(x)} {N(y + h - r)} c\n");
        c.Append($"{N(x)} {N(y + r)} l\n");
        c.Append($"{N(x)} {N(y + r - kr)} {N(x + r - kr)} {N(y)} {N(x + r)} {N(y)} c\nh\n");
    }

    public void EndPage()
    {
        var bytes = Encoding.ASCII.GetBytes(_content.ToString());
        var contentId = NewObject();
        WriteStreamObject(contentId, "/Filter /FlateDecode", Deflate(bytes, 0, bytes.Length, CompressionLevel.Optimal));
        var pageId = NewObject();
        BeginObject(pageId);
        var xobjects = string.Join(" ", _pageImages.Select(i => $"/Im{i} {i} 0 R"));
        Write($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {N(settings.PageWidthPoints)} {N(settings.PageHeightPoints)}] " +
              $"/Resources << /XObject << {xobjects} >> >> /Contents {contentId} 0 R >>\nendobj\n");
        _pageIds.Add(pageId);
    }

    public void Finish()
    {
        if (_fs == null) return;
        BeginObject(2);
        Write($"<< /Type /Pages /Kids [{string.Join(" ", _pageIds.Select(i => $"{i} 0 R"))}] /Count {_pageIds.Count} >>\nendobj\n");
        BeginObject(1);
        Write("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
        var infoId = NewObject();
        BeginObject(infoId);
        Write($"<< /Title ({title}) /Producer (ProxyPrintGenerator) >>\nendobj\n");
        var xref = _fs.Position;
        var sb = new StringBuilder();
        sb.Append($"xref\n0 {_offsets.Count}\n0000000000 65535 f \n");
        for (var i = 1; i < _offsets.Count; i++) sb.Append($"{_offsets[i]:D10} 00000 n \n");
        sb.Append($"trailer\n<< /Size {_offsets.Count} /Root 1 0 R /Info {infoId} 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        Write(sb.ToString());
        _fs.Dispose();
        _fs = null;
    }

    public void Dispose() => _fs?.Dispose();
}

// MARK: - Streaming PNG writer

/// Splits whatever is written to it into PNG IDAT chunks.
internal sealed class IdatChunkStream(Stream output) : Stream
{
    private readonly MemoryStream _buffer = new();
    private const int ChunkSize = 1 << 20;

    public override void Write(byte[] buffer, int offset, int count)
    {
        _buffer.Write(buffer, offset, count);
        if (_buffer.Length >= ChunkSize) FlushChunk();
    }

    private void FlushChunk()
    {
        if (_buffer.Length == 0) return;
        Png.WriteChunk(output, "IDAT", _buffer.GetBuffer(), (int)_buffer.Length);
        _buffer.SetLength(0);
    }

    public override void Flush() => FlushChunk();
    protected override void Dispose(bool disposing) { if (disposing) FlushChunk(); base.Dispose(disposing); }
    public override bool CanRead => false;
    public override bool CanSeek => false;
    public override bool CanWrite => true;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
}

internal static class Png
{
    private static readonly uint[] CrcTable = Enumerable.Range(0, 256).Select(n =>
    {
        var c = (uint)n;
        for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        return c;
    }).ToArray();

    public static uint Crc(uint crc, byte[] data, int offset, int count)
    {
        for (var i = offset; i < offset + count; i++) crc = CrcTable[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
        return crc;
    }

    public static void WriteBE(Stream s, uint v)
    {
        s.WriteByte((byte)(v >> 24)); s.WriteByte((byte)(v >> 16)); s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)v);
    }

    public static void WriteChunk(Stream s, string type, byte[] data, int count)
    {
        var t = Encoding.ASCII.GetBytes(type);
        WriteBE(s, (uint)count);
        s.Write(t, 0, 4);
        s.Write(data, 0, count);
        var crc = Crc(0xFFFFFFFF, t, 0, 4);
        crc = Crc(crc, data, 0, count) ^ 0xFFFFFFFF;
        WriteBE(s, crc);
    }

    public static byte[] BE(params uint[] values)
    {
        var b = new byte[values.Length * 4];
        for (var i = 0; i < values.Length; i++)
        {
            b[i * 4] = (byte)(values[i] >> 24); b[i * 4 + 1] = (byte)(values[i] >> 16);
            b[i * 4 + 2] = (byte)(values[i] >> 8); b[i * 4 + 3] = (byte)values[i];
        }
        return b;
    }
}

/// Writes an RGB24 PNG row by row ("Sub" filter), with the DPI stamped
/// into pHYs so print software can place it at true size.
public sealed class StitchedPngWriter : IDisposable
{
    private readonly Stream _out;
    private readonly IdatChunkStream _idat;
    private readonly ZLibStream _z;
    private readonly int _width;
    private readonly byte[] _row;
    private bool _disposed;
    public int RowsWritten { get; private set; }

    public StitchedPngWriter(Stream output, int width, int height, double dpi, CompressionLevel level = CompressionLevel.Optimal)
    {
        _out = output;
        _width = width;
        _row = new byte[width * 3 + 1];
        output.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        var ihdr = Png.BE((uint)width, (uint)height).Concat(new byte[] { 8, 2, 0, 0, 0 }).ToArray();
        Png.WriteChunk(output, "IHDR", ihdr, ihdr.Length);
        var ppm = (uint)Math.Round(dpi / 0.0254);
        var phys = Png.BE(ppm, ppm).Concat(new byte[] { 1 }).ToArray();
        Png.WriteChunk(output, "pHYs", phys, phys.Length);
        _idat = new IdatChunkStream(output);
        _z = new ZLibStream(_idat, level, true);
    }

    public void WriteRow(byte[] src, int offset)
    {
        var n = _width * 3;
        _row[0] = 1; // Sub
        for (var i = 0; i < 3 && i < n; i++) _row[1 + i] = src[offset + i];
        for (var i = 3; i < n; i++) _row[1 + i] = (byte)(src[offset + i] - src[offset + i - 3]);
        _z.Write(_row, 0, _row.Length);
        RowsWritten++;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _z.Dispose();
        _idat.Dispose();
        Png.WriteChunk(_out, "IEND", [], 0);
        _out.Flush();
    }

    /// Re-inflates every IDAT byte (the zlib trailer checks the Adler-32)
    /// and confirms the size from the header and the row data, without
    /// ever holding the picture.
    public static void Verify(string path, int width, int totalHeight, Func<bool> shouldCancel, Action<long, long>? progress)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20);
        var sig = new byte[8];
        fs.ReadExactly(sig);
        using var idat = new IdatReadStream(fs);
        using var z = new ZLibStream(idat, CompressionMode.Decompress);
        var expected = (long)totalHeight * (1 + width * 3);
        var buf = new byte[1 << 20];
        long total = 0, lastReported = 0;
        int read;
        while ((read = z.Read(buf, 0, buf.Length)) > 0)
        {
            total += read;
            if (total - lastReported >= 64_000_000) { lastReported = total; progress?.Invoke(total, expected); }
            if (shouldCancel()) throw new OperationCanceledException();
        }
        if (idat.HeaderHeight != totalHeight || total != expected)
            throw new PpgException($"[PPG:PNG-VERIFY] The stitched PNG failed verification (decoded {total} of {expected} bytes).");
    }

    private sealed class IdatReadStream(Stream s) : Stream
    {
        private long _remaining;
        private bool _ended;
        public int HeaderHeight { get; private set; }

        private bool NextChunk()
        {
            var header = new byte[8];
            while (true)
            {
                if (s.Read(header, 0, 8) < 8) throw new PpgException("[PPG:PNG-TRUNCATED] The stitched PNG ended early.");
                var len = (long)header[0] << 24 | (long)header[1] << 16 | (long)header[2] << 8 | header[3];
                var type = Encoding.ASCII.GetString(header, 4, 4);
                if (type == "IEND") { _ended = true; return false; }
                if (type == "IDAT") { _remaining = len; return true; }
                if (type == "IHDR")
                {
                    var d = new byte[len];
                    s.ReadExactly(d);
                    HeaderHeight = d[4] << 24 | d[5] << 16 | d[6] << 8 | d[7];
                    s.Seek(4, SeekOrigin.Current);
                    continue;
                }
                s.Seek(len + 4, SeekOrigin.Current);
            }
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            if (_ended) return 0;
            while (_remaining == 0)
            {
                if (!NextChunk()) return 0;
                if (_remaining == 0) s.Seek(4, SeekOrigin.Current);
            }
            var n = s.Read(buffer, offset, (int)Math.Min(count, _remaining));
            if (n <= 0) throw new PpgException("[PPG:PNG-TRUNCATED] The stitched PNG ended early.");
            _remaining -= n;
            if (_remaining == 0) s.Seek(4, SeekOrigin.Current); // the chunk CRC
            return n;
        }

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}

// MARK: - Image pages (PNG / JPEG)

public sealed class ImagePageBuilder(string outputPath, PrintSettings settings, int scale,
    OutputFormat format, double jpegQuality) : IPageBuilder
{
    public Action<int, int>? OnFaceDrawn { get; set; }
    public Action<int, int>? OnStitchProgress { get; set; }
    public Action<long, long>? OnVerifyProgress { get; set; }
    public Func<bool> ShouldCancel { get; set; } = () => false;

    private double PixelsPerPoint => scale * 300.0 / 72.0;
    private int PageWidthPx => (int)Math.Round(settings.PageWidthPoints * PixelsPerPoint);
    private int PageHeightPx => (int)Math.Round(settings.PageHeightPoints * PixelsPerPoint);

    private RgbImage? _page;
    private int _placed, _total, _pageCount, _finishedPages;
    private (FaceRef Ref, PreparedFace Face)? _last;

    private FileStream? _pngFile;
    private StitchedPngWriter? _png;
    private string? _scratchPath;
    private MemoryMappedFile? _mmf;
    private MemoryMappedViewAccessor? _view;

    public void Begin(int totalPlacements, int pageCount)
    {
        _total = totalPlacements;
        _pageCount = pageCount;
        var totalHeight = (long)PageHeightPx * pageCount;
        if (format == OutputFormat.Png)
        {
            _pngFile = new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
            _png = new StitchedPngWriter(_pngFile, PageWidthPx, (int)totalHeight, scale * 300.0);
        }
        else
        {
            var bytes = (long)PageWidthPx * 3 * totalHeight;
            if (PageWidthPx > 65_535 || totalHeight > 65_535 || bytes > int.MaxValue)
                throw new PpgException("[PPG:JPEG-SIZE] JPEG cannot hold an image this size: the format caps a side at 65,535 pixels. Use PNG or PDF here, or lower the scale.");
            _scratchPath = Path.Combine(Path.GetTempPath(), $"ProxyPrintStitch-{Guid.NewGuid()}");
            _mmf = MemoryMappedFile.CreateFromFile(_scratchPath, FileMode.Create, null, bytes, MemoryMappedFileAccess.ReadWrite);
            _view = _mmf.CreateViewAccessor(0, bytes);
        }
    }

    public void BeginPage()
    {
        var px = new byte[(long)PageWidthPx * PageHeightPx * 3];
        Array.Fill(px, (byte)255); // the paper itself: plain white
        _page = new RgbImage(PageWidthPx, PageHeightPx, px);
    }

    public async Task DrawCardAsync(int slot, FaceRef face, Func<Task<PreparedFace>> load)
    {
        PreparedFace prepared;
        if (_last is { } last && last.Ref == face) prepared = last.Face;
        else { prepared = await load().ConfigureAwait(false); _last = (face, prepared); }

        var page = _page!;
        var k = PixelsPerPoint;
        var (x, top, w, h) = settings.SlotRectFromTop(slot);
        var buf = settings.BufferMM * PageGeometry.PointsPerMM;
        var cal = settings.Calibration;
        await Task.Run(() =>
        {
            ImageOps.FillRect(page, (x - buf) * k, (top - buf) * k, (x + w + buf) * k, (top + h + buf) * k, cal.Boosted(prepared.BorderColor));
            ImageOps.DrawImage(page, prepared.Image, x * k, top * k, w * k, h * k);
            if (settings.ShowGuides)
            {
                var thick = settings.ThickGuides;
                ImageOps.StrokeDashedRoundedRect(page, x * k, top * k, w * k, h * k, PageGeometry.CardCornerRadiusPoints * k,
                    (thick ? 2.2 : 0.7) * k, (thick ? 3.2 : 1.6) * k, (thick ? 2.2 : 1.6) * k, cal.Boosted(PageGeometry.GuideColor));
            }
        }).ConfigureAwait(false);
        _placed++;
        OnFaceDrawn?.Invoke(_placed, _total);
    }

    public void EndPage()
    {
        var page = _page!;
        if (_png != null)
        {
            for (var y = 0; y < page.Height; y++) _png.WriteRow(page.Pixels, y * page.Stride);
        }
        else if (_view != null)
        {
            // Into the canvas as BGR, page one at the top.
            var rowBytes = page.Stride;
            var row = new byte[rowBytes];
            long baseOffset = (long)_finishedPages * page.Height * rowBytes;
            for (var y = 0; y < page.Height; y++)
            {
                var o = y * rowBytes;
                for (var i = 0; i < rowBytes; i += 3) { row[i] = page.Pixels[o + i + 2]; row[i + 1] = page.Pixels[o + i + 1]; row[i + 2] = page.Pixels[o + i]; }
                _view.WriteArray(baseOffset + (long)y * rowBytes, row, 0, rowBytes);
            }
        }
        _page = null;
        _finishedPages++;
        OnStitchProgress?.Invoke(_finishedPages, _pageCount);
        if (ShouldCancel()) throw new OperationCanceledException();
    }

    public void Finish()
    {
        _last = null;
        if (_png != null)
        {
            _png.Dispose();
            _pngFile!.Dispose();
            var height = PageHeightPx * _pageCount;
            _png = null;
            StitchedPngWriter.Verify(outputPath, PageWidthPx, height, ShouldCancel, OnVerifyProgress);
            return;
        }
        if (_view == null) return;
        unsafe
        {
            byte* ptr = null;
            _view.SafeMemoryMappedViewHandle.AcquirePointer(ref ptr);
            try
            {
                var stride = PageWidthPx * 3;
                var height = PageHeightPx * _pageCount;
                var dpi = scale * 300.0;
                var src = BitmapSource.Create(PageWidthPx, height, dpi, dpi, PixelFormats.Bgr24, null,
                    (IntPtr)ptr, stride * height, stride);
                var enc = new JpegBitmapEncoder { QualityLevel = Math.Clamp((int)Math.Round(jpegQuality * 100), 1, 100) };
                enc.Frames.Add(BitmapFrame.Create(src));
                using var fs = new FileStream(outputPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
                enc.Save(fs);
            }
            finally { _view.SafeMemoryMappedViewHandle.ReleasePointer(); }
        }
        CleanupScratch();
    }

    private void CleanupScratch()
    {
        _view?.Dispose(); _view = null;
        _mmf?.Dispose(); _mmf = null;
        if (_scratchPath != null) { try { File.Delete(_scratchPath); } catch { } _scratchPath = null; }
    }

    public void Dispose()
    {
        try { _png?.Dispose(); } catch { }
        _pngFile?.Dispose();
        CleanupScratch();
    }
}
