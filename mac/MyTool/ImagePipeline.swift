//
//  ImagePipeline.swift
//  Version 8
//  Proxy Printer (native port) — Phase 1 engine
//
//  Prepares one card face at a time for the PDF builder:
//    download the PNG scan (with retries), sample the card's own border
//    color, flatten transparency onto that color, Lanczos upscale by the
//    scale factor with a gentle unsharp pass, then apply the ink
//    calibration. Every stage is cached on disk using the Python script's
//    file naming, so reruns are decode-only.
//
//  Memory rule (from the plan): a PreparedFace is handed to the caller,
//  drawn, and released. The pipeline never keeps a deck of upscaled
//  images alive.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO

/// 8 bit RGB color, channels 0...255, as in the Python script.
public nonisolated struct RGBColor: Equatable {
    public var r: Int
    public var g: Int
    public var b: Int
    public init(_ r: Int, _ g: Int, _ b: Int) {
        self.r = r; self.g = g; self.b = b
    }

    public var cgColor: CGColor {
        CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255, alpha: 1)
    }
}

/// Per channel ink compensation. A factor above 1 deepens that ink's
/// channel to make up for a weak cartridge.
public nonisolated struct InkCalibration: Equatable {
    public var cyan: Double
    public var magenta: Double
    public var yellow: Double
    public init(cyan: Double = 1, magenta: Double = 1, yellow: Double = 1) {
        self.cyan = cyan; self.magenta = magenta; self.yellow = yellow
    }
    public static let none = InkCalibration()
    public var isIdentity: Bool {
        cyan == 1 && magenta == 1 && yellow == 1
    }

    /// The Python boost_color: channel' = 255 - min(255, (255 - v) * f).
    public func boosted(_ color: RGBColor) -> RGBColor {
        func boost(_ v: Int, _ f: Double) -> Int {
            if f == 1 { return v }
            return 255 - min(255, Int((Double(255 - v) * f).rounded()))
        }
        return RGBColor(boost(color.r, cyan), boost(color.g, magenta),
                        boost(color.b, yellow))
    }
}

public nonisolated struct PreparedFace {
    /// Fully processed (upscaled + calibrated) image, ready to draw.
    public var image: CGImage
    /// The card's sampled border color, NOT yet calibration boosted;
    /// the PDF builder boosts it at draw time, like the Python script.
    public var borderColor: RGBColor
}

