// ImageOps.cs
// Hand rolled, parallel pixel operations on packed RGB24 buffers: the
// Lanczos3 upscale, the unsharp mask, the color passes, and the small
// rasterizer the PNG / JPEG page builder draws pages with.

namespace ProxyPrintGenerator.Engine;

public static class ImageOps
{
    // MARK: - Resampling

    private static double Lanczos(double x, int a)
    {
        if (x == 0) return 1;
        if (Math.Abs(x) >= a) return 0;
        var px = Math.PI * x;
        return a * Math.Sin(px) * Math.Sin(px / a) / (px * px);
    }

    /// Per output pixel: first source index and normalized weights.
    private static (int[] Start, float[][] Weights) Kernel(int src, int dst, int a = 3)
    {
        var ratio = (double)src / dst;
        var support = ratio > 1 ? a * ratio : a;
        var filterScale = ratio > 1 ? ratio : 1;
        var starts = new int[dst];
        var weights = new float[dst][];
        for (var i = 0; i < dst; i++)
        {
            var center = (i + 0.5) * ratio - 0.5;
            var left = (int)Math.Floor(center - support) + 1;
            var right = (int)Math.Floor(center + support);
            var ws = new float[right - left + 1];
            double sum = 0;
            for (var j = left; j <= right; j++)
            {
                var w = Lanczos((j - center) / filterScale, a);
                ws[j - left] = (float)w;
                sum += w;
            }
            for (var k = 0; k < ws.Length; k++) ws[k] = (float)(ws[k] / sum);
            starts[i] = left;
            weights[i] = ws;
        }
        return (starts, weights);
    }

    private static byte Clamp(float v) => v <= 0 ? (byte)0 : v >= 255 ? (byte)255 : (byte)(v + 0.5f);

    public static RgbImage LanczosResize(RgbImage src, int dw, int dh)
    {
        int sw = src.Width, sh = src.Height;
        var (hs, hw) = Kernel(sw, dw);
        var (vs, vw) = Kernel(sh, dh);
        var tmp = new float[sh * dw * 3];
        var sp = src.Pixels;
        Parallel.For(0, sh, y =>
        {
            var row = y * sw * 3;
            var o = y * dw * 3;
            for (var x = 0; x < dw; x++)
            {
                float r = 0, g = 0, b = 0;
                var ws = hw[x]; var s0 = hs[x];
                for (var k = 0; k < ws.Length; k++)
                {
                    var sx = Math.Clamp(s0 + k, 0, sw - 1) * 3 + row;
                    var w = ws[k];
                    r += sp[sx] * w; g += sp[sx + 1] * w; b += sp[sx + 2] * w;
                }
                tmp[o++] = r; tmp[o++] = g; tmp[o++] = b;
            }
        });
        var dst = new byte[dw * dh * 3];
        var rowLen = dw * 3;
        Parallel.For(0, dh, () => new float[rowLen], (y, _, acc) =>
        {
            Array.Clear(acc);
            var ws = vw[y]; var s0 = vs[y];
            for (var k = 0; k < ws.Length; k++)
            {
                var sy = Math.Clamp(s0 + k, 0, sh - 1) * rowLen;
                var w = ws[k];
                for (var i = 0; i < rowLen; i++) acc[i] += tmp[sy + i] * w;
            }
            var o = y * rowLen;
            for (var i = 0; i < rowLen; i++) dst[o + i] = Clamp(acc[i]);
            return acc;
        }, _ => { });
        return new RgbImage(dw, dh, dst);
    }

    /// out = src + amount * (src - gaussian(src, sigma)), in place.
    public static void UnsharpMask(RgbImage img, double sigma, double amount)
    {
        var radius = (int)Math.Ceiling(sigma * 3);
        var kernel = new float[radius * 2 + 1];
        double sum = 0;
        for (var i = -radius; i <= radius; i++) { kernel[i + radius] = (float)Math.Exp(-(i * i) / (2 * sigma * sigma)); sum += kernel[i + radius]; }
        for (var i = 0; i < kernel.Length; i++) kernel[i] = (float)(kernel[i] / sum);

        int w = img.Width, h = img.Height, rowLen = w * 3;
        var p = img.Pixels;
        var blurH = new byte[p.Length];
        Parallel.For(0, h, y =>
        {
            var row = y * rowLen;
            for (var x = 0; x < w; x++)
            {
                float r = 0, g = 0, b = 0;
                for (var k = -radius; k <= radius; k++)
                {
                    var sx = row + Math.Clamp(x + k, 0, w - 1) * 3;
                    var kw = kernel[k + radius];
                    r += p[sx] * kw; g += p[sx + 1] * kw; b += p[sx + 2] * kw;
                }
                var o = row + x * 3;
                blurH[o] = Clamp(r); blurH[o + 1] = Clamp(g); blurH[o + 2] = Clamp(b);
            }
        });
        // Vertical pass, writing the sharpened result into a fresh buffer
        // (rows still being read must stay untouched).
        var outBuf = new byte[p.Length];
        var amt = (float)amount;
        Parallel.For(0, h, () => new float[rowLen], (y, _, acc) =>
        {
            Array.Clear(acc);
            for (var k = -radius; k <= radius; k++)
            {
                var sy = Math.Clamp(y + k, 0, h - 1) * rowLen;
                var kw = kernel[k + radius];
                for (var i = 0; i < rowLen; i++) acc[i] += blurH[sy + i] * kw;
            }
            var o = y * rowLen;
            for (var i = 0; i < rowLen; i++)
            {
                float v = p[o + i];
                outBuf[o + i] = Clamp(v + amt * (v - acc[i]));
            }
            return acc;
        }, _ => { });
        Buffer.BlockCopy(outBuf, 0, p, 0, p.Length);
    }

