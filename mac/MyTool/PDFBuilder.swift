//
//  PDFBuilder.swift
//  Version 23
//  Proxy Printer (native port) — Phase 1 engine
//
//  File backed PDF assembly with CGPDFContext, mirroring the Python
//  layout exactly:
//    - Paper from Letter to tabloid and A3, plus custom
//      sizes; the grid fits the sheet (3x3 on Letter size
//      sheets, 4x4 on the big ones), centered
//    - true card size 63x88 mm, 3 mm gaps measured art edge to art edge
//    - 1 mm buffer per card filled with the card's own sampled border
//      color (calibration boosted, like the card image)
//    - blue dotted guide at true card size, following the 3 mm rounded
//      corners; cut on the dots for an exact size card
//    - fronts in deck order; two sided backs go in the highest free slot
//      of the final page, or on a fresh page (see LayoutPlan)
//
//  Pages are written as they are finished and images are drawn from the
//  caller's per page working set, so memory stays flat at any scale.
//  The caller passes the same CGImage instance for every placement of a
//  face within a page, which is Quartz's cue to store that image once
//  for the page instead of once per placement.
//

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Compression
import Darwin

public let pointsPerMM: Double = 72.0 / 25.4
public let cardWidthPoints: Double = 63 * pointsPerMM
public let cardHeightPoints: Double = 88 * pointsPerMM
public let cardCornerRadiusPoints: Double = 3 * pointsPerMM
public nonisolated enum PaperSize: Hashable, Sendable {
    case letter
    case a4
    case legal
    case tabloid
    case a3
    case custom(widthMM: Double, heightMM: Double)

    public var size: CGSize {
        switch self {
        case .letter: return CGSize(width: 612.0, height: 792.0)
        case .a4: return CGSize(width: 595.28, height: 841.89)
        case .legal: return CGSize(width: 612.0, height: 1008.0)
        case .tabloid: return CGSize(width: 792.0, height: 1224.0)
        case .a3: return CGSize(width: 841.89, height: 1190.55)
        case .custom(let widthMM, let heightMM):
            return CGSize(width: widthMM * pointsPerMM,
                          height: heightMM * pointsPerMM)
        }
    }

    public var isCustom: Bool {
        switch self {
        case .custom: return true
        default: return false
        }
    }

    /// How many card columns fit across the sheet at the
    /// standard 3mm gap with a 2mm edge minimum: three on
    /// Letter width sheets, four on tabloid and A3.
    public var gridColumns: Int {
        let widthMM = Double(size.width) / pointsPerMM
        let fit = (widthMM - 4.0 + 3.0) / (63.0 + 3.0)
        return max(1, Int(fit))
    }

    /// How many card rows fit down the sheet, the same
    /// fit worked out along the height.
    public var gridRows: Int {
        let heightMM = Double(size.height) / pointsPerMM
        let fit = (heightMM - 4.0 + 3.0) / (88.0 + 3.0)
        return max(1, Int(fit))
    }
}

/// A printer's unprintable border, taken from the maker's
/// own spec and widened by a paper feed tolerance, so the
/// layout can promise that no card edge ever lands where
/// the printer cannot reach. Floors are the closest a card
/// edge may sit to each side of the sheet, in millimeters.
public nonisolated enum SafeAreaProfile: String, CaseIterable, Sendable {
    case none
    case canonInkjet

    public var floors: (top: Double, bottom: Double,
                        left: Double, right: Double)? {
        switch self {
        case .none:
            return nil
        case .canonInkjet:
            // Canon MAXIFY Letter spec: the printer cannot
            // reach the top 3.0mm, bottom 5.0mm, left 6.4mm
            // or right 6.3mm of the sheet. Each floor adds
            // about 1.5mm of feed tolerance on top of that.
            return (top: 4.5, bottom: 6.5, left: 7.9, right: 7.8)
        }
    }
}

/// How much of each edge of a sheet a printer cannot
/// reach, in millimeters, as its driver reported it
/// (Fit to my printer). The layout widens the reach by
/// a millimeter of paper feed tolerance before using
/// it as floors; see PrintSettings.effectiveFloors.
public nonisolated struct PrinterMargins: Hashable, Sendable {
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double

    public init(top: Double, bottom: Double,
                left: Double, right: Double) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }
}

public nonisolated struct PrintSettings {
    public var paper: PaperSize = .letter
    /// The grid the chosen paper holds.
    public var columns: Int {
        guard let floors = effectiveFloors else {
            return paper.gridColumns
        }
        let paperW = Double(paper.size.width) / pointsPerMM
        return Self.fitCount(
            room: paperW - floors.left - floors.right,
            card: 63.0)
    }
    public var rows: Int {
        guard let floors = effectiveFloors else {
            return paper.gridRows
        }
        let paperH = Double(paper.size.height) / pointsPerMM
        return Self.fitCount(
            room: paperH - floors.top - floors.bottom,
            card: 88.0)
    }
    public var cardsPerPage: Int { columns * rows }

    /// How many cards of the given size fit in the room
    /// left inside the floors, gaps squeezed to their
    /// 0.5mm minimum: the Windows layout's fit rule. At
    /// least one always fits; the margin clamps then
    /// center it as well as the sheet allows.
    private static func fitCount(room: Double,
                                 card: Double) -> Int {
        if room < card { return 1 }
        return max(1, Int((room + 0.5) / (card + 0.5)))
    }
    public var gapMM: Double = 3.0
    public var bufferMM: Double = 1.0
    /// Moves the whole card grid up the page by this much,
    /// for printers whose printable area clips the bottom
    /// of the sheet. Zero keeps the grid centered.
    public var shiftUpMM: Double = 0
    /// Keeps every card edge inside the chosen printer's
    /// printable area; see SafeAreaProfile.
    public var safeArea: SafeAreaProfile = .none
    /// The reach a printer's driver reported (Fit to
    /// my printer). When set, the cards stay inside it,
    /// whatever the safe area profile says.
    public var printerMargins: PrinterMargins? = nil

    /// The edges every card must stay inside, when
    /// anything sets them: the driver's reach widened
    /// by a millimeter of paper feed tolerance, or the
    /// safe area profile's floors. Nil means no floors.
    public var effectiveFloors: (top: Double, bottom: Double,
                                 left: Double,
                                 right: Double)? {
        if let margins = printerMargins {
            return (top: margins.top + 1.0,
                    bottom: margins.bottom + 1.0,
                    left: margins.left + 1.0,
                    right: margins.right + 1.0)
        }
        return safeArea.floors
    }
    /// Pushes the row and column gaps out to the most the
    /// sheet allows, each axis separately, for maximum
    /// room to cut.
    public var maximizeGap: Bool = false
    /// Draws the dotted cutting guides with a heavier
    /// stroke and longer dashes, easier to follow with a
    /// blade. The cut line stays the center of the stroke,
    /// so card size does not change.
    public var thickGuides: Bool = false
    public var showGuides: Bool = true
    /// Used to boost buffer and guide colors, matching the image boost.
    public var calibration: InkCalibration = .none
    /// The proxy mark drawn on every face; see ProxyMark.
    public var proxyMark: ProxyMark = .none
    public init() {}

    /// The gaps the layout actually uses, in mm, one per
    /// axis: the rows are squeezed by the sheet's height
    /// and the columns by its width, and the two rarely
    /// allow the same number. With a safe area profile on,
    /// each axis is capped by that axis's floors; without
    /// one, a 2mm sheet edge minimum caps them. Max gap
    /// mode pushes each axis out to its own cap instead of
    /// the asked for gap, so the columns can open wide even
    /// when the rows cannot. Cards never change size.
    public func resolvedGapsMM() -> (row: Double, column: Double) {
        let paperW = Double(paper.size.width) / pointsPerMM
        let paperH = Double(paper.size.height) / pointsPerMM
        let cardW = cardWidthPoints / pointsPerMM
        let cardH = cardHeightPoints / pointsPerMM
        let topEdge = effectiveFloors?.top ?? 2.0
        let bottomEdge = effectiveFloors?.bottom ?? 2.0
        let leftEdge = effectiveFloors?.left ?? 2.0
        let rightEdge = effectiveFloors?.right ?? 2.0
        let maxRow = rows > 1
            ? (paperH - topEdge - bottomEdge
               - Double(rows) * cardH) / Double(rows - 1)
            : gapMM
        let maxColumn = columns > 1
            ? (paperW - leftEdge - rightEdge
               - Double(columns) * cardW) / Double(columns - 1)
            : gapMM
        if maximizeGap {
            return (row: max(0.5, maxRow),
                    column: max(0.5, maxColumn))
        }
        return (row: max(0.5, min(gapMM, maxRow)),
                column: max(0.5, min(gapMM, maxColumn)))
    }

    /// Where the top row's card edge lands, in mm from the
    /// top of the sheet: centered, moved by Shift up, then
    /// held inside the safe area floors when a profile is
    /// on, so Shift up stops at the safe line instead of
    /// pushing art off the top of the sheet.
    public func resolvedTopMarginMM() -> Double {
        let gap = resolvedGapsMM().row
        let paperH = Double(paper.size.height) / pointsPerMM
        let gridH = Double(rows)
                * (cardHeightPoints / pointsPerMM)
            + Double(rows - 1) * gap
        var top = (paperH - gridH) / 2 - shiftUpMM
        if let floors = effectiveFloors {
            top = min(max(top, floors.top),
                      paperH - gridH - floors.bottom)
        }
        return top
    }

    /// Where the left column's card edge lands, in mm from
    /// the left of the sheet: centered, then held inside
    /// the safe area floors when a profile is on.
    public func resolvedLeftMarginMM() -> Double {
        let gap = resolvedGapsMM().column
        let paperW = Double(paper.size.width) / pointsPerMM
        let gridW = Double(columns)
                * (cardWidthPoints / pointsPerMM)
            + Double(columns - 1) * gap
        var left = (paperW - gridW) / 2
        if let floors = effectiveFloors {
            left = min(max(left, floors.left),
                       paperW - gridW - floors.right)
        }
        return left
    }
}