public nonisolated enum ImagePipelineError: Error, CustomStringConvertible {
    case message(String)
    public var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

public nonisolated final class ImagePipeline {

    private let cacheDirectory: URL
    private let calibration: InkCalibration
    private let vibrance: Double
    private let midtoneLift: Double
    private let session: URLSession
    private let ciContext = CIContext(options: nil)

    public init(cacheDirectory: URL, calibration: InkCalibration,
                vibrance: Double = 0,
                midtoneLift: Double = 0,
                session: URLSession = ScryfallTransport.makeSession()) {
        self.cacheDirectory = cacheDirectory
        self.calibration = calibration
        self.vibrance = vibrance
        self.midtoneLift = midtoneLift
        self.session = session
    }

    // MARK: - Public entry point

    /// Mirrors the Python prepare_image, including its two level cache:
    /// a calibrated file is reused directly; otherwise the uncalibrated
    /// processed file is reused and only the calibration is reapplied.
    public func prepareFace(url: URL, set: String, collector: String,
                            faceIndex: Int, scale: Int) async throws
        -> PreparedFace {
        try FileManager.default.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true)

        let baseStem = "\(Self.safeStemPart(set))"
            + "_\(Self.safeStemPart(collector))"
            + "_f\(faceIndex)_x\(scale)"
        var destStem = baseStem
        if !calibration.isIdentity {
            destStem += String(
                format: "_c%g_m%g_y%g",
                calibration.cyan, calibration.magenta, calibration.yellow)
        }
        if vibrance > 0 {
            destStem += String(format: "_v%g", vibrance)
        }
        if midtoneLift > 0 {
            destStem += String(format: "_l%g", midtoneLift)
        }
        let dest = cacheDirectory.appendingPathComponent(destStem + ".png")
        let destMeta = cacheDirectory.appendingPathComponent(destStem + ".json")
        if let cached = loadCached(image: dest, meta: destMeta) {
            return cached
        }

        let base = cacheDirectory.appendingPathComponent(baseStem + ".png")
        let baseMeta = cacheDirectory.appendingPathComponent(baseStem + ".json")

        let processed: CGImage
        let color: RGBColor
        if FileManager.default.fileExists(atPath: base.path),
           let metaColor = readMetaColor(baseMeta),
           let baseImage = loadPNG(base) {
            processed = baseImage
            color = metaColor
        } else {
            let source = try await downloadPNG(url)
            color = Self.sampleBorderColor(of: source)
            guard let done = process(source, borderColor: color, scale: scale)
            else {
                throw ImagePipelineError.message(
                    "[PPG:FACE-PROCESS] Image processing failed for \(set) \(collector) face \(faceIndex)")
            }
            processed = done
            try savePNG(processed, to: base)
            try writeMetaColor(color, to: baseMeta)
            // Same courtesy pause after a fresh download as the Python code.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        ciContext.clearCaches()
        // The color passes run inside their own pool, and
        // the shared Core Image context drops its caches
        // when the face is done: left alone, a hundred
        // faces' worth of intermediates pile up in it and
        // the whole machine feels the weight afterwards.
        let final: CGImage = try autoreleasepool {
            var result = processed
            if !calibration.isIdentity {
                guard let boosted = applyCalibration(to: processed)
                else {
                    throw ImagePipelineError.message(
                        "[PPG:FACE-CALIBRATION] Calibration failed for \(set) \(collector) face \(faceIndex)")
                }
                result = boosted
            }
            if midtoneLift > 0 {
                guard let lifted = applyMidtoneLift(to: result)
                else {
                    throw ImagePipelineError.message(
                        "[PPG:FACE-LIFT] Midtone lift failed for \(set) \(collector) face \(faceIndex)")
                }
                result = lifted
            }
            if vibrance > 0 {
                guard let vivid = applyVibrance(to: result) else {
                    throw ImagePipelineError.message(
                        "[PPG:FACE-VIBRANCE] Vibrance failed for \(set) \(collector) face \(faceIndex)")
                }
                result = vivid
            }
            if !calibration.isIdentity || vibrance > 0
                || midtoneLift > 0 {
                try savePNG(result, to: dest)
                try writeMetaColor(color, to: destMeta)
            }
            return result
        }
        ciContext.clearCaches()
        return PreparedFace(image: final, borderColor: color)
    }

    /// Cache file names are built from set codes and
    /// collector numbers, which arrive from outside data:
    /// keep letters, digits, dash and underscore, and turn
    /// everything else (dots, slashes, stars) into an
    /// underscore, so a strange number can never become a
    /// path.
    private static func safeStemPart(_ value: String) -> String {
        var out = ""
        for character in value {
            if character.isLetter || character.isNumber
                || character == "-" || character == "_" {
                out.append(character)
            } else {
                out.append("_")
            }
        }
        return out
    }

    /// Scryfall card PNGs are 745 x 1040; nothing real comes
    /// close to this.
    public static let maxImageSide = 4096

    // MARK: - Download

    private func downloadPNG(_ url: URL) async throws -> CGImage {
        let request = ScryfallTransport.makeRequest(url: url)
        let (data, http) = try await ScryfallTransport.data(
            for: request, attempts: 4, baseDelay: 2, session: session)
        guard http.statusCode == 200 else {
            throw ImagePipelineError.message(
                "[PPG:FACE-DOWNLOAD] Image download failed: HTTP \(http.statusCode) for \(url.absoluteString)")
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData, nil) else {
            throw ImagePipelineError.message(
                "[PPG:FACE-DECODE] Downloaded image could not be decoded: \(url.absoluteString)")
        }
        // Header first: the dimensions come from the image
        // properties, before any full decode, so an oversized
        // or broken file is turned away early.
        let properties = CGImageSourceCopyPropertiesAtIndex(
            source, 0, nil) as NSDictionary?
        let width = properties?[kCGImagePropertyPixelWidth]
            as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight]
            as? Int ?? 0
        guard width > 0, height > 0,
              width <= Self.maxImageSide,
              height <= Self.maxImageSide,
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, nil)
        else {
            throw ImagePipelineError.message(
                "[PPG:FACE-DECODE] Downloaded image could not be decoded: \(url.absoluteString)")
        }
        return image
    }

    // MARK: - Processing (CoreImage)

    /// Flatten onto the sampled border color, then upscale + unsharp.
    private func process(_ source: CGImage, borderColor: RGBColor,
                         scale: Int) -> CGImage? {
        var image = CIImage(cgImage: source)
        let extent = image.extent
        let background = CIImage(
            color: CIColor(red: CGFloat(borderColor.r) / 255,
                           green: CGFloat(borderColor.g) / 255,
                           blue: CGFloat(borderColor.b) / 255,
                           alpha: 1)).cropped(to: extent)
        if let over = CIFilter(name: "CISourceOverCompositing") {
            over.setValue(image, forKey: kCIInputImageKey)
            over.setValue(background, forKey: kCIInputBackgroundImageKey)
            if let out = over.outputImage { image = out }
        }
        if scale != 1 {
            if let lanczos = CIFilter(name: "CILanczosScaleTransform") {
                lanczos.setValue(image, forKey: kCIInputImageKey)
                lanczos.setValue(NSNumber(value: scale),
                                 forKey: kCIInputScaleKey)
                lanczos.setValue(NSNumber(value: 1.0),
                                 forKey: kCIInputAspectRatioKey)
                if let out = lanczos.outputImage { image = out }
            }
            if let unsharp = CIFilter(name: "CIUnsharpMask") {
                unsharp.setValue(image, forKey: kCIInputImageKey)
                // Python: UnsharpMask(radius=2.2, percent=58, threshold=2).
                // CoreImage has no threshold parameter; radius and
                // intensity (percent / 100) carry over directly.
                unsharp.setValue(NSNumber(value: 2.2),
                                 forKey: kCIInputRadiusKey)
                unsharp.setValue(NSNumber(value: 0.58),
                                 forKey: kCIInputIntensityKey)
                if let out = unsharp.outputImage { image = out }
            }
        }
        return ciContext.createCGImage(image, from: image.extent)
    }

    /// The Python CMY boost, channel by channel, is the affine map
    /// v' = f * v + (1 - f) * 255 (expand boost_color to check), which is
    /// exactly what CIColorMatrix expresses. Rendering to an 8 bit image
    /// clamps out of range values the way PIL's point() does.
    private func applyCalibration(to source: CGImage) -> CGImage? {
        guard let matrix = CIFilter(name: "CIColorMatrix") else { return nil }
        let c = calibration
        matrix.setValue(CIImage(cgImage: source), forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: CGFloat(c.cyan), y: 0, z: 0, w: 0),
                        forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: CGFloat(c.magenta), z: 0, w: 0),
                        forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: CGFloat(c.yellow), w: 0),
                        forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1),
                        forKey: "inputAVector")
        matrix.setValue(
            CIVector(x: CGFloat(1 - c.cyan), y: CGFloat(1 - c.magenta),
                     z: CGFloat(1 - c.yellow), w: 0),
            forKey: "inputBiasVector")
        guard let out = matrix.outputImage else { return nil }
        return ciContext.createCGImage(out, from: out.extent)
    }

    /// A midtone lift fights dot gain, the darkening
    /// matte prints pick up in their middle tones: a gamma
    /// curve under 1.0 brightens the middle of the range
    /// while black stays black and white stays white, so
    /// shaded art opens up without washing anything out.
    /// The slider value is how far the power drops below
    /// 1.0, so 0.2 on the slider runs a 0.8 gamma.
    private func applyMidtoneLift(to source: CGImage) -> CGImage? {
        guard let gamma = CIFilter(name: "CIGammaAdjust")
        else { return nil }
        gamma.setValue(CIImage(cgImage: source),
                       forKey: kCIInputImageKey)
        gamma.setValue(NSNumber(value: 1.0 - midtoneLift),
                       forKey: "inputPower")
        guard let out = gamma.outputImage else { return nil }
        return ciContext.createCGImage(out, from: out.extent)
    }

    /// Vibrance is a saturation lift, not an ink change:
    /// every color is pushed away from gray while its
    /// brightness stays put, so prints gain color without
    /// the blacks and neutrals darkening the way extra
    /// CMY does. CIColorControls saturation scales each
    /// pixel's chroma around its own luminance, which is
    /// exactly that.
    private func applyVibrance(to source: CGImage) -> CGImage? {
        guard let controls = CIFilter(name: "CIColorControls")
        else { return nil }
        controls.setValue(CIImage(cgImage: source),
                          forKey: kCIInputImageKey)
        controls.setValue(NSNumber(value: 1.0 + vibrance),
                          forKey: kCIInputSaturationKey)
        guard let out = controls.outputImage else { return nil }
        return ciContext.createCGImage(out, from: out.extent)
    }

    // MARK: - Border color sampling

    /// Median of border pixels sampled just inside the card's edges, at
    /// the same relative positions as the Python edge_color: x at 1.6%
    /// from each side, y at 1.2%, crossed with the quarter points.
    /// (The sample set is symmetric top to bottom, so the bitmap row
    /// orientation does not change the median.)
    public static func sampleBorderColor(of image: CGImage) -> RGBColor {
        let w = image.width
        let h = image.height
        guard w > 4, h > 4 else { return RGBColor(0, 0, 0) }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn = pixels.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return RGBColor(0, 0, 0) }

        let xs = [max(1, Int(Double(w) * 0.016)),
                  w - 1 - Int(Double(w) * 0.016)]
        let ys = [max(1, Int(Double(h) * 0.012)),
                  h - 1 - Int(Double(h) * 0.012)]
        var points: [(Int, Int)] = []
        for x in xs {
            for fy in [0.25, 0.5, 0.75] { points.append((x, Int(Double(h) * fy))) }
        }
        for y in ys {
            for fx in [0.25, 0.5, 0.75] { points.append((Int(Double(w) * fx), y)) }
        }
        var rs: [Int] = [], gs: [Int] = [], bs: [Int] = []
        for (x, y) in points {
            let i = (y * w + x) * 4
            let a = Int(pixels[i + 3])
            if a > 200 {
                // Undo premultiplication to recover the source channels.
                rs.append(min(255, Int(pixels[i]) * 255 / a))
                gs.append(min(255, Int(pixels[i + 1]) * 255 / a))
                bs.append(min(255, Int(pixels[i + 2]) * 255 / a))
            }
        }
        if rs.isEmpty { return RGBColor(0, 0, 0) }
        func median(_ values: [Int]) -> Int {
            let sorted = values.sorted()
            let mid = sorted.count / 2
            return sorted.count % 2 == 1
                ? sorted[mid]
                : (sorted[mid - 1] + sorted[mid]) / 2
        }
        return RGBColor(median(rs), median(gs), median(bs))
    }

    // MARK: - Cache files

    private struct FaceMeta: Codable { var color: [Int] }

    private func loadCached(image url: URL, meta: URL) -> PreparedFace? {
        guard let color = readMetaColor(meta), let image = loadPNG(url) else {
            return nil
        }
        return PreparedFace(image: image, borderColor: color)
    }

    private func readMetaColor(_ url: URL) -> RGBColor? {
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(FaceMeta.self, from: data),
              meta.color.count == 3 else { return nil }
        return RGBColor(meta.color[0], meta.color[1], meta.color[2])
    }

    private func writeMetaColor(_ color: RGBColor, to url: URL) throws {
        let data = try JSONEncoder().encode(
            FaceMeta(color: [color.r, color.g, color.b]))
        try data.write(to: url)
    }

    private func loadPNG(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func savePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ImagePipelineError.message(
                "[PPG:CACHE-CREATE] Could not create PNG at \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ImagePipelineError.message(
                "[PPG:CACHE-WRITE] Could not write PNG at \(url.path)")
        }
    }
}