    // MARK: - Color passes

    private static void ApplyLuts(RgbImage img, byte[] lr, byte[] lg, byte[] lb)
    {
        var p = img.Pixels;
        Parallel.For(0, img.Height, y =>
        {
            var o = y * img.Stride; var end = o + img.Stride;
            for (; o < end; o += 3) { p[o] = lr[p[o]]; p[o + 1] = lg[p[o + 1]]; p[o + 2] = lb[p[o + 2]]; }
        });
    }

    /// v' = f*v + (1-f)*255 per channel (cyan on red, magenta on green,
    /// yellow on blue): the CMY boost as an affine map.
    public static void ApplyCalibration(RgbImage img, InkCalibration c)
    {
        static byte[] Lut(double f) => Enumerable.Range(0, 256).Select(v => Clamp((float)(f * v + (1 - f) * 255))).ToArray();
        ApplyLuts(img, Lut(c.Cyan), Lut(c.Magenta), Lut(c.Yellow));
    }

    /// Gamma under 1 brightens the middle tones; black and white hold.
    public static void ApplyGamma(RgbImage img, double power)
    {
        var lut = Enumerable.Range(0, 256).Select(v => Clamp((float)(255 * Math.Pow(v / 255.0, power)))).ToArray();
        ApplyLuts(img, lut, lut, lut);
    }

    /// Saturation around each pixel's own luminance (Rec. 709 weights).
    public static void ApplySaturation(RgbImage img, double saturation)
    {
        var p = img.Pixels; var s = (float)saturation;
        Parallel.For(0, img.Height, y =>
        {
            var o = y * img.Stride; var end = o + img.Stride;
            for (; o < end; o += 3)
            {
                float r = p[o], g = p[o + 1], b = p[o + 2];
                var l = 0.2125f * r + 0.7154f * g + 0.0721f * b;
                p[o] = Clamp(l + (r - l) * s); p[o + 1] = Clamp(l + (g - l) * s); p[o + 2] = Clamp(l + (b - l) * s);
            }
        });
    }

    // MARK: - Page rasterizer (top-left origin, pixels)

    public static void FillRect(RgbImage page, double x0, double y0, double x1, double y1, RgbColor c)
    {
        int ix0 = Math.Max(0, (int)Math.Round(x0)), iy0 = Math.Max(0, (int)Math.Round(y0));
        int ix1 = Math.Min(page.Width, (int)Math.Round(x1)), iy1 = Math.Min(page.Height, (int)Math.Round(y1));
        if (ix1 <= ix0 || iy1 <= iy0) return;
        var p = page.Pixels;
        Parallel.For(iy0, iy1, y =>
        {
            var o = y * page.Stride + ix0 * 3;
            for (var x = ix0; x < ix1; x++, o += 3) { p[o] = (byte)c.R; p[o + 1] = (byte)c.G; p[o + 2] = (byte)c.B; }
        });
    }

    /// Draws src stretched into the pixel rect, bilinear sampled.
    public static void DrawImage(RgbImage page, RgbImage src, double x0, double y0, double w, double h)
    {
        int ix0 = Math.Max(0, (int)Math.Round(x0)), iy0 = Math.Max(0, (int)Math.Round(y0));
        int ix1 = Math.Min(page.Width, (int)Math.Round(x0 + w)), iy1 = Math.Min(page.Height, (int)Math.Round(y0 + h));
        double sx = src.Width / w, sy = src.Height / h;
        var p = page.Pixels; var s = src.Pixels; int sw = src.Width, sh = src.Height, ss = src.Stride;
        Parallel.For(iy0, iy1, y =>
        {
            var fy = (y + 0.5 - y0) * sy - 0.5;
            var yA = Math.Clamp((int)Math.Floor(fy), 0, sh - 1); var yB = Math.Min(yA + 1, sh - 1);
            var ty = (float)Math.Clamp(fy - Math.Floor(fy), 0, 1);
            var o = y * page.Stride + ix0 * 3;
            for (var x = ix0; x < ix1; x++, o += 3)
            {
                var fx = (x + 0.5 - x0) * sx - 0.5;
                var xA = Math.Clamp((int)Math.Floor(fx), 0, sw - 1); var xB = Math.Min(xA + 1, sw - 1);
                var tx = (float)Math.Clamp(fx - Math.Floor(fx), 0, 1);
                int a = yA * ss + xA * 3, b = yA * ss + xB * 3, c = yB * ss + xA * 3, d = yB * ss + xB * 3;
                for (var ch = 0; ch < 3; ch++)
                {
                    var top = s[a + ch] + (s[b + ch] - s[a + ch]) * tx;
                    var bot = s[c + ch] + (s[d + ch] - s[c + ch]) * tx;
                    p[o + ch] = Clamp(top + (bot - top) * ty);
                }
            }
        });
    }