// MARK: - Proxy marks

/// What kind of proxy mark a build draws on every face.
public nonisolated enum ProxyMarkKind: String, CaseIterable, Sendable {
    case none
    case label
    case border
    case logo
}

/// Where on the art a label or logo sits: the nine spots
/// of a three by three grid inside the art window.
public nonisolated enum MarkPosition: Int, CaseIterable, Sendable {
    case topLeft = 0
    case top
    case topRight
    case middleLeft
    case middle
    case middleRight
    case bottomLeft
    case bottom
    case bottomRight
}

/// The lettering of the PROXY label: only the fonts the
/// app ships.
public nonisolated enum MarkFont: String, CaseIterable, Sendable {
    case cinzel
    case cinzelDecorative
    case fellEnglish
    case fellEnglishItalic
    case faerieMoot

    /// The bundled face's PostScript name. Cinzel and
    /// Cinzel Decorative ride their bold faces, as the
    /// Windows build letters its label.
    public var fontName: String {
        switch self {
        case .cinzel: return "Cinzel-Bold"
        case .cinzelDecorative: return "CinzelDecorative-Bold"
        case .fellEnglish: return "IM_FELL_English_Roman"
        case .fellEnglishItalic: return "IM_FELL_English_Italic"
        case .faerieMoot: return "FaerieMootOrnate"
        }
    }
}

/// One proxy mark: what it is, its color (as chosen,
/// before ink calibration), where it sits, how wide a
/// border band is, and the label's lettering.
public nonisolated struct ProxyMark: Equatable, Sendable {
    public var kind: ProxyMarkKind
    public var color: RGBColor
    public var position: MarkPosition
    public var borderMM: Double
    public var font: MarkFont

    public init(kind: ProxyMarkKind = .none,
                color: RGBColor = RGBColor(196, 28, 44),
                position: MarkPosition = .topLeft,
                borderMM: Double = 3.0,
                font: MarkFont = .cinzel) {
        self.kind = kind
        self.color = color
        self.position = position
        self.borderMM = borderMM
        self.font = font
    }

    public static let none = ProxyMark()
}

/// Draws proxy marks over card faces, mirroring the
/// Windows build's ProxyMarkArt: the label and the logo
/// sit inside the art window of a modern frame (5mm in
/// from the left, 10.5mm down from the top, 53 by 38mm),
/// inset 2.5mm from its edges, and each gets a thin halo,
/// white, or dark when the mark color is light, so it
/// reads on busy art. A border band fills the card edge
/// inward; its inner corners round at 1mm.
nonisolated enum ProxyMarkDrawing {

    private static let artX = 5.0
    private static let artY = 10.5
    private static let artW = 53.0
    private static let artH = 38.0
    private static let inset = 2.5
    private static let logoMM = 15.0

    /// The halo behind a mark: dark for light colors,
    /// white for everything else.
    static func haloColor(for color: RGBColor) -> CGColor {
        let luminance = 0.299 * Double(color.r)
            + 0.587 * Double(color.g)
            + 0.114 * Double(color.b)
        if luminance > 170 {
            return CGColor(red: 20 / 255, green: 20 / 255,
                           blue: 20 / 255, alpha: 150 / 255)
        }
        return CGColor(red: 1, green: 1, blue: 1,
                       alpha: 215 / 255)
    }

    /// Where a mark of the given size lands in card
    /// millimeters, measured from the card's top left.
    static func place(size: (width: Double, height: Double),
                      position: MarkPosition)
        -> (x: Double, y: Double) {
        let col = position.rawValue % 3
        let row = position.rawValue / 3
        let x = col == 0 ? artX + inset
            : col == 1 ? artX + (artW - size.width) / 2
            : artX + artW - inset - size.width
        let y = row == 0 ? artY + inset
            : row == 1 ? artY + (artH - size.height) / 2
            : artY + artH - inset - size.height
        return (x, y)
    }

    /// Draws the mark over one card, in the page builders'
    /// space: points, origin at the page's lower left, the
    /// card at cardRect.
    static func draw(in ctx: CGContext, cardRect: CGRect,
                     mark: ProxyMark, calibration: InkCalibration) {
        let ink = calibration.boosted(mark.color)
        switch mark.kind {
        case .none:
            return
        case .border:
            let bandMM = min(max(mark.borderMM, 0.5), 12)
            let band = bandMM * pointsPerMM
            let inner = cardRect.insetBy(dx: band, dy: band)
            let round = 1.0 * pointsPerMM
            ctx.saveGState()
            ctx.setFillColor(ink.cgColor)
            ctx.addPath(CGPath(rect: cardRect, transform: nil))
            ctx.addPath(CGPath(roundedRect: inner,
                               cornerWidth: round,
                               cornerHeight: round,
                               transform: nil))
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        case .label, .logo:
            ctx.saveGState()
            ctx.translateBy(x: cardRect.minX, y: cardRect.maxY)
            ctx.scaleBy(x: CGFloat(pointsPerMM),
                        y: CGFloat(-pointsPerMM))
            if mark.kind == .label {
                drawLabel(in: ctx, mark: mark, ink: ink)
            } else {
                drawLogo(in: ctx, mark: mark, ink: ink)
            }
            ctx.restoreGState()
        }
    }

    private static func drawLabel(in ctx: CGContext,
                                  mark: ProxyMark,
                                  ink: RGBColor) {
        let art = labelArt(for: mark.font)
        let spot = place(size: (art.width, art.height),
                         position: mark.position)
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(spot.x), y: CGFloat(spot.y))
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(haloColor(for: mark.color))
        ctx.setLineWidth(1.0)
        ctx.addPath(art.path)
        ctx.strokePath()
        ctx.setFillColor(ink.cgColor)
        ctx.addPath(art.path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawLogo(in ctx: CGContext,
                                 mark: ProxyMark,
                                 ink: RGBColor) {
        let spot = place(size: (logoMM, logoMM),
                         position: mark.position)
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(spot.x), y: CGFloat(spot.y))
        let k = logoMM / 240.0
        ctx.scaleBy(x: CGFloat(k), y: CGFloat(k))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(haloColor(for: mark.color))
        ctx.setLineWidth(13)
        ctx.addPath(logoPath)
        ctx.strokePath()
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(6)
        ctx.addPath(logoPath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: The label's letters

    private static var labelCache:
        [MarkFont: (path: CGPath, width: Double, height: Double)] = [:]

    /// The word PROXY as one path, sized the Windows way:
    /// every font is scaled so its capital height is 5mm,
    /// then narrowed if it runs wider than 46mm. The
    /// path's origin is the ink's top left corner, in mm.
    static func labelArt(for font: MarkFont)
        -> (path: CGPath, width: Double, height: Double) {
        if let hit = labelCache[font] { return hit }
        let trial = CTFontCreateWithName(font.fontName as CFString,
                                         100, nil)
        let capRatio = Double(CTFontGetCapHeight(trial)) / 100.0
        var em = capRatio > 0.3 ? 5.0 / capRatio : 7.0

        func measure(_ size: Double) -> (CTFont, Double) {
            let face = CTFontCreateWithName(
                font.fontName as CFString, CGFloat(size), nil)
            var chars: [UniChar] = Array("PROXY".utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            CTFontGetGlyphsForCharacters(face, &chars, &glyphs,
                                         chars.count)
            var advances = [CGSize](repeating: .zero,
                                    count: chars.count)
            CTFontGetAdvancesForGlyphs(face, .horizontal, glyphs,
                                       &advances, chars.count)
            var width = 0.0
            for advance in advances { width += Double(advance.width) }
            return (face, width)
        }

        var (face, width) = measure(em)
        if width > 46.0 {
            em *= 46.0 / width
            (face, width) = measure(em)
        }
        let capMM = Double(CTFontGetCapHeight(face))

        var chars: [UniChar] = Array("PROXY".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        CTFontGetGlyphsForCharacters(face, &chars, &glyphs,
                                     chars.count)
        var advances = [CGSize](repeating: .zero, count: chars.count)
        CTFontGetAdvancesForGlyphs(face, .horizontal, glyphs,
                                   &advances, chars.count)
        let path = CGMutablePath()
        var x = 0.0
        for index in glyphs.indices {
            var transform = CGAffineTransform(
                a: 1, b: 0, c: 0, d: -1,
                tx: CGFloat(x), ty: CGFloat(capMM))
            if let glyphPath = CTFontCreatePathForGlyph(
                face, glyphs[index], &transform) {
                path.addPath(glyphPath)
            }
            x += Double(advances[index].width)
        }
        let art = (path: path as CGPath, width: width, height: capMM)
        labelCache[font] = art
        return art
    }

    // MARK: The fox logo path

    /// The sleeping fox between two trees, inside a ring:
    /// stroke paths in a 240 by 240 box, the same path
    /// data the Windows build and the repo's logo file use.
    static let logoPath: CGPath = buildLogoPath()

    private static let logoPathData = "M 44.8,208.8 C 45.6,184.8 47.2,159.2 51.2,127.2 M 50.4,133.6 C 57.6,117.6 67.2,104.8 80,95.2 M 51.2,127.2 C 51.2,114.4 52.8,101.6 56,92 M 45.6,194.4 C 37.6,191.2 31.2,197.6 35.2,203.2 C 38.4,208 45.6,204.8 43.2,199.2 M 45.6,186.4 C 54.4,184 60,190.4 56,195.2 C 52.8,198.4 48,195.2 50.4,191.2 M 56.6,120 C 48,125.5 25.6,124.7 20.4,113.6 C 4.9,109.2 9.8,92.5 25.2,97.1 C 11.1,89.4 19.5,74.2 33.5,82.1 C 21.4,71.5 32.9,58.5 44.9,69.2 C 35.3,56.3 49.4,46 58.7,59.1 C 52.3,44.4 68.2,37.5 74.5,52.3 C 71.4,36.5 88.4,33.2 91.4,49 C 91.7,33 109.1,33.5 108.5,49.6 C 115,57.3 109.6,79.1 103.4,86 C 100.8,93 90.8,93.5 87.5,86.8 C 87.7,94.2 78.7,98.5 73.1,93.5 C 76.1,100.3 69.3,107.6 62.3,105.2 C 67.6,110.3 64,119.7 56.6,120 Z M 195.2,208.8 C 194.4,184.8 192.8,159.2 188.8,127.2 M 189.6,133.6 C 182.4,117.6 172.8,104.8 160,95.2 M 188.8,127.2 C 188.8,114.4 187.2,101.6 184,92 M 194.4,194.4 C 202.4,191.2 208.8,197.6 204.8,203.2 C 201.6,208 194.4,204.8 196.8,199.2 M 194.4,186.4 C 185.6,184 180,190.4 184,195.2 C 187.2,198.4 192,195.2 189.6,191.2 M 183.4,120 C 192,125.5 214.4,124.7 219.6,113.6 C 235.1,109.2 230.2,92.5 214.8,97.1 C 228.9,89.4 220.5,74.2 206.5,82.1 C 218.6,71.5 207.1,58.5 195.1,69.2 C 204.7,56.3 190.6,46 181.3,59.1 C 187.7,44.4 171.8,37.5 165.5,52.3 C 168.6,36.5 151.6,33.2 148.6,49 C 148.3,33 130.9,33.5 131.5,49.6 C 125,57.3 130.4,79.1 136.6,86 C 139.2,93 149.2,93.5 152.5,86.8 C 152.3,94.2 161.3,98.5 166.9,93.5 C 163.9,100.3 170.7,107.6 177.7,105.2 C 172.4,110.3 176,119.7 183.4,120 Z M 118.1,143 C 142.3,127.5 180.4,137.8 182.1,172.4 C 183.8,196.6 164.8,210.4 137.2,210.4 C 109.5,210.4 80.1,208.7 66.3,196.6 C 60.3,190.5 62.8,183.6 70.6,183.6 C 92.2,187.1 119.9,189.7 140.6,185.3 C 156.2,181.9 164.8,173.2 164.8,162 M 81.9,186.2 C 76.7,192.3 76.7,199.2 82.7,205.2 M 100.9,148.2 L 107.8,122.3 L 119.9,143.9 M 82.7,156.8 L 73.2,132.6 L 93.1,149.1 M 106,134.4 L 110.4,143.9 M 77.5,143 L 85.3,150.8 M 93.1,149.1 C 95.7,147.3 98.3,147.3 100.9,148.2 M 82.7,156.8 C 76.7,164.6 68,170.7 59.4,175.8 C 64.6,181 80.1,182.8 95.7,180.2 M 119.9,143.9 C 125.1,156 121.6,170.7 107.8,178.4 C 103.5,180.2 99.1,181 95.7,180.2 M 85.3,164.6 C 88.8,168.1 94,168.1 97.4,164.6 M 120,6 A 114,114 0 1 1 119.9,6 Z"

    private static func buildLogoPath() -> CGPath {
        let path = CGMutablePath()
        var tokens: [String] = []
        var current = ""
        for ch in logoPathData {
            if ch.isLetter {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                tokens.append(String(ch))
            } else if ch == "," || ch == " " {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }

        var i = 0
        var command = ""
        func number() -> Double {
            let value = Double(tokens[i]) ?? 0
            i += 1
            return value
        }
        while i < tokens.count {
            let token = tokens[i]
            if token.count == 1, let first = token.first,
               first.isLetter {
                command = token
                i += 1
            }
            switch command {
            case "M":
                let x = number()
                let y = number()
                path.move(to: CGPoint(x: x, y: y))
                command = "L"
            case "L":
                let x = number()
                let y = number()
                path.addLine(to: CGPoint(x: x, y: y))
            case "C":
                let x1 = number()
                let y1 = number()
                let x2 = number()
                let y2 = number()
                let x = number()
                let y = number()
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: x1, y: y1),
                              control2: CGPoint(x: x2, y: y2))
            case "A":
                let rx = number()
                let ry = number()
                _ = number()
                let largeArc = number() > 0.5
                let sweep = number() > 0.5
                let x = number()
                let y = number()
                addArc(to: path, rx: rx, ry: ry,
                       largeArc: largeArc, sweep: sweep,
                       to: CGPoint(x: x, y: y))
            case "Z":
                path.closeSubpath()
                command = ""
            default:
                i += 1
            }
        }
        return path
    }

    /// An SVG elliptical arc, converted from its end
    /// point form to a center arc. The path space is
    /// y down, so a sweep arc runs through increasing
    /// angles in that space.
    private static func addArc(to path: CGMutablePath,
                               rx: Double, ry: Double,
                               largeArc: Bool, sweep: Bool,
                               to end: CGPoint) {
        let start = path.currentPoint
        var rx = abs(rx)
        var ry = abs(ry)
        if rx == 0 || ry == 0 {
            path.addLine(to: end)
            return
        }
        let x1 = Double(start.x)
        let y1 = Double(start.y)
        let x2 = Double(end.x)
        let y2 = Double(end.y)
        let dx = (x1 - x2) / 2
        let dy = (y1 - y2) / 2
        let lambda = dx * dx / (rx * rx) + dy * dy / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }
        let num = rx * rx * ry * ry
            - rx * rx * dy * dy - ry * ry * dx * dx
        let den = rx * rx * dy * dy + ry * ry * dx * dx
        var co = den > 0 ? sqrt(max(0, num / den)) : 0
        if largeArc == sweep { co = -co }
        let cxp = co * rx * dy / ry
        let cyp = -co * ry * dx / rx
        let cx = cxp + (x1 + x2) / 2
        let cy = cyp + (y1 + y2) / 2
        let ux = (dx - cxp) / rx
        let uy = (dy - cyp) / ry
        let vx = (-dx - cxp) / rx
        let vy = (-dy - cyp) / ry
        let startAngle = atan2(uy, ux)
        var delta = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        if sweep, delta < 0 { delta += 2 * Double.pi }
        if !sweep, delta > 0 { delta -= 2 * Double.pi }
        let center = CGPoint(x: cx, y: cy)
        if abs(delta) > 1.5 * Double.pi {
            path.addArc(center: center, radius: CGFloat(rx),
                        startAngle: CGFloat(startAngle),
                        endAngle: CGFloat(startAngle + delta / 2),
                        clockwise: delta < 0)
            path.addArc(center: center, radius: CGFloat(rx),
                        startAngle: CGFloat(startAngle + delta / 2),
                        endAngle: CGFloat(startAngle + delta),
                        clockwise: delta < 0)
        } else {
            path.addArc(center: center, radius: CGFloat(rx),
                        startAngle: CGFloat(startAngle),
                        endAngle: CGFloat(startAngle + delta),
                        clockwise: delta < 0)
        }
    }
}

/// Identifies one face of one printing.
public nonisolated struct FaceRef: Hashable {
    public var cardKey: String
    public var faceIndex: Int
    public init(set: String, collectorNumber: String, faceIndex: Int) {
        self.cardKey = "\(set.lowercased())|\(collectorNumber)"
        self.faceIndex = faceIndex
    }
}

/// The page plan: which faces land in which slots, computed before any
/// image work so the builder can assemble page by page.
public nonisolated struct LayoutPlan {
    /// Front faces per page, in slot order (slot = row * columns + col).
    public var pages: [[FaceRef]]
    /// Back faces by page index, then slot.
    public var backPlacements: [Int: [Int: FaceRef]]
    /// Card names for the backs, in the order they were placed (summary).
    public var backNames: [String]
    public var totalPlacements: Int
    public var pageCount: Int { pages.count }
    /// Back to back plans: the page where the front/back pairs
    /// begin, or -1 when the plan has none.
    public var duplexStartPage: Int
    /// Sheets that print double sided in a back to back plan:
    /// every front page in the duplex section has a back page
    /// behind it.
    public var duplexSheets: Int {
        duplexStartPage < 0 ? 0 : (pageCount - duplexStartPage) / 2
    }

    /// Faithful port of the Python placement: backs fill the highest
    /// free slot of the final page; when it is full, a fresh page starts
    /// and its first back goes in slot 0 (later backs then fill that
    /// page from the last slot down, exactly as the Python loop behaves).
    public static func makePlan(fronts: [FaceRef],
                                backs: [(name: String, face: FaceRef)],
                                perPage: Int = 9)
        -> LayoutPlan {
        var pages: [[FaceRef]] = []
        var i = 0
        while i < fronts.count {
            pages.append(Array(fronts[i..<min(i + perPage, fronts.count)]))
            i += perPage
        }
        if pages.isEmpty { pages = [[]] }

        var backPlacements: [Int: [Int: FaceRef]] = [:]
        var backNames: [String] = []
        for back in backs {
            let pageIndex = pages.count - 1
            let frontCount = pages[pageIndex].count
            var placed = false
            var slot = perPage - 1
            while slot >= frontCount {
                if backPlacements[pageIndex]?[slot] == nil {
                    backPlacements[pageIndex, default: [:]][slot] = back.face
                    placed = true
                    break
                }
                slot -= 1
            }
            if !placed {
                pages.append([])
                backPlacements[pages.count - 1] = [0: back.face]
            }
            backNames.append(back.name)
        }
        return LayoutPlan(pages: pages, backPlacements: backPlacements,
                          backNames: backNames,
                          totalPlacements: fronts.count + backs.count,
                          duplexStartPage: -1)
    }

    /// Back to back: one sided cards fill the first pages;
    /// then every two sided copy gets a front page slot with
    /// its back on the next page, mirrored, so the sheet can
    /// print double sided and each two sided card cuts out
    /// as one piece.
    public static func makeBackToBack(
        singles: [FaceRef],
        twoSided: [(name: String, front: FaceRef, back: FaceRef)],
        perPage: Int = 9,
        columns: Int = 3)
        -> LayoutPlan {
        var pages: [[FaceRef]] = []
        var i = 0
        while i < singles.count {
            pages.append(Array(
                singles[i..<min(i + perPage, singles.count)]))
            i += perPage
        }
        var backPlacements: [Int: [Int: FaceRef]] = [:]
        var duplexStartPage = -1
        if !twoSided.isEmpty {
            duplexStartPage = pages.count
            var j = 0
            while j < twoSided.count {
                let chunk = Array(
                    twoSided[j..<min(j + perPage,
                                      twoSided.count)])
                pages.append(chunk.map { $0.front })
                pages.append([])
                var backs: [Int: FaceRef] = [:]
                for (slot, copy) in chunk.enumerated() {
                    backs[mirroredSlot(slot, columns: columns)] = copy.back
                }
                backPlacements[pages.count - 1] = backs
                j += perPage
            }
        }
        if pages.isEmpty { pages = [[]] }
        var backNames: [String] = []
        for copy in twoSided where !backNames.contains(copy.name) {
            backNames.append(copy.name)
        }
        return LayoutPlan(
            pages: pages, backPlacements: backPlacements,
            backNames: backNames,
            totalPlacements: singles.count + twoSided.count * 2,
            duplexStartPage: duplexStartPage)
    }

    /// The slot behind a slot when the sheet flips on its
    /// long edge: same row, column mirrored. The grid is
    /// centered, so the mirrored slot lines up with the front.
    public static func mirroredSlot(_ slot: Int,
                                    columns: Int = 3) -> Int {
        slot / columns * columns
            + (columns - 1 - slot % columns)
    }
}

/// Anything that assembles pages card by card: the PDF builder,
/// or the page image builder, which renders the same pages to
/// images and packs them into a zip instead.
nonisolated protocol PageBuilding: AnyObject {
    var onFaceDrawn: ((_ placed: Int, _ total: Int) -> Void)? { get set }
    var onPageFinished: ((_ page: Int, _ totalPages: Int) -> Void)? { get set }
    /// Set when a step failed quietly (the page assembly calls do
    /// not throw); the engine checks it after finish().
    var failureMessage: String? { get }
    func begin(totalPlacements: Int, pageCount: Int) throws
    func beginPage()
    func drawCard(slot: Int, face: PreparedFace)
    func endPage()
    func finish()
}

/// Page image encodings for the image builder.
nonisolated enum PageImageFormat {
    case png
    case jpeg
}

public nonisolated enum PDFBuilderError: Error, CustomStringConvertible {
    case message(String)
    public var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

public nonisolated final class PDFBuilder: PageBuilding {

    public var onFaceDrawn: ((_ placed: Int, _ total: Int) -> Void)?
    public var onPageFinished: ((_ page: Int, _ totalPages: Int) -> Void)?
    public var failureMessage: String? { nil }

    private let outputURL: URL
    private let settings: PrintSettings
    private let title: String

    private var context: CGContext?
    private var totalPlacements = 0
    private var totalPages = 0
    private var placedCount = 0
    private var finishedPages = 0

    private var pageWidth: Double { Double(settings.paper.size.width) }
    private var pageHeight: Double { Double(settings.paper.size.height) }
    private var gapXPoints: Double {
        settings.resolvedGapsMM().column * pointsPerMM
    }
    private var gapYPoints: Double {
        settings.resolvedGapsMM().row * pointsPerMM
    }
    private var bufferPoints: Double { settings.bufferMM * pointsPerMM }
    private var originX: Double {
        settings.resolvedLeftMarginMM() * pointsPerMM
    }
    private var topMargin: Double {
        settings.resolvedTopMarginMM() * pointsPerMM
    }

    public init(outputURL: URL, settings: PrintSettings, title: String) {
        self.outputURL = outputURL
        self.settings = settings
        self.title = title
    }

    /// The true size rect for a slot, in PDF coordinates (origin at the
    /// lower left, so row 0 of the grid is measured down from the top).
    public func slotRect(_ slot: Int) -> CGRect {
        let col = slot % settings.columns
        let row = slot / settings.columns
        let x = originX + Double(col) * (cardWidthPoints + gapXPoints)
        let topY = topMargin + Double(row) * (cardHeightPoints + gapYPoints)
        let y = pageHeight - topY - cardHeightPoints
        return CGRect(x: x, y: y, width: cardWidthPoints,
                      height: cardHeightPoints)
    }

    public func begin(totalPlacements: Int, pageCount: Int) throws {
        self.totalPlacements = totalPlacements
        self.totalPages = pageCount
        var mediaBox = CGRect(origin: .zero, size: settings.paper.size)
        let info: [CFString: Any] = [kCGPDFContextTitle: title]
        guard let ctx = CGContext(outputURL as CFURL, mediaBox: &mediaBox,
                                  info as CFDictionary) else {
            throw PDFBuilderError.message(
                "[PPG:PDF-CONTEXT] Could not create PDF context for \(outputURL.path)")
        }
        context = ctx
    }

    public func beginPage() {
        context?.beginPDFPage(nil)
    }

    public func drawCard(slot: Int, face: PreparedFace) {
        guard let ctx = context else { return }
        let rect = slotRect(slot)
        let calibration = settings.calibration

        // Buffer: the card's own border color, boosted like the image.
        let bufferColor = calibration.boosted(face.borderColor)
        ctx.setFillColor(bufferColor.cgColor)
        ctx.fill(rect.insetBy(dx: -bufferPoints, dy: -bufferPoints))

        ctx.draw(face.image, in: rect)

        if settings.proxyMark.kind != .none {
            ProxyMarkDrawing.draw(in: ctx, cardRect: rect,
                                  mark: settings.proxyMark,
                                  calibration: settings.calibration)
        }

        if settings.showGuides {
            let guide = calibration.boosted(RGBColor(13, 71, 255))
            let path = CGPath(roundedRect: rect,
                              cornerWidth: cardCornerRadiusPoints,
                              cornerHeight: cardCornerRadiusPoints,
                              transform: nil)
            ctx.setStrokeColor(guide.cgColor)
            ctx.setLineWidth(settings.thickGuides ? 2.2 : 0.7)
            ctx.setLineDash(phase: 0,
                            lengths: settings.thickGuides
                                ? [3.2, 2.2] : [1.6, 1.6])
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        placedCount += 1
        onFaceDrawn?(placedCount, totalPlacements)
    }

    public func endPage() {
        context?.endPDFPage()
        finishedPages += 1
        onPageFinished?(finishedPages, totalPages)
    }

    /// Closes the PDF context, which flushes the file to disk.
    public func finish() {
        if let ctx = context {
            ctx.closePDF()
        }
        context = nil
    }
}

/// Assembles the same pages as PDFBuilder, but renders each one
/// to a full resolution image instead: PNG for the highest
/// quality (lossless, the exact pixels, no PDF compression in
/// the way), stitched into one tall file, or JPEG at a chosen
/// quality when a small file matters more, its pages packed
/// into a zip. Pages render one at a time, so memory stays
/// flat like the PDF path either way.
nonisolated final class ImagePageBuilder: PageBuilding {

    var onFaceDrawn: ((_ placed: Int, _ total: Int) -> Void)?
    var onPageFinished: ((_ page: Int, _ totalPages: Int) -> Void)?
    var onStitchProgress: ((_ done: Int, _ total: Int) -> Void)?
    var onVerifyProgress: ((_ done: Int, _ total: Int) -> Void)?
    /// Polled inside the long synchronous stretches (the
    /// stitch and the verification pass), so Cancel works
    /// there too instead of only between faces and pages.
    var shouldCancel: (() -> Bool)?
    private(set) var wasCancelled = false
    private(set) var failureMessage: String?

    private let outputURL: URL
    private let settings: PrintSettings
    private let scale: Int
    private let format: PageImageFormat
    private let jpegQuality: Double

    private var context: CGContext?
    private var tempDirectory: URL?
    private var pageURLs: [URL] = []
    private var totalPlacements = 0
    private var totalPages = 0
    private var placedCount = 0
    private var finishedPages = 0

    private var pageWidth: Double { Double(settings.paper.size.width) }
    private var pageHeight: Double { Double(settings.paper.size.height) }
    private var gapXPoints: Double {
        settings.resolvedGapsMM().column * pointsPerMM
    }
    private var gapYPoints: Double {
        settings.resolvedGapsMM().row * pointsPerMM
    }
    private var bufferPoints: Double { settings.bufferMM * pointsPerMM }
    private var pixelsPerPoint: Double { Double(scale) * 300.0 / 72.0 }
    private var originX: Double {
        settings.resolvedLeftMarginMM() * pointsPerMM
    }
    private var topMargin: Double {
        settings.resolvedTopMarginMM() * pointsPerMM
    }

    init(outputURL: URL, settings: PrintSettings, scale: Int,
         format: PageImageFormat, jpegQuality: Double) {
        self.outputURL = outputURL
        self.settings = settings
        self.scale = scale
        self.format = format
        self.jpegQuality = jpegQuality
    }

    /// Same slot math as the PDF builder, in points; the page
    /// context is pre-scaled to pixels, and its origin sits at
    /// the lower left just like PDF space.
    func slotRect(_ slot: Int) -> CGRect {
        let col = slot % settings.columns
        let row = slot / settings.columns
        let x = originX + Double(col) * (cardWidthPoints + gapXPoints)
        let topY = topMargin + Double(row) * (cardHeightPoints + gapYPoints)
        let y = pageHeight - topY - cardHeightPoints
        return CGRect(x: x, y: y, width: cardWidthPoints,
                      height: cardHeightPoints)
    }

    func begin(totalPlacements: Int, pageCount: Int) throws {
        self.totalPlacements = totalPlacements
        self.totalPages = pageCount
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProxyPrintPages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        tempDirectory = dir
    }

    func beginPage() {
        let widthPx = Int((pageWidth * pixelsPerPoint).rounded())
        let heightPx = Int((pageHeight * pixelsPerPoint).rounded())
        guard let ctx = CGContext(
            data: nil, width: widthPx, height: heightPx,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            failureMessage = "[PPG:PAGE-CREATE] Could not create an image page."
            return
        }
        ctx.scaleBy(x: CGFloat(pixelsPerPoint),
                    y: CGFloat(pixelsPerPoint))
        // The paper itself: plain white under everything.
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pageWidth,
                        height: pageHeight))
        context = ctx
    }

    func drawCard(slot: Int, face: PreparedFace) {
        guard let ctx = context else { return }
        let rect = slotRect(slot)
        let calibration = settings.calibration

        let bufferColor = calibration.boosted(face.borderColor)
        ctx.setFillColor(bufferColor.cgColor)
        ctx.fill(rect.insetBy(dx: -bufferPoints, dy: -bufferPoints))

        ctx.draw(face.image, in: rect)

        if settings.proxyMark.kind != .none {
            ProxyMarkDrawing.draw(in: ctx, cardRect: rect,
                                  mark: settings.proxyMark,
                                  calibration: settings.calibration)
        }

        if settings.showGuides {
            let guide = calibration.boosted(RGBColor(13, 71, 255))
            let path = CGPath(roundedRect: rect,
                              cornerWidth: cardCornerRadiusPoints,
                              cornerHeight: cardCornerRadiusPoints,
                              transform: nil)
            ctx.setStrokeColor(guide.cgColor)
            ctx.setLineWidth(settings.thickGuides ? 2.2 : 0.7)
            ctx.setLineDash(phase: 0,
                            lengths: settings.thickGuides
                                ? [3.2, 2.2] : [1.6, 1.6])
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        placedCount += 1
        onFaceDrawn?(placedCount, totalPlacements)
    }

    func endPage() {
        defer { context = nil }
        guard let ctx = context, let dir = tempDirectory else { return }
        finishedPages += 1
        if let image = ctx.makeImage() {
            // Pages stage as PNG whatever the final format:
            // lossless intermediates, so a JPEG build encodes
            // once, at the end, from full quality pixels
            // instead of re encoding an already compressed
            // page.
            let url = dir.appendingPathComponent(
                String(format: "page-%03d.png", finishedPages))
            if let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString,
                1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                if CGImageDestinationFinalize(dest) {
                    pageURLs.append(url)
                } else if failureMessage == nil {
                    failureMessage =
                        "[PPG:PAGE-WRITE] Could not write page \(finishedPages)."
                }
            } else if failureMessage == nil {
                failureMessage =
                    "[PPG:PAGE-WRITE] Could not write page \(finishedPages)."
            }
        }
        onPageFinished?(finishedPages, totalPages)
    }

    /// Finishes the output file and clears the temporary page
    /// files away. Both image formats stitch their pages
    /// into one tall file: PNG through the hand rolled
    /// writer, JPEG through ImageIO off a mapped canvas.
    func finish() {
        guard let dir = tempDirectory else { return }
        defer {
            try? FileManager.default.removeItem(at: dir)
            tempDirectory = nil
        }
        if format == .png {
            do {
                try stitchPages()
            } catch is CancellationError {
                wasCancelled = true
            } catch {
                if failureMessage == nil {
                    failureMessage =
                        "Could not stitch the PNG: \(error)"
                }
            }
            return
        }
        do {
            try stitchJPEG()
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            if failureMessage == nil {
                failureMessage =
                    "Could not stitch the JPEG: \(error)"
            }
        }
    }

    /// Stitches the finished page PNGs into one tall PNG at
    /// the output URL: the pages stacked top to bottom, each
    /// at its exact rendered size, with the render DPI written
    /// into the file so print software can place it at true
    /// size. Rows stream through the compressor one page at a
    /// time, so memory stays flat even at 1800 DPI.
    private func stitchPages() throws {
        guard !pageURLs.isEmpty else {
            throw PDFBuilderError.message("[PPG:STITCH-EMPTY] No pages to stitch.")
        }
        func loadImage(_ url: URL) throws -> CGImage {
            guard let source = CGImageSourceCreateWithURL(
                    url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(
                    source, 0, nil)
            else {
                throw PDFBuilderError.message(
                    "[PPG:PAGE-READBACK] Could not read back a finished page.")
            }
            return image
        }
        let firstImage = try loadImage(pageURLs[0])
        let width = firstImage.width
        let height = firstImage.height
        let totalHeight = height * pageURLs.count

        FileManager.default.createFile(atPath: outputURL.path,
                                       contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        var writer = PNGChunkWriter(handle: handle)
        try handle.write(contentsOf: Data(
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        func bigEndian(_ value: UInt32) -> [UInt8] {
            [UInt8((value >> 24) & 0xFF),
             UInt8((value >> 16) & 0xFF),
             UInt8((value >> 8) & 0xFF),
             UInt8(value & 0xFF)]
        }
        var ihdr = bigEndian(UInt32(width))
            + bigEndian(UInt32(totalHeight))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])
        try writer.writeChunk(type: "IHDR", data: ihdr)

        // Resolution: the render DPI, so the file knows its
        // own true size in print software that honors it.
        let ppm = UInt32((Double(scale) * 300.0 / 0.0254).rounded())
        var phys = bigEndian(ppm) + bigEndian(ppm)
        phys.append(1)
        try writer.writeChunk(type: "pHYs", data: phys)

        let compressor = try PNGCompressor()
        // The zlib header goes in first; the compressor's
        // raw deflate follows, and its Adler-32 closes the
        // stream after the tail drains.
        var idat: [UInt8] = [0x78, 0x9C]
        idat.reserveCapacity(1 << 20)
        func collect(_ bytes: [UInt8]) throws {
            idat.append(contentsOf: bytes)
            if idat.count >= (1 << 20) {
                try writer.writeChunk(type: "IDAT", data: idat)
                idat.removeAll(keepingCapacity: true)
            }
        }

        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        for (pageIndex, url) in pageURLs.enumerated() {
            // One page at a time, and let each page's decode
            // go when its rows are in: at full scale a single
            // page is over a gigabyte of pixels.
            try autoreleasepool {
            let image = try loadImage(url)
            guard image.width == width, image.height == height
            else {
                throw PDFBuilderError.message(
                    "[PPG:PAGE-SIZE] A finished page had the wrong size.")
            }
            guard let ctx = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast
                    .rawValue),
                  let raw = ctx.data
            else {
                throw PDFBuilderError.message(
                    "[PPG:PAGE-UNPACK] Could not unpack a finished page.")
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width,
                                       height: height))
            let base = raw.assumingMemoryBound(to: UInt8.self)
            // The context is free to pad its rows past the
            // width asked for, so step by the stride it
            // actually used, not the assumed one. Stepping
            // by the assumed stride drifts a little further
            // on every row and scrambles the picture while
            // the file stays perfectly valid.
            let rowStride = ctx.bytesPerRow
            // Rows come out of the context in the image's
            // own top first order (the first stitch read
            // them in the opposite order on the theory that
            // memory starts at the bottom, and the page came
            // out upside down; the screenshot settled it).
            var row: [UInt8] = []
            row.reserveCapacity(bytesPerRow + 1)
            for r in 0..<height {
                row.removeAll(keepingCapacity: true)
                row.append(0)
                row.append(contentsOf: UnsafeBufferPointer(
                    start: base + r * rowStride,
                    count: bytesPerRow))
                try row.withUnsafeBufferPointer { buffer in
                    try collect(try compressor.feed(
                        buffer.baseAddress!, count: buffer.count,
                        finalize: false))
                }
            }
            }
            onStitchProgress?(pageIndex + 1, pageURLs.count)
            if shouldCancel?() == true {
                throw CancellationError()
            }
        }
        let tail = try compressor.feedEmpty(finalize: true)
        try collect(tail)
        let adler = compressor.adler32
        idat.append(UInt8((adler >> 24) & 0xFF))
        idat.append(UInt8((adler >> 16) & 0xFF))
        idat.append(UInt8((adler >> 8) & 0xFF))
        idat.append(UInt8(adler & 0xFF))
        if !idat.isEmpty {
            try writer.writeChunk(type: "IDAT", data: idat)
        }
        try writer.writeChunk(type: "IEND", data: [])

        // Prove the file before calling it done: check the
        // stacked height from its header, then re-inflate
        // the whole stream and compare the byte count and
        // the Adler-32 trailer. The first version of this
        // check decoded the picture through ImageIO, which
        // at 1800 dpi over a full deck means a bitmap of
        // many gigabytes, and the check itself failed on
        // files that were perfectly good.
        guard let source = CGImageSourceCreateWithURL(
                outputURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil) as? [CFString: Any],
              let pixelHeight = props[kCGImagePropertyPixelHeight]
                as? Int,
              pixelHeight == totalHeight
        else {
            throw PDFBuilderError.message(
                "[PPG:PNG-HEADER] The stitched PNG did not read back cleanly.")
        }
        try verifyStitchedPNG(width: width,
                              totalHeight: totalHeight)
    }

    /// Walks the finished file chunk by chunk, inflating
    /// the IDAT stream as it goes, and confirms the stream
    /// decodes to exactly the expected bytes with the
    /// Adler-32 trailer matching the bytes that came out.
    /// The picture itself is never materialized, so the
    /// proof costs the same at any scale.
    private func verifyStitchedPNG(width: Int,
                                   totalHeight: Int) throws {
        let expected = totalHeight * (1 + width * 4)
        let handle = try FileHandle(forReadingFrom: outputURL)
        defer { try? handle.close() }
        func readExactly(_ count: Int) throws -> Data {
            guard let data = try handle.read(upToCount: count),
                  data.count == count
            else {
                throw PDFBuilderError.message(
                    "[PPG:PNG-TRUNCATED] The stitched PNG ended early.")
            }
            return data
        }
        _ = try readExactly(8)  // the PNG signature
        let inflater = try PNGInflater()
        var heldBack: [UInt8] = []
        var headerSkipped = false
        var sawEnd = false
        var lastReported = 0
        while !sawEnd {
            if shouldCancel?() == true {
                throw CancellationError()
            }
            let header = try readExactly(8)
            let length = Int(header[0]) << 24
                | Int(header[1]) << 16
                | Int(header[2]) << 8
                | Int(header[3])
            let type = String(bytes: header[4..<8],
                              encoding: .ascii) ?? ""
            if type == "IEND" {
                sawEnd = true
                _ = try readExactly(4)  // the chunk CRC
            } else if type == "IDAT" {
                var remaining = length
                while remaining > 0 {
                    let piece = try readExactly(
                        min(remaining, 1 << 18))
                    remaining -= piece.count
                    // The first two IDAT bytes are the zlib
                    // header and the last four of the whole
                    // stream are the Adler-32 trailer. Hold
                    // bytes back so neither reaches the
                    // inflater, then compare the trailer at
                    // the end.
                    var bytes = heldBack + [UInt8](piece)
                    if !headerSkipped {
                        if bytes.count <= 2 {
                            heldBack = bytes
                            continue
                        }
                        bytes.removeFirst(2)
                        headerSkipped = true
                    }
                    if bytes.count > 4 {
                        let feedCount = bytes.count - 4
                        try bytes.withUnsafeBufferPointer {
                            buffer in
                            try inflater.feed(
                                buffer.baseAddress!,
                                count: feedCount)
                        }
                        heldBack = Array(bytes.suffix(4))
                    } else {
                        heldBack = bytes
                    }
                    if inflater.totalOut - lastReported
                        >= 64_000_000 {
                        lastReported = inflater.totalOut
                        onVerifyProgress?(inflater.totalOut,
                                          expected)
                    }
                }
                _ = try readExactly(4)  // the chunk CRC
            } else {
                try handle.seek(
                    toOffset: handle.offsetInFile
                        + UInt64(length) + 4)
            }
        }
        guard headerSkipped, heldBack.count == 4 else {
            throw PDFBuilderError.message(
                "[PPG:PNG-SHORT] The stitched PNG stream was too short.")
        }
        let trailer = UInt32(heldBack[0]) << 24
            | UInt32(heldBack[1]) << 16
            | UInt32(heldBack[2]) << 8
            | UInt32(heldBack[3])
        let result = try inflater.finish()
        guard result.total == expected,
              result.adler == trailer
        else {
            throw PDFBuilderError.message(
                "[PPG:PNG-VERIFY] The stitched PNG failed verification "
                    + "(decoded \(result.total) of \(expected) "
                    + "bytes).")
        }
    }

    /// Stitches the finished pages into one tall JPEG at
    /// the output URL. The canvas is a bitmap context over
    /// a memory mapped scratch file, so a full deck at
    /// full scale never has to fit in memory: the system
    /// pages the canvas to disk as ImageIO encodes it.
    /// The render DPI is stamped into the JPEG so print
    /// software can place it at true size.
    private func stitchJPEG() throws {
        guard !pageURLs.isEmpty else {
            throw PDFBuilderError.message("[PPG:STITCH-EMPTY] No pages to stitch.")
        }
        // The engine checks this before the build as well;
        // it is repeated here so a direct builder user gets
        // the same plain answer instead of an encoder error.
        if let first = pageURLs.first,
           let source = CGImageSourceCreateWithURL(
            first as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(
            source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int,
           w > 65_535 || h * pageURLs.count > 65_535 {
            throw PDFBuilderError.message(
                "[PPG:JPEG-SIZE] JPEG cannot hold an image this size: the "
                    + "format caps a side at 65,535 pixels. "
                    + "Use PNG or PDF at this scale.")
        }
        guard let firstSource = CGImageSourceCreateWithURL(
                pageURLs[0] as CFURL, nil),
              let firstProps = CGImageSourceCopyPropertiesAtIndex(
                firstSource, 0, nil) as? [CFString: Any],
              let width = firstProps[kCGImagePropertyPixelWidth]
                as? Int,
              let height = firstProps[kCGImagePropertyPixelHeight]
                as? Int
        else {
            throw PDFBuilderError.message(
                "[PPG:PAGE-READBACK] Could not read back a finished page.")
        }
        let totalHeight = height * pageURLs.count
        let bytesPerRow = width * 4
        let totalBytes = bytesPerRow * totalHeight

        let scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProxyPrintStitch-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: scratchURL)
        }
        FileManager.default.createFile(atPath: scratchURL.path,
                                       contents: nil)
        // Updating, not just writing: mapping a write only
        // handle for reading and writing is refused, which
        // is what the first stitch run ran into.
        let fileHandle = try FileHandle(forUpdating: scratchURL)
        try fileHandle.truncate(atOffset: UInt64(totalBytes))
        let mapped = mmap(nil, totalBytes, PROT_READ | PROT_WRITE,
                          MAP_SHARED, fileHandle.fileDescriptor, 0)
        guard let base = mapped,
              base != UnsafeMutableRawPointer(bitPattern: -1)
        else {
            throw PDFBuilderError.message(
                "[PPG:JPEG-CANVAS-MAP] Could not map the stitch canvas: "
                    + String(cString: strerror(errno)))
        }
        defer {
            munmap(base, totalBytes)
            try? fileHandle.close()
        }

        guard let ctx = CGContext(
            data: base, width: width, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast
                .rawValue)
        else {
            throw PDFBuilderError.message(
                "[PPG:JPEG-CANVAS] Could not create the stitch canvas.")
        }
        for (index, url) in pageURLs.enumerated() {
            try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(
                    url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(
                    source, 0, nil)
            else {
                throw PDFBuilderError.message(
                    "[PPG:PAGE-READBACK] Could not read back a finished page.")
            }
            guard image.width == width, image.height == height
            else {
                throw PDFBuilderError.message(
                    "[PPG:PAGE-SIZE] A finished page had the wrong size.")
            }
            // The canvas origin is at the lower left and
            // page one belongs at the top.
            let y = totalHeight - (index + 1) * height
            ctx.draw(image, in: CGRect(x: 0, y: y, width: width,
                                       height: height))
            }
            onStitchProgress?(index + 1, pageURLs.count)
            if shouldCancel?() == true {
                throw CancellationError()
            }
        }
        guard let tall = ctx.makeImage() else {
            throw PDFBuilderError.message(
                "[PPG:JPEG-FINISH] Could not finish the stitched image.")
        }
        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil)
        else {
            throw PDFBuilderError.message(
                "[PPG:JPEG-CREATE] Could not create the JPEG file.")
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality:
                jpegQuality,
            kCGImagePropertyDPIWidth: Double(scale) * 300.0,
            kCGImagePropertyDPIHeight: Double(scale) * 300.0]
        CGImageDestinationAddImage(dest, tall,
                                   options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw PDFBuilderError.message(
                "[PPG:JPEG-WRITE] Could not write the stitched JPEG.")
        }

        // Same proof as the PNG: the file must read back
        // at the full stacked height before the build
        // counts it as done.
        guard let source = CGImageSourceCreateWithURL(
                outputURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(
                source, 0, nil) as? [CFString: Any],
              let pixelHeight = props[kCGImagePropertyPixelHeight]
                as? Int,
              pixelHeight == totalHeight
        else {
            throw PDFBuilderError.message(
                "[PPG:JPEG-HEADER] The stitched JPEG did not read back cleanly.")
        }
    }
}

/// Writes a chunked PNG by hand: signature first (written by
/// the caller), then length + type + data + CRC per chunk.
private nonisolated struct PNGChunkWriter {
    var handle: FileHandle

    static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes {
            crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    mutating func writeChunk(type: String, data: [UInt8]) throws {
        let typeBytes = Array(type.utf8)
        let len = UInt32(data.count)
        var chunk: [UInt8] = [
            UInt8((len >> 24) & 0xFF), UInt8((len >> 16) & 0xFF),
            UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
        chunk.append(contentsOf: typeBytes)
        chunk.append(contentsOf: data)
        let crc = Self.crc32(typeBytes + data)
        chunk.append(UInt8((crc >> 24) & 0xFF))
        chunk.append(UInt8((crc >> 16) & 0xFF))
        chunk.append(UInt8((crc >> 8) & 0xFF))
        chunk.append(UInt8(crc & 0xFF))
        try handle.write(contentsOf: Data(chunk))
    }
}

/// The deflate stream PNG's IDAT chunks carry, fed row by
/// row. What this SDK's stream API emits under the ZLIB
/// name turned out to be raw deflate, with no zlib header
/// and no checksum (proven from a real file's bytes on
/// Nov 3, 2026: the stream began ec da, a raw deflate block
/// header, and libpng rejected it with "incorrect header
/// check"). So the stitcher wraps the envelope itself:
/// a 78 9C header before, and the Adler-32 this class
/// tracks over everything fed, after. Reference type on
/// purpose, so the stitch loop can hand it buffers
/// without closure capture trouble.
private nonisolated final class PNGCompressor {
    // Built inside init: this SDK imports the C stream
    // struct with non optional pointer fields, so it cannot
    // start life as nils. It is pointed at the scratch
    // buffer with zero sizes, which the C initializer
    // overwrites anyway before anything reads them.
    private var stream: compression_stream
    private let scratch: UnsafeMutablePointer<UInt8>
    private let scratchSize = 1 << 20
    private static let emptyByte: UInt8 = 0

    /// The running Adler-32 of everything fed so far, in
    /// its two halves; the stitcher appends the combined
    /// value as the zlib trailer.
    private var adlerA: UInt32 = 1
    private var adlerB: UInt32 = 0
    var adler32: UInt32 { (adlerB << 16) | adlerA }

    private func consumeAdler(_ ptr: UnsafePointer<UInt8>,
                              count: Int) {
        // The classic deferred reduction: the sums stay
        // exact while the modulo runs once per 5552 bytes.
        var a = adlerA
        var b = adlerB
        var i = 0
        while i < count {
            let chunk = min(5552, count - i)
            for j in 0..<chunk {
                a += UInt32(ptr[i + j])
                b += a
            }
            a %= 65521
            b %= 65521
            i += chunk
        }
        adlerA = a
        adlerB = b
    }

    init() throws {
        scratch = UnsafeMutablePointer<UInt8>.allocate(
            capacity: scratchSize)
        stream = compression_stream(
            dst_ptr: scratch, dst_size: 0,
            src_ptr: UnsafePointer(scratch), src_size: 0,
            state: nil)
        guard compression_stream_init(
            &stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else {
            scratch.deallocate()
            throw PDFBuilderError.message(
                "[PPG:PNG-COMPRESSOR] Could not start the PNG compressor.")
        }
    }

    deinit {
        compression_stream_destroy(&stream)
        scratch.deallocate()
    }

    /// Feeds bytes and returns whatever compressed output the
    /// stream produced. With finalize set, drains the tail and
    /// ends the stream.
    func feed(_ ptr: UnsafePointer<UInt8>, count: Int,
              finalize: Bool) throws -> [UInt8] {
        consumeAdler(ptr, count: count)
        var out: [UInt8] = []
        stream.src_ptr = ptr
        stream.src_size = count
        let flags: Int32 = finalize
            ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        var guardCount = 0
        while true {
            guardCount += 1
            if guardCount > 100_000 {
                throw PDFBuilderError.message(
                    "[PPG:PNG-STALL] PNG compression stalled.")
            }
            stream.dst_ptr = scratch
            stream.dst_size = scratchSize
            let status = compression_stream_process(&stream, flags)
            let produced = scratchSize - stream.dst_size
            if produced > 0 {
                out.append(contentsOf: UnsafeBufferPointer(
                    start: scratch, count: produced))
            }
            if status == COMPRESSION_STATUS_END { break }
            guard status == COMPRESSION_STATUS_OK else {
                throw PDFBuilderError.message(
                    "[PPG:PNG-COMPRESS] PNG compression failed.")
            }
            if stream.src_size == 0 && !finalize { break }
        }
        return out
    }

    func feedEmpty(finalize: Bool) throws -> [UInt8] {
        try withUnsafePointer(to: Self.emptyByte) { ptr in
            try feed(ptr, count: 0, finalize: finalize)
        }
    }
}

/// Streaming inflater for the stitch verifier: decodes
/// raw deflate (the same framing the compressor emits),
/// counting the bytes out and running the same Adler-32,
/// so the finished file can be proved against its own
/// trailer without ever holding the picture.
private nonisolated final class PNGInflater {
    private var stream: compression_stream
    private let scratch: UnsafeMutablePointer<UInt8>
    private let scratchSize = 1 << 18
    private var adlerA: UInt32 = 1
    private var adlerB: UInt32 = 0
    private(set) var totalOut = 0
    var adler32: UInt32 { (adlerB << 16) | adlerA }

    init() throws {
        scratch = UnsafeMutablePointer<UInt8>.allocate(
            capacity: scratchSize)
        stream = compression_stream(
            dst_ptr: scratch, dst_size: 0,
            src_ptr: UnsafePointer(scratch), src_size: 0,
            state: nil)
        guard compression_stream_init(
            &stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
        else {
            scratch.deallocate()
            throw PDFBuilderError.message(
                "[PPG:PNG-VERIFIER] Could not start the PNG verifier.")
        }
    }

    deinit {
        compression_stream_destroy(&stream)
        scratch.deallocate()
    }

    private func consumeOutput(_ count: Int) {
        totalOut += count
        var a = adlerA
        var b = adlerB
        var i = 0
        while i < count {
            let chunk = min(5552, count - i)
            for j in 0..<chunk {
                a += UInt32(scratch[i + j])
                b += a
            }
            a %= 65521
            b %= 65521
            i += chunk
        }
        adlerA = a
        adlerB = b
    }

    /// One process call. Returns true when the stream has
    /// reached its end.
    private func pump(flags: Int32) throws -> Bool {
        stream.dst_ptr = scratch
        stream.dst_size = scratchSize
        let status = compression_stream_process(&stream, flags)
        let produced = scratchSize - stream.dst_size
        if produced > 0 { consumeOutput(produced) }
        if status == COMPRESSION_STATUS_END { return true }
        guard status == COMPRESSION_STATUS_OK else {
            throw PDFBuilderError.message(
                "[PPG:PNG-DECODE] The stitched PNG stream did not decode.")
        }
        return false
    }

    func feed(_ ptr: UnsafePointer<UInt8>, count: Int) throws {
        stream.src_ptr = ptr
        stream.src_size = count
        while stream.src_size > 0 {
            if try pump(flags: 0) {
                throw PDFBuilderError.message(
                    "[PPG:PNG-STREAM-END] The stitched PNG stream ended early.")
            }
        }
    }

    /// Drains the stream with no further input and reports
    /// the totals the verifier checks.
    func finish() throws -> (total: Int, adler: UInt32) {
        var guardCount = 0
        let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
        while true {
            guardCount += 1
            if guardCount > 10_000 {
                throw PDFBuilderError.message(
                    "[PPG:PNG-VERIFY-STALL] PNG verification stalled.")
            }
            stream.src_ptr = UnsafePointer(scratch)
            stream.src_size = 0
            if try pump(flags: flags) { break }
        }
        return (totalOut, adler32)
    }
}

/// A minimal streaming zip writer (STORE method, no extra
/// compression: PNG and JPEG pages are already compressed).
/// Files are read from disk in chunks, first for their checksum
/// and then again into the archive, so packing stays flat in
/// memory no matter how large the pages are.
nonisolated struct ZipArchiveWriter {

    private var handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [(name: String, crc: UInt32,
                            size: UInt32, offset: UInt32)] = []

    init(outputURL: URL) throws {
        FileManager.default.createFile(atPath: outputURL.path,
                                       contents: nil)
        handle = try FileHandle(forWritingTo: outputURL)
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    private func crc32(of url: URL) throws -> UInt32 {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var crc: UInt32 = 0xFFFF_FFFF
        while let chunk = try reader.read(upToCount: 1 << 20),
              !chunk.isEmpty {
            for byte in chunk {
                crc = Self.crcTable[Int((crc ^ UInt32(byte)) & 0xFF)]
                    ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private func field<T: FixedWidthInteger>(_ value: T) -> Data {
        var le = value.littleEndian
        return Data(bytes: &le, count: MemoryLayout<T>.size)
    }

    private mutating func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    mutating func addFile(name: String, sourceURL: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(
            atPath: sourceURL.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let crc = try crc32(of: sourceURL)
        let nameData = Data(name.utf8)
        let localOffset = UInt32(offset)

        var header = Data()
        header.append(field(UInt32(0x0403_4b50)))
        header.append(field(UInt16(20)))       // version needed
        header.append(field(UInt16(0)))        // flags
        header.append(field(UInt16(0)))        // method: stored
        header.append(field(UInt16(0)))        // mod time
        header.append(field(UInt16(0x21)))     // mod date 1980-01-01
        header.append(field(crc))
        header.append(field(UInt32(size)))
        header.append(field(UInt32(size)))
        header.append(field(UInt16(nameData.count)))
        header.append(field(UInt16(0)))        // extra length
        header.append(nameData)
        try write(header)

        let reader = try FileHandle(forReadingFrom: sourceURL)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1 << 20),
              !chunk.isEmpty {
            try write(chunk)
        }
        entries.append((name: name, crc: crc, size: UInt32(size),
                        offset: localOffset))
    }

    mutating func finish() throws {
        let cdStart = offset
        for entry in entries {
            let nameData = Data(entry.name.utf8)
            var record = Data()
            record.append(field(UInt32(0x0201_4b50)))
            record.append(field(UInt16(20)))   // version made by
            record.append(field(UInt16(20)))   // version needed
            record.append(field(UInt16(0)))    // flags
            record.append(field(UInt16(0)))    // method: stored
            record.append(field(UInt16(0)))    // mod time
            record.append(field(UInt16(0x21))) // mod date
            record.append(field(entry.crc))
            record.append(field(entry.size))
            record.append(field(entry.size))
            record.append(field(UInt16(nameData.count)))
            record.append(field(UInt16(0)))    // extra
            record.append(field(UInt16(0)))    // comment
            record.append(field(UInt16(0)))    // disk start
            record.append(field(UInt16(0)))    // internal attrs
            record.append(field(UInt32(0)))    // external attrs
            record.append(field(entry.offset))
            record.append(nameData)
            try write(record)
        }
        var end = Data()
        end.append(field(UInt32(0x0605_4b50)))
        end.append(field(UInt16(0)))
        end.append(field(UInt16(0)))
        end.append(field(UInt16(entries.count)))
        end.append(field(UInt16(entries.count)))
        end.append(field(UInt32(offset - cdStart)))
        end.append(field(UInt32(cdStart)))
        end.append(field(UInt16(0)))
        try write(end)
        try handle.close()
    }
}