    /// Strokes a dashed rounded rectangle (pixels), antialiased, by laying
    /// short capsule segments along the path's arc length.
    public static void StrokeDashedRoundedRect(RgbImage page, double x, double y, double w, double h,
        double radius, double lineWidth, double dashOn, double dashOff, RgbColor color)
    {
        // Sample the path densely into a polyline with cumulative length.
        var pts = new List<(double X, double Y)>();
        void Arc(double cx, double cy, double a0, double a1)
        {
            const int n = 24;
            for (var i = 0; i <= n; i++)
            {
                var a = a0 + (a1 - a0) * i / n;
                pts.Add((cx + radius * Math.Cos(a), cy + radius * Math.Sin(a)));
            }
        }
        // Start at the top-left after the corner, run clockwise.
        pts.Add((x + radius, y));
        pts.Add((x + w - radius, y));
        Arc(x + w - radius, y + radius, -Math.PI / 2, 0);
        pts.Add((x + w, y + h - radius));
        Arc(x + w - radius, y + h - radius, 0, Math.PI / 2);
        pts.Add((x + radius, y + h));
        Arc(x + radius, y + h - radius, Math.PI / 2, Math.PI);
        pts.Add((x, y + radius));
        Arc(x + radius, y + radius, Math.PI, 1.5 * Math.PI);

        var segments = new List<(double Ax, double Ay, double Bx, double By)>();
        // Dash state machine: how much of the current dash (or gap) is left.
        var on = true;
        var left = dashOn;
        for (var i = 0; i + 1 < pts.Count; i++)
        {
            var (ax, ay) = pts[i]; var (bx, by) = pts[i + 1];
            var len = Math.Sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
            if (len < 1e-9) continue;
            double t = 0;
            while (len - t > 1e-9)
            {
                var step = Math.Min(left, len - t);
                if (on)
                {
                    double t0 = t / len, t1 = (t + step) / len;
                    segments.Add((ax + (bx - ax) * t0, ay + (by - ay) * t0, ax + (bx - ax) * t1, ay + (by - ay) * t1));
                }
                t += step;
                left -= step;
                if (left <= 1e-9) { on = !on; left = on ? dashOn : dashOff; }
            }
        }

        var half = lineWidth / 2;
        var p = page.Pixels;
        // Max coverage per pixel, so segment joins never double-blend.
        var coverage = new Dictionary<long, double>();
        foreach (var (ax, ay, bx, by) in segments)
        {
            int minX = Math.Max(0, (int)Math.Floor(Math.Min(ax, bx) - half - 1));
            int maxX = Math.Min(page.Width - 1, (int)Math.Ceiling(Math.Max(ax, bx) + half + 1));
            int minY = Math.Max(0, (int)Math.Floor(Math.Min(ay, by) - half - 1));
            int maxY = Math.Min(page.Height - 1, (int)Math.Ceiling(Math.Max(ay, by) + half + 1));
            double dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
            for (var py = minY; py <= maxY; py++)
            for (var px = minX; px <= maxX; px++)
            {
                double cx = px + 0.5, cy = py + 0.5;
                // Distance along / across the segment (butt caps).
                var t = l2 > 0 ? ((cx - ax) * dx + (cy - ay) * dy) / l2 : 0;
                var len = Math.Sqrt(l2);
                var along = t * len;
                var across = len > 0 ? Math.Abs((cx - ax) * dy - (cy - ay) * dx) / len : 0;
                var covAcross = Math.Clamp(half + 0.5 - across, 0, 1);
                var covAlong = Math.Clamp(Math.Min(along + 0.5, len - along + 0.5), 0, 1);
                var cov = covAcross * covAlong;
                if (cov <= 0) continue;
                long key = (long)py * page.Width + px;
                if (!coverage.TryGetValue(key, out var old) || cov > old) coverage[key] = cov;
            }
        }
        foreach (var (key, cov) in coverage)
        {
            var o = (int)(key / page.Width) * page.Stride + (int)(key % page.Width) * 3;
            p[o] = (byte)Math.Round(p[o] + (color.R - p[o]) * cov);
            p[o + 1] = (byte)Math.Round(p[o + 1] + (color.G - p[o + 1]) * cov);
            p[o + 2] = (byte)Math.Round(p[o + 2] + (color.B - p[o + 2]) * cov);
        }
    }
}
