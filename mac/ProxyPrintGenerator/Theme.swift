//
//  Theme.swift
//  Version 47
//  Proxy Printer (native port) — the Printing Selector theme
//
//  Ports the web Printing Selector's look to the native app: dark
//  brown leather with soft mottling, pale parchment panels,
//  fantasy type (Cinzel Decorative for the deck name, Cinzel for
//  section plaques, IM Fell English for reading text), and
//  holographic foil in the same spirit as the web app: an animated
//  foil nameplate for the deck name and bright plaques behind the
//  section titles. The fonts are registered at startup in
//  ProxyPrintApp.swift; if a font file is missing, Font.custom
//  quietly falls back to the system font and nothing breaks.
//
//  App target only (SwiftUI).
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Theme {
    // Leather (the dark outside of the card back)
    static let leatherDeep = Color(red: 0.11, green: 0.07, blue: 0.04)
    static let leather = Color(red: 0.20, green: 0.12, blue: 0.07)
    static let leatherLight = Color(red: 0.32, green: 0.20, blue: 0.11)
    // Parchment and suede (the pale inside)
    static let parchment = Color(red: 0.93, green: 0.87, blue: 0.71)
    static let parchmentDeep = Color(red: 0.84, green: 0.75, blue: 0.55)
    /// The warm tan under the suede texture, a lit version of
    /// the photographic nap's own color, for any thin spot.
    static let suedeBase = Color(red: 0.776, green: 0.604, blue: 0.373)
    static let ink = Color(red: 0.15, green: 0.09, blue: 0.05)
    static let gold = Color(red: 0.83, green: 0.62, blue: 0.22)

    static func displayFont(size: CGFloat) -> Font {
        .custom("CinzelDecorative-Bold", size: size)
    }
    static func plaqueFont(size: CGFloat) -> Font {
        .custom("Cinzel-Bold", size: size)
    }
    static func fellFont(size: CGFloat) -> Font {
        // PostScript name verified from the bundled font file
        // itself; IM Fell's regular face calls itself "Roman".
        .custom("IM_FELL_English_Roman", size: size)
    }
    static func fellItalicFont(size: CGFloat) -> Font {
        .custom("IM_FELL_English_Italic", size: size)
    }
    static func kingdomFont(size: CGFloat) -> Font {
        // The small text face: Faerie Moot Ornate, Liam's
        // pick late Nov 2, 2026 (Rise of Kingdom read as all
        // caps at small sizes; he chose the Ornate face of
        // Faerie Moot over the Simple one). PostScript name
        // verified from the font file itself. Note the file
        // in his Xcode project is still named
        // FaerieMootSimple.ttf; registration goes by file
        // name and finds it, and this call asks for the
        // Ornate font living inside it by its real name.
        .custom("FaerieMootOrnate", size: size)
    }

    /// The angel's own gold, bright face to deep carve, as a
    /// top down gradient for letter faces.
    static var angelGoldLinear: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.965, green: 0.878, blue: 0.643),
                     Color(red: 0.847, green: 0.706, blue: 0.424),
                     Color(red: 0.698, green: 0.541, blue: 0.267)],
            startPoint: .top, endPoint: .bottom)
    }
    /// The wallet leather as a top down gradient, light edge
    /// to deep center, for embossed leather letter faces.
    static var leatherLinear: LinearGradient {
        LinearGradient(colors: [leatherLight, leather, leatherDeep],
                       startPoint: .top, endPoint: .bottom)
    }

    /// The holographic foil palette, a full hue ring so it can
    /// cycle smoothly back into itself.
    static let foilColors: [Color] = [
        Color(red: 1.00, green: 0.45, blue: 0.55),
        Color(red: 1.00, green: 0.75, blue: 0.35),
        Color(red: 0.95, green: 0.95, blue: 0.45),
        Color(red: 0.50, green: 0.95, blue: 0.55),
        Color(red: 0.40, green: 0.85, blue: 1.00),
        Color(red: 0.60, green: 0.55, blue: 1.00),
        Color(red: 1.00, green: 0.55, blue: 0.95),
        Color(red: 1.00, green: 0.45, blue: 0.55),
    ]
    static var foilAngular: AngularGradient {
        AngularGradient(gradient: Gradient(colors: foilColors),
                        center: .center)
    }
    static var foilLinear: LinearGradient {
        LinearGradient(colors: foilColors,
                       startPoint: .leading, endPoint: .trailing)
    }

    /// A bundled texture or artwork image (the dragon skin
    /// leather, the suede, the embossed forest), loaded from the
    /// app bundle by file name, PNG or JPEG. Returns nil when the
    /// file did not make it into the target, and the views fall
    /// back to flat color.
    static func textureImage(named name: String) -> Image? {
        guard let url = Bundle.main.url(forResource: name,
                                        withExtension: "png")
            ?? Bundle.main.url(forResource: name,
                               withExtension: "jpg")
        else { return nil }
        #if os(macOS)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(contentsOfFile: url.path)
        else { return nil }
        return Image(uiImage: image)
        #endif
    }
}

/// A tiny deterministic random source, so the leather mottling
/// draws the same pattern on every launch instead of shimmering
/// differently each time the view redraws.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The dark leather backdrop. First choice is the embossed
/// forest artwork (an original scene tooled into oxblood leather
/// in the manner of a hand worked wallet, made for this app),
/// filled to the window. Behind it, the fallback: a tile of
/// dragon skin leather under soft mottled blotches. Either way a
/// glossy diagonal sheen and a vignette finish it. If every image
/// file is missing, the base gradient carries the look alone.
struct LeatherBackground: View {
    var body: some View {
        GeometryReader { geo in
        ZStack {
            LinearGradient(
                colors: [Theme.leatherLight, Theme.leather,
                         Theme.leatherDeep],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            if let forest = Theme.textureImage(named: "leather-forest") {
                // The embossed forest artwork is the background:
                // one full scene, filled to the window, its busy
                // edges framing a calm center. It carries its own
                // texture, so no mottling is laid over it.
                forest
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width,
                           height: geo.size.height)
                    .clipped()
            } else {
                Group {
                    if let scales = Theme.textureImage(
                        named: "leather-dragon") {
                        scales
                            .resizable(resizingMode: .tile)
                            .opacity(0.9)
                    }
                    Canvas { context, size in
                        context.addFilter(.blur(radius: 26))
                        var rng = SplitMix(state: 0xC0FFEE)
                        for _ in 0..<70 {
                            let w = size.width
                                * CGFloat.random(in: 0.08...0.30,
                                                 using: &rng)
                            let h = w * CGFloat.random(in: 0.5...0.9,
                                                       using: &rng)
                            let x = CGFloat.random(in: -40...size.width,
                                                   using: &rng)
                            let y = CGFloat.random(in: -40...size.height,
                                                   using: &rng)
                            let color: Color
                            if Bool.random(using: &rng) {
                                color = Color.black.opacity(
                                    Double.random(in: 0.05...0.13,
                                                  using: &rng))
                            } else {
                                color = Color(red: 0.55, green: 0.38,
                                              blue: 0.20).opacity(
                                    Double.random(in: 0.04...0.10,
                                                  using: &rng))
                            }
                            context.fill(
                                Path(ellipseIn: CGRect(x: x, y: y,
                                                       width: w,
                                                       height: h)),
                                with: .color(color))
                        }
                    }
                }
            }
            // the gloss: a soft sheen raking down from the top,
            // like light on polished hide
            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.clear,
                         Color.black.opacity(0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [Color.clear, Color.black.opacity(0.25)],
                center: .center, startRadius: 220, endRadius: 720)
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .clipped()
        }
        .ignoresSafeArea()
    }
}

/// The fuzzy inside of the leather: a suede surface from a
/// photographic texture Liam picked himself, a fine warm tan
/// nap with a soft sheen where the light rakes across it. The
/// frost is baked into the texture itself (a gentle blur and a
/// lift toward cream) after a live material layer proved to
/// render as an opaque filter over the picture on Liam's
/// build: the nap stays clearly visible through the haze, and
/// dark ink text on it stays easy to read.
struct SuedePanel: View {
    var body: some View {
        ZStack {
            Theme.suedeBase
            if let suede = Theme.textureImage(named: "suede") {
                suede
                    .resizable(resizingMode: .tile)
                    .opacity(0.95)
            }
        }
    }
}

/// A segmented toggle in the app's own hand: Apple's segmented
/// control cannot be given a custom font (Apple draws it), so
/// wherever the app needs one (Faces and List, the Scale
/// pickers), this stands in: a dark translucent track, the
/// chosen side under a gold capsule, labels in Cinzel.
struct FantasySegmentedControl<Value: Hashable>: View {
    let items: [(value: Value, label: String)]
    @Binding var selection: Value
    var fontSize: CGFloat = 15
    var unselectedColor: Color = Theme.ink

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let isSelected = selection == item.value
                Button {
                    selection = item.value
                } label: {
                    Text(item.label)
                        .font(Theme.plaqueFont(size: fontSize))
                        .foregroundStyle(
                            isSelected ? Theme.leatherDeep
                                       : unselectedColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isSelected {
                                Capsule().fill(Theme.gold)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background {
            Capsule().fill(Color.black.opacity(0.18))
        }
    }
}

/// How far the floating content panel sits from the window
/// edges, so the embossed forest artwork stays visible around
/// it: a reminder band at the top and bottom, and on a wide
/// window, open artwork on both sides where the fox and the
/// rabbit live.
enum PanelMetrics {
    static func horizontalInset(for width: CGFloat) -> CGFloat {
        if width >= 1250 { return (width - 920) / 2 }
        if width >= 700 { return 44 }
        return 10
    }

    static func verticalInset(for height: CGFloat) -> CGFloat {
        min(140, max(30, height * 0.10))
    }

    /// The top band runs much thinner than the bottom one, so
    /// content starts sooner and more of it fits on screen. The
    /// bottom keeps its room: the fox and the rabbit live there.
    static func topInset(for height: CGFloat) -> CGFloat {
        guard isMacUI else {
            // On the phone the panel starts right under the
            // navigation bar, with barely a seam of background.
            return 6
        }
        return min(38, max(10, height * 0.03))
    }
}

/// The app's main layout: the embossed forest leather fills
/// the window, and the screen's content rides on one floating
/// panel of fuzzy suede with rounded corners and a soft
/// shadow. Screens with a bottom bar pass it as a second
/// block: it sits in the layout flow under the panel as its
/// own rounded leather strip. (It used to ride in the list's
/// safe area inset; inside the floating panel that math put
/// the bar off the bottom of the window on Liam's Mac, so the
/// bar is plain layout now, with no safe areas involved.)
struct PanelScaffold<Content: View, Bar: View>: View {
    var hasBar: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var bar: () -> Bar

    init(@ViewBuilder bar: @escaping () -> Bar,
         @ViewBuilder content: @escaping () -> Content) {
        self.hasBar = true
        self.bar = bar
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            let h = PanelMetrics.horizontalInset(for: geo.size.width)
            let topV = PanelMetrics.topInset(for: geo.size.height)
            // On the desktop the stack runs nearly to the bottom
            // edge, just clearing the stitched frame, and the bar
            // sits flush against the panel above it. On the phone
            // the bar runs right down to the bottom edge too,
            // with no band of background under it.
            let bottomV: CGFloat = isMacUI ? 20 : 4
            ZStack {
                LeatherBackground()
                VStack(spacing: isMacUI ? 0 : 10) {
                    ZStack {
                        SuedePanel()
                        content()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .shadow(color: Color.black.opacity(0.5),
                            radius: 16, x: 0, y: 5)
                    if hasBar {
                        bar()
                            .clipShape(
                                RoundedRectangle(cornerRadius: 22))
                            .shadow(color: Color.black.opacity(0.5),
                                    radius: 16, x: 0, y: 5)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, h)
                .padding(.top, topV)
                .padding(.bottom, bottomV)
            }
        }
    }
}

extension PanelScaffold where Bar == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        self.hasBar = false
        self.content = content
        self.bar = { EmptyView() }
    }
}

/// The wallet's stitched edge as the Mac window's border: a
/// dark leather band just inside the edge with a dashed line
/// of tan thread running through it. Decoration only; it
/// never takes a click.
struct StitchedEdgeOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.leatherDeep, lineWidth: 18)
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 0.78, green: 0.63, blue: 0.42),
                        style: StrokeStyle(lineWidth: 2.5,
                                           dash: [7, 5]))
                .padding(9)
        }
        .allowsHitTesting(false)
    }
}

/// The bright iridescent plaque that section titles sit on, like
/// the web app's title plaques: a foil wash with a sheen and a
/// thin gold rim. Calm and still; the nameplate owns the motion.
struct FoilPlaque: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Theme.foilLinear)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.clear,
                                 Color.black.opacity(0.12)],
                        startPoint: .top, endPoint: .bottom)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.gold.opacity(0.8),
                                  lineWidth: 1))
    }
}

extension Theme {
    /// The one length for every wash plaque in the app:
    /// section headers and the Add a deck button all ride
    /// on the same coin, much shorter than the panel.
    static var plaqueWidth: CGFloat { isMacUI ? 500 : 320 }
}

/// The section plaque as a picture: the holographic wash
/// Liam picked from four painted options on Nov 2, 2026,
/// carved gold under a full oil slick rainbow. Used behind
/// the section headers and the Add a deck button. Falls
/// back to the plain foil gradient if the picture is not
/// in the bundle. Shaped like a shiny coin, per Liam later
/// that day: capsule ends, a thick raised metallic rim, an
/// inner bevel line, and gloss pooled across the top. Every
/// plaque in the app is one length, Theme.plaqueWidth.
struct WashPlaque: View {
    var body: some View {
        ZStack {
            Theme.foilLinear
            if let wash = Theme.textureImage(named: "plaque-wash") {
                wash
                    .resizable()
                    .scaledToFill()
            }
            LinearGradient(
                colors: [Color.white.opacity(0.30),
                         Color.white.opacity(0.05),
                         Color.clear],
                startPoint: .top, endPoint: .center)
        }
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color(red: 0.98, green: 0.87,
                                       blue: 0.50),
                                 Theme.gold,
                                 Color(red: 0.55, green: 0.38,
                                       blue: 0.12)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 5))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.35),
                              lineWidth: 1)
                .padding(5))
    }
}

/// The wash plaque stretched wide: the same carved gold
/// and gloss as WashPlaque, but in a rounded rectangle
/// that spans a page instead of riding at one coin length.
/// The deck page banner wears it.
struct WidePlaque: View {
    var body: some View {
        ZStack {
            Theme.foilLinear
            if let wash = Theme.textureImage(named: "plaque-wash") {
                wash
                    .resizable()
                    .scaledToFill()
            }
            LinearGradient(
                colors: [Color.white.opacity(0.30),
                         Color.white.opacity(0.05),
                         Color.clear],
                startPoint: .top, endPoint: .center)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20,
                                    style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20,
                             style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color(red: 0.98, green: 0.87,
                                       blue: 0.50),
                                 Theme.gold,
                                 Color(red: 0.55, green: 0.38,
                                       blue: 0.12)],
                        startPoint: .top, endPoint: .bottom),
                    lineWidth: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 20,
                             style: .continuous)
                .strokeBorder(Color.white.opacity(0.35),
                              lineWidth: 1)
                .padding(5))
    }
}

/// A settings group that hides away until its title is
/// tapped: a title row with a chevron, and the rows it
/// covers stacked under it while it is open. Starts closed,
/// so a settings list stays short.
struct HideawayGroup<Content: View>: View {
    let title: String
    @State private var open = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    open.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    KingdomText(text: title,
                                size: isMacUI ? 20 : 19)
                    Image(systemName: open
                            ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.gold)
                        .arrowChip()
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                content()
            }
        }
    }
}

/// Menu pickers on the suede render as bare gold letters
/// with a chevron, which vanishes against the tan. This
/// seats a picker on a dark leather chip with a fine gold
/// rim, so its value stays readable.
extension View {
    func pickerChip() -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8,
                                 style: .continuous)
                    .fill(Theme.leatherDeep))
            .overlay(
                RoundedRectangle(cornerRadius: 8,
                                 style: .continuous)
                    .strokeBorder(Theme.gold.opacity(0.45),
                                  lineWidth: 1))
    }
}


/// The little brother of the picker chip, for a lone gold
/// arrow or glyph on the suede: the print margin hideaway's
/// chevron wears it, so the arrow stays visible.
extension View {
    func arrowChip() -> some View {
        self
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6,
                                 style: .continuous)
                    .fill(Theme.leatherDeep))
            .overlay(
                RoundedRectangle(cornerRadius: 6,
                                 style: .continuous)
                    .strokeBorder(Theme.gold.opacity(0.45),
                                  lineWidth: 1))
    }
}

/// A starburst with soft spikes, the shape a WOW sticker
/// is cut in.
struct BurstShape: Shape {
    var points: Int = 16
    var innerRatio: CGFloat = 0.84

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let total = points * 2
        for i in 0..<total {
            let angle = Double(i) * Double.pi / Double(points)
                - Double.pi / 2
            let r = i % 2 == 0 ? outer : inner
            let p = CGPoint(x: cx + CGFloat(cos(angle)) * r,
                            y: cy + CGFloat(sin(angle)) * r)
            if i == 0 {
                path.move(to: p)
            } else {
                path.addLine(to: p)
            }
        }
        path.closeSubpath()
        return path
    }
}

/// The realism sticker, mirrored from the Windows build's
/// Auto switch and dressed as a flashy WOW sticker: tap it
/// and Auto vibrance is on, 40% vibrance and 12% midtone
/// lift, with the two sliders sitting the build out. Off,
/// the sticker sleeps in grey.
struct RealismSticker: View {
    let isOn: Bool
    let onTap: () -> Void

    var body: some View {
        Button {
            onTap()
        } label: {
            ZStack {
                BurstShape()
                    .fill(LinearGradient(
                        colors: [Color(red: 1.00, green: 0.25,
                                       blue: 0.55),
                                 Color(red: 1.00, green: 0.55,
                                       blue: 0.20),
                                 Color(red: 1.00, green: 0.80,
                                       blue: 0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                BurstShape()
                    .stroke(Color.white, lineWidth: 3.5)
                VStack(spacing: 1) {
                    Text("Use auto vibrance")
                        .font(.system(size: 13.5,
                                      weight: .black,
                                      design: .rounded))
                    Text("to make your prints")
                        .font(.system(size: 13.5,
                                      weight: .black,
                                      design: .rounded))
                    Text("POP!")
                        .font(.system(size: 36,
                                      weight: .black,
                                      design: .rounded))
                }
                .foregroundStyle(Color.white)
                .shadow(color: Color.black.opacity(0.45),
                        radius: 1.5, x: 0, y: 1.5)
            }
            .frame(width: 216, height: 136)
            .rotationEffect(.degrees(-7))
            .shadow(color: Color.black.opacity(0.35),
                    radius: 3, x: 0, y: 2)
            .saturation(isOn ? 1 : 0.12)
            .opacity(isOn ? 1 : 0.8)
        }
        .buttonStyle(.plain)
    }
}

/// The fox outline from the Windows logo, as a SwiftUI
/// shape: the same path data the PDF builder stamps with,
/// parsed the same way (M, L, C, A, Z commands in a 240
/// square, y down, which is also SwiftUI's way).
struct FoxOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 240
        let ox = rect.minX + (rect.width - 240 * scale) / 2
        let oy = rect.minY + (rect.height - 240 * scale) / 2
        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: ox + CGFloat(x) * scale,
                    y: oy + CGFloat(y) * scale)
        }
        var path = Path()
        var tokens: [String] = []
        var current = ""
        for ch in Self.pathData {
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
        var cur = CGPoint(x: 0, y: 0)
        var subStart = CGPoint(x: 0, y: 0)
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
                cur = CGPoint(x: x, y: y)
                subStart = cur
                path.move(to: pt(x, y))
                command = "L"
            case "L":
                let x = number()
                let y = number()
                cur = CGPoint(x: x, y: y)
                path.addLine(to: pt(x, y))
            case "C":
                let x1 = number()
                let y1 = number()
                let x2 = number()
                let y2 = number()
                let x = number()
                let y = number()
                path.addCurve(to: pt(x, y),
                              control1: pt(x1, y1),
                              control2: pt(x2, y2))
                cur = CGPoint(x: x, y: y)
            case "A":
                let rx = number()
                let ry = number()
                _ = number()
                let largeArc = number() > 0.5
                let sweep = number() > 0.5
                let x = number()
                let y = number()
                let end = CGPoint(x: x, y: y)
                Self.addArc(to: &path, start: cur,
                            rx: rx, ry: ry,
                            largeArc: largeArc, sweep: sweep,
                            end: end, scale: scale, pt: pt)
                cur = end
            case "Z":
                path.closeSubpath()
                cur = subStart
                command = ""
            default:
                i += 1
            }
        }
        return path
    }

    /// An SVG elliptical arc converted from end point form
    /// to a center arc: the same math the PDF builder runs.
    private static func addArc(
        to path: inout Path, start: CGPoint,
        rx: Double, ry: Double,
        largeArc: Bool, sweep: Bool,
        end: CGPoint, scale: CGFloat,
        pt: (Double, Double) -> CGPoint) {
        var rx = abs(rx)
        var ry = abs(ry)
        if rx == 0 || ry == 0 {
            path.addLine(to: pt(Double(end.x), Double(end.y)))
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
            let factor = sqrt(lambda)
            rx *= factor
            ry *= factor
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
        let center = pt(cx, cy)
        let radius = CGFloat(rx) * scale
        if abs(delta) > 1.5 * Double.pi {
            path.addArc(center: center, radius: radius,
                        startAngle: Angle(radians: startAngle),
                        endAngle: Angle(radians: startAngle
                                                   + delta / 2),
                        clockwise: delta < 0)
            path.addArc(center: center, radius: radius,
                        startAngle: Angle(radians: startAngle
                                                   + delta / 2),
                        endAngle: Angle(radians: startAngle
                                                   + delta),
                        clockwise: delta < 0)
        } else {
            path.addArc(center: center, radius: radius,
                        startAngle: Angle(radians: startAngle),
                        endAngle: Angle(radians: startAngle
                                                   + delta),
                        clockwise: delta < 0)
        }
    }

    static let pathData = "M 44.8,208.8 C 45.6,184.8 47.2,159.2 51.2,127.2 M 50.4,133.6 C 57.6,117.6 67.2,104.8 80,95.2 M 51.2,127.2 C 51.2,114.4 52.8,101.6 56,92 M 45.6,194.4 C 37.6,191.2 31.2,197.6 35.2,203.2 C 38.4,208 45.6,204.8 43.2,199.2 M 45.6,186.4 C 54.4,184 60,190.4 56,195.2 C 52.8,198.4 48,195.2 50.4,191.2 M 56.6,120 C 48,125.5 25.6,124.7 20.4,113.6 C 4.9,109.2 9.8,92.5 25.2,97.1 C 11.1,89.4 19.5,74.2 33.5,82.1 C 21.4,71.5 32.9,58.5 44.9,69.2 C 35.3,56.3 49.4,46 58.7,59.1 C 52.3,44.4 68.2,37.5 74.5,52.3 C 71.4,36.5 88.4,33.2 91.4,49 C 91.7,33 109.1,33.5 108.5,49.6 C 115,57.3 109.6,79.1 103.4,86 C 100.8,93 90.8,93.5 87.5,86.8 C 87.7,94.2 78.7,98.5 73.1,93.5 C 76.1,100.3 69.3,107.6 62.3,105.2 C 67.6,110.3 64,119.7 56.6,120 Z M 195.2,208.8 C 194.4,184.8 192.8,159.2 188.8,127.2 M 189.6,133.6 C 182.4,117.6 172.8,104.8 160,95.2 M 188.8,127.2 C 188.8,114.4 187.2,101.6 184,92 M 194.4,194.4 C 202.4,191.2 208.8,197.6 204.8,203.2 C 201.6,208 194.4,204.8 196.8,199.2 M 194.4,186.4 C 185.6,184 180,190.4 184,195.2 C 187.2,198.4 192,195.2 189.6,191.2 M 183.4,120 C 192,125.5 214.4,124.7 219.6,113.6 C 235.1,109.2 230.2,92.5 214.8,97.1 C 228.9,89.4 220.5,74.2 206.5,82.1 C 218.6,71.5 207.1,58.5 195.1,69.2 C 204.7,56.3 190.6,46 181.3,59.1 C 187.7,44.4 171.8,37.5 165.5,52.3 C 168.6,36.5 151.6,33.2 148.6,49 C 148.3,33 130.9,33.5 131.5,49.6 C 125,57.3 130.4,79.1 136.6,86 C 139.2,93 149.2,93.5 152.5,86.8 C 152.3,94.2 161.3,98.5 166.9,93.5 C 163.9,100.3 170.7,107.6 177.7,105.2 C 172.4,110.3 176,119.7 183.4,120 Z M 118.1,143 C 142.3,127.5 180.4,137.8 182.1,172.4 C 183.8,196.6 164.8,210.4 137.2,210.4 C 109.5,210.4 80.1,208.7 66.3,196.6 C 60.3,190.5 62.8,183.6 70.6,183.6 C 92.2,187.1 119.9,189.7 140.6,185.3 C 156.2,181.9 164.8,173.2 164.8,162 M 81.9,186.2 C 76.7,192.3 76.7,199.2 82.7,205.2 M 100.9,148.2 L 107.8,122.3 L 119.9,143.9 M 82.7,156.8 L 73.2,132.6 L 93.1,149.1 M 106,134.4 L 110.4,143.9 M 77.5,143 L 85.3,150.8 M 93.1,149.1 C 95.7,147.3 98.3,147.3 100.9,148.2 M 82.7,156.8 C 76.7,164.6 68,170.7 59.4,175.8 C 64.6,181 80.1,182.8 95.7,180.2 M 119.9,143.9 C 125.1,156 121.6,170.7 107.8,178.4 C 103.5,180.2 99.1,181 95.7,180.2 M 85.3,164.6 C 88.8,168.1 94,168.1 97.4,164.6 M 120,6 A 114,114 0 1 1 119.9,6 Z"
}

/// A small card wearing the chosen proxy mark, drawn the
/// way the PDF builder draws it: a black card, its art
/// window, and the mark in its spot, so a mark can be
/// judged and placed before a build runs. The art window
/// wears a plain wash; the mark is the point.
struct ProxyMarkPreview: View {
    let mark: ProxyMark

    var body: some View {
        let cardW: CGFloat = 148
        let cardH = cardW * 88 / 63
        let artW = cardW * 53 / 63
        let artH = cardH * 38 / 88
        let ink = Color(red: Double(mark.color.r) / 255,
                        green: Double(mark.color.g) / 255,
                        blue: Double(mark.color.b) / 255)
        let luminance = 0.299 * Double(mark.color.r)
            + 0.587 * Double(mark.color.g)
            + 0.114 * Double(mark.color.b)
        let halo = luminance > 170
            ? Color(red: 20 / 255, green: 20 / 255,
                    blue: 20 / 255).opacity(150 / 255)
            : Color.white.opacity(215 / 255)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cardW * 3 / 63,
                             style: .continuous)
                .fill(Color(white: 0.07))
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.45, green: 0.52,
                                   blue: 0.38),
                             Color(red: 0.72, green: 0.64,
                                   blue: 0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing)
                markLayer(ink: ink, halo: halo,
                          artW: artW, artH: artH)
            }
            .frame(width: artW, height: artH)
            .offset(x: cardW * 5 / 63, y: cardH * 10.5 / 88)
            if mark.kind == .border {
                RoundedRectangle(cornerRadius: cardW * 3 / 63,
                                 style: .continuous)
                    .strokeBorder(
                        ink,
                        lineWidth: CGFloat(mark.borderMM)
                            / 63 * cardW)
            }
        }
        .frame(width: cardW, height: cardH)
    }

    /// The label or the fox, centered on its spot inside
    /// the art window: the nine spots are a three by three
    /// grid, and the mark slides between the same 2.5 mm
    /// insets the builder keeps.
    @ViewBuilder
    private func markLayer(ink: Color, halo: Color,
                           artW: CGFloat,
                           artH: CGFloat) -> some View {
        let row = mark.position.rawValue / 3
        let col = mark.position.rawValue % 3
        let fx = [CGFloat(0), 0.5, 1][col]
        let fy = [CGFloat(0), 0.5, 1][row]
        if mark.kind == .label {
            let fontSize = artW * (5.0 / 0.7) / 53
            let markW = fontSize * 3.2
            let markH = fontSize * 1.15
            let cx = markW / 2 + fx * (artW - markW)
            let cy = markH / 2 + fy * (artH - markH)
            Text("PROXY")
                .font(.custom(mark.font.fontName,
                              size: fontSize))
                .foregroundStyle(ink)
                .shadow(color: halo, radius: 0, x: 1.2, y: 0)
                .shadow(color: halo, radius: 0, x: -1.2, y: 0)
                .shadow(color: halo, radius: 0, x: 0, y: 1.2)
                .shadow(color: halo, radius: 0, x: 0, y: -1.2)
                .position(x: cx, y: cy)
        } else if mark.kind == .logo {
            let size = artW * 15 / 53
            let cx = size / 2 + fx * (artW - size)
            let cy = size / 2 + fy * (artH - size)
            ZStack {
                FoxOutlineShape()
                    .stroke(halo, style: StrokeStyle(
                        lineWidth: size * 13 / 240,
                        lineCap: .round, lineJoin: .round))
                FoxOutlineShape()
                    .stroke(ink, style: StrokeStyle(
                        lineWidth: size * 6 / 240,
                        lineCap: .round, lineJoin: .round))
            }
            .frame(width: size, height: size)
            .position(x: cx, y: cy)
        }
    }
}

/// The five land symbols as a decorative row: sun, water,
/// moon, fire, and tree in tinted circles with gold rims, for
/// under the big headings.
struct ManaPipRow: View {
    var pipSize: CGFloat = 17
    /// When set, only these pips show (by index into the five),
    /// so a heading can split the row across its two sides.
    var subset: [Int]? = nil

    private var shownIndices: [Int] {
        subset ?? Array(pips.indices)
    }

    private var pips: [(symbol: String, fill: Color, glyph: Color)] {
        [("sun.max.fill",
          Color(red: 0.96, green: 0.90, blue: 0.72),
          Color(red: 0.55, green: 0.42, blue: 0.10)),
         ("drop.fill",
          Color(red: 0.25, green: 0.45, blue: 0.85),
          Color.white),
         ("moon.fill",
          Color(red: 0.16, green: 0.14, blue: 0.20),
          Color(red: 0.85, green: 0.82, blue: 0.75)),
         ("flame.fill",
          Color(red: 0.85, green: 0.30, blue: 0.18),
          Color(red: 1.0, green: 0.85, blue: 0.55)),
         ("tree.fill",
          Color(red: 0.25, green: 0.55, blue: 0.30),
          Color.white)]
    }

    var body: some View {
        HStack(spacing: 7) {
            ForEach(shownIndices, id: \.self) { index in
                let pip = pips[index]
                Image(systemName: pip.symbol)
                    .font(.system(size: pipSize * 0.58, weight: .bold))
                    .foregroundStyle(pip.glyph)
                    .frame(width: pipSize, height: pipSize)
                    .background(Circle().fill(pip.fill))
                    .overlay(
                        Circle().strokeBorder(
                            Theme.gold.opacity(0.7), lineWidth: 1))
            }
        }
    }
}

/// A plaque title: Faerie Moot Ornate in dark ink with an
/// ivory outline, the letter style Quality and Low Ink
/// Calibration set and Liam asked to make standard on
/// Nov 2, 2026. Shared by the section headers and the Add
/// a deck button so every wash plaque reads the same way.
struct PlaqueTitleText: View {
    let text: String
    let size: CGFloat

    private var outlineRadius: CGFloat {
        max(0.9, size * 0.04)
    }

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) / 8.0 * 2.0 * Double.pi
                Text(text)
                    .font(Theme.kingdomFont(size: size))
                    .foregroundStyle(Color(red: 0.97,
                                           green: 0.94,
                                           blue: 0.85))
                    .offset(x: cos(angle) * outlineRadius,
                            y: sin(angle) * outlineRadius)
            }
            Text(text)
                .font(Theme.kingdomFont(size: size))
                .foregroundStyle(Theme.ink)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}

/// A section heading gone spectacular: big Faerie Moot
/// Ornate on the holographic foil plaque, living glitter all over it,
/// and the five land symbols in a row beneath the words.
struct SpectacularHeader: View {
    let title: String
    /// With the pips split across the two sides of the words
    /// instead of in a row beneath them, the heading keeps its
    /// big font but stands about half as tall.
    var pipsOnSides: Bool = false

    private var titleSeed: Int {
        title.unicodeScalars.reduce(7) { ($0 &* 31) &+ Int($1.value) }
    }

    var body: some View {
        Group {
            if pipsOnSides {
                HStack(spacing: 14) {
                    ManaPipRow(pipSize: isMacUI ? 19 : 17,
                               subset: [0, 1, 2])
                    PlaqueTitleText(
                        text: title.uppercased(),
                        size: isMacUI ? 34 : 31)
                    ManaPipRow(pipSize: isMacUI ? 19 : 17,
                               subset: [3, 4])
                }
            } else {
                VStack(spacing: 5) {
                    PlaqueTitleText(
                        text: title.uppercased(),
                        size: isMacUI ? 38 : 31)
                    ManaPipRow(pipSize: isMacUI ? 19 : 17)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, pipsOnSides ? 8 : 10)
        .frame(width: Theme.plaqueWidth)
        .background { WashPlaque() }
        .overlay { GlitterOverlay(seed: titleSeed) }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// The app masthead for the two main screens. The title is
/// a painted picture in the app icon's artwork: an embossed
/// tooled leather frame around a holographic rimmed plaque
/// whose field is holographic gold, carrying a gold landscape
/// (swamp, angel, campfire, lake, and a drinking dinosaur),
/// ProxyPrintGenerator in embossed gold letters, and the
/// five theme gems in a row beneath. The living glitter
/// plays over the picture, and
/// the section name rides under it on a small dark chip, so
/// the header still says the app's name and where you are at
/// the same time. If the picture is missing from the bundle,
/// a drawn stand in (foil rim, gold trees and star, foil
/// letters) takes its place.
struct AppMasthead: View {
    var section: String
    @State private var sheen: Double = 0

    var body: some View {
        VStack(spacing: 7) {
            if let art = Theme.textureImage(named: "masthead") {
                art
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(
                        cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16,
                                         style: .continuous)
                            .strokeBorder(Color.black.opacity(0.3),
                                          lineWidth: 1))
                    .overlay { GlitterOverlay(seed: 4242) }
                    .shadow(color: Color.black.opacity(0.4),
                            radius: 8, x: 0, y: 3)
            } else {
                drawnMasthead
            }
            KingdomText(text: section, size: 17.5)
                .padding(.horizontal, 15)
                .padding(.vertical, 5)
                .background {
                    Capsule().fill(Theme.leatherDeep)
                        .overlay(
                            Capsule().strokeBorder(
                                Theme.gold.opacity(0.55),
                                lineWidth: 1))
                }
        }
    }

    /// The drawn stand in, used only when the painted picture
    /// is not in the bundle.
    private var drawnMasthead: some View {
        VStack(spacing: 4) {
            HStack(spacing: 14) {
                Image(systemName: "tree.fill")
                    .font(.system(size: 20, weight: .bold))
                Image(systemName: "sparkle")
                    .font(.system(size: 24, weight: .bold))
                    .offset(y: -5)
                Image(systemName: "tree.fill")
                    .font(.system(size: 20, weight: .bold))
            }
            .foregroundStyle(Theme.foilLinear)
            .hueRotation(.degrees(sheen))
            .shadow(color: Color.black.opacity(0.45),
                    radius: 1, x: 0, y: 1.5)
            Text("ProxyPrintGen")
                .font(Theme.kingdomFont(size: 30))
                .foregroundStyle(Theme.foilLinear)
                .hueRotation(.degrees(sheen))
                .shadow(color: Color.black.opacity(0.45),
                        radius: 1, x: 0, y: 1.5)
            ManaPipRow(pipSize: 16)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.leatherDeep)
                .overlay(
                    RoundedRectangle(cornerRadius: 14,
                                     style: .continuous)
                        .strokeBorder(Theme.foilLinear,
                                      lineWidth: 3)
                        .hueRotation(.degrees(sheen)))
        }
        .overlay { GlitterOverlay(seed: 4242) }
        .padding(9)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Theme.leatherLight, Theme.leather,
                                 Theme.leatherDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.35),
                                  lineWidth: 1)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(red: 0.78, green: 0.63,
                                  blue: 0.42).opacity(0.8),
                            style: StrokeStyle(lineWidth: 1.5,
                                               dash: [6, 4]))
                    .padding(4.5)
            }
        }
        .shadow(color: Color.black.opacity(0.4),
                radius: 8, x: 0, y: 3)
        .onAppear {
            withAnimation(.linear(duration: 24)
                .repeatForever(autoreverses: false)) {
                sheen = 360
            }
        }
    }
}

extension View {
    /// Pins the app masthead at the top of a scrolling screen,
    /// in the spot the system title used to take, on the phone
    /// and the desktop alike.
    @ViewBuilder
    func appMasthead(section: String) -> some View {
        self.safeAreaInset(edge: .top, spacing: 0) {
            AppMasthead(section: section)
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 10)
        }
    }
}

/// One speck of glitter: where it sits on the plaque, how
/// big, which neon color, and the rhythm it blinks on.
struct GlitterSpeck {
    var x: Double
    var y: Double
    var size: CGFloat
    var color: Color
    var period: Double
    var phase: Double

    /// The fixed scatter for one heading, rolled from its seed
    /// so every heading glitters differently but always in the
    /// same places.
    static func scatter(seed: Int) -> [GlitterSpeck] {
        var rng = SplitMix(state: UInt64(bitPattern: Int64(seed)))
        let neon: [Color] = [
            Color(red: 0.30, green: 0.95, blue: 1.00),
            Color(red: 1.00, green: 0.35, blue: 0.85),
            Color(red: 0.55, green: 1.00, blue: 0.35),
            Color(red: 1.00, green: 0.90, blue: 0.25),
            Color(red: 0.70, green: 0.55, blue: 1.00),
            Color(red: 1.00, green: 0.55, blue: 0.30),
        ]
        return (0..<14).map { _ in
            GlitterSpeck(
                x: Double.random(in: 0.05...0.95, using: &rng),
                y: Double.random(in: 0.12...0.88, using: &rng),
                size: CGFloat.random(in: 4...8, using: &rng),
                color: neon[Int.random(in: 0..<neon.count,
                                       using: &rng)],
                period: Double.random(in: 0.8...2.1, using: &rng),
                phase: Double.random(in: 0...1, using: &rng))
        }
    }
}

/// The glitter itself, drawn for one moment in time: the
/// neon specks at their blink brightness for that instant.
struct GlitterCanvas: View {
    let specks: [GlitterSpeck]
    let t: Double

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(specks.indices, id: \.self) { index in
                    let speck = specks[index]
                    let cycle = (t / speck.period + speck.phase)
                        .truncatingRemainder(dividingBy: 1)
                    let glow = max(0, 1 - abs(cycle - 0.5) * 5)
                    Image(systemName: "sparkle")
                        .font(.system(size: speck.size,
                                      weight: .bold))
                        .foregroundStyle(speck.color)
                        .opacity(glow * 0.95)
                        .position(
                            x: speck.x * geo.size.width,
                            y: speck.y * geo.size.height)
                }
            }
        }
    }
}

/// Living glitter for the spectacular headings: small neon
/// sparkles strewn about at random, each blinking in and out
/// on its own rhythm like real glitter catching the light.
struct GlitterOverlay: View {
    let specks: [GlitterSpeck]

    init(seed: Int) {
        specks = GlitterSpeck.scatter(seed: seed)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GlitterCanvas(
                specks: specks,
                t: timeline.date.timeIntervalSinceReferenceDate)
        }
        .allowsHitTesting(false)
    }
}

struct FantasyButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 20
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.plaqueFont(size: fontSize))
            .foregroundStyle(Theme.leatherDeep)
            .padding(.vertical, 11)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 13,
                                     style: .continuous)
                        .fill(LinearGradient(
                            colors: [
                                Color(red: 0.98, green: 0.87,
                                      blue: 0.50),
                                Theme.gold,
                                Color(red: 0.78, green: 0.60,
                                      blue: 0.22)],
                            startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 13,
                                     style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0.38),
                                     Color.clear,
                                     Color.black.opacity(0.10)],
                            startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 13,
                                     style: .continuous)
                        .strokeBorder(
                            Color(red: 0.55, green: 0.42, blue: 0.10)
                                .opacity(0.65),
                            lineWidth: 1)
                }
            }
            .opacity(isEnabled
                     ? (configuration.isPressed ? 0.72 : 1)
                     : 0.45)
    }
}

/// A small caption dressed up: Fell italic in warm bronze
/// between two sparkles, for the quiet helper lines (Dots per
/// inch, the card faces footer hints).
struct OrnamentCaption: View {
    let text: String
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.72, weight: .bold))
            KingdomText(text: text, size: size)
                .multilineTextAlignment(.center)
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.72, weight: .bold))
        }
        .foregroundStyle(Color(red: 0.42, green: 0.30, blue: 0.05))
    }
}

/// A success line: Fell italic in a deep green with a
/// check mark, so good news never reads like the bronze
/// warnings beside it. (Liam, Nov 13, 2026: the fit
/// success text wore the same font, color and size as
/// the error text, and said "can't" besides.)
struct SuccessCaption: View {
    let text: String
    var size: CGFloat = 17

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size * 0.85,
                              weight: .bold))
            Text(text)
                .font(Theme.fellItalicFont(size: size))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(Color(red: 0.11, green: 0.33,
                               blue: 0.14))
    }
}

/// The smaller text treatment, settled Nov 2, 2026: Faerie
/// Moot Simple letters with the angel's gold on the face
/// and an embossed leather outline. (The holographic
/// outline read as rainbow, and the leather faced version
/// never pleased, so the gold face keeps the leather as
/// its outline.) Faerie Moot ships Regular only, so the
/// face is struck five times over for a bold weight.
struct KingdomText: View {
    let text: String
    let size: CGFloat

    private var outlineRadius: CGFloat { size * 0.06 + 0.8 }
    private var boldRadius: CGFloat { size * 0.016 + 0.22 }

    var body: some View {
        ZStack {
            ForEach(0..<10, id: \.self) { i in
                let angle = Double(i) / 10.0 * 2.0 * Double.pi
                Text(text)
                    .font(Theme.kingdomFont(size: size))
                    .foregroundStyle(AnyShapeStyle(
                        Theme.leatherLinear))
                    .offset(x: cos(angle) * outlineRadius,
                            y: sin(angle) * outlineRadius)
            }
            ForEach(0..<5, id: \.self) { i in
                let dx: CGFloat = [0, boldRadius, -boldRadius,
                                   0, 0][i]
                let dy: CGFloat = [0, 0, 0,
                                   boldRadius, -boldRadius][i]
                Text(text)
                    .font(Theme.kingdomFont(size: size))
                    .foregroundStyle(AnyShapeStyle(
                        Theme.angelGoldLinear))
                    .offset(x: dx, y: dy)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: 1)
    }
}

/// The deck name as a centerpiece, the way the Printing Selector
/// presents it: a card shaped plate with a holographic foil rim,
/// an oil slick wash behind the letters, twinkling sparkles, and
/// the name itself big, centered, and in Cinzel Decorative. The
/// foil colors cycle slowly by hue rotation. The name is a text
/// field, so tapping it renames the deck, as before.
struct FoilNameplate: View {
    @Binding var name: String
    var subtitle: String
    var onCommit: () -> Void

    @State private var hueSpin: Double = 0
    @State private var twinkle = false
    @State private var plateWidth: CGFloat = 0

    /// The name's size, fitted to the nameplate itself: short
    /// names ride at full size, long names step down until the
    /// whole name fits instead of trailing off into an ellipsis,
    /// and on the Mac the ceiling itself breathes with the plate
    /// width, so a half screen window gets a smaller header and
    /// a wide window a bigger one.
    private var nameFontSize: CGFloat {
        let chars = max(name.count, 1)
        let width = plateWidth > 0 ? plateWidth
            : (isMacUI ? 700 : 340)
        // The fit math was tuned when the name rode in Cinzel
        // Decorative, which runs very wide, roughly a full point
        // of width per point of size for each character, once the
        // plate's own padding is out of the way. Faerie Moot
        // Ornate runs narrower, so names now fit with room to
        // spare rather than trailing off.
        let fit = (width - 64) / CGFloat(chars)
        let ceiling: CGFloat = isMacUI
            ? min(50, max(30, width * 0.055))
            : 29
        let floor: CGFloat = isMacUI ? 15 : 13
        return min(ceiling, max(floor, fit))
    }

    var body: some View {
        VStack(spacing: 3) {
            TextField("Deck name", text: $name)
                .font(Theme.kingdomFont(size: nameFontSize))
                .foregroundStyle(Theme.parchment)
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .onSubmit(onCommit)
            KingdomText(text: subtitle,
                        size: isMacUI ? 20 : 19)
            KingdomText(text: "tap the name to rename it",
                        size: 16.5)
            ManaPipRow(pipSize: 16)
                .padding(.top, 3)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background { plate }
        .overlay { sparkles }
        .onAppear {
            withAnimation(.linear(duration: 18)
                .repeatForever(autoreverses: false)) {
                hueSpin = 360
            }
            twinkle = true
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { plateWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { newWidth in
                        plateWidth = newWidth
                    }
            }
        )
    }

    /// The plate: a bright foil rim around a dark leather center,
    /// with a translucent foil wash behind the name. Hue rotation
    /// makes the colors travel, the native echo of the web
    /// nameplate's rotating sparkly foil.
    private var plate: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.foilAngular)
                .hueRotation(.degrees(hueSpin))
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(
                    colors: [Theme.leather, Theme.leatherDeep],
                    startPoint: .top, endPoint: .bottom))
                .padding(3)
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Theme.foilAngular)
                .opacity(0.16)
                .hueRotation(.degrees(hueSpin))
                .padding(3)
        }
    }

    private var sparkles: some View {
        ZStack {
            sparkle(at: .topLeading, size: 13, delay: 0.0, inset: 10)
            sparkle(at: .topTrailing, size: 10, delay: 0.7, inset: 14)
            sparkle(at: .bottomLeading, size: 10, delay: 1.3, inset: 16)
            sparkle(at: .bottomTrailing, size: 14, delay: 0.4, inset: 9)
        }
        .allowsHitTesting(false)
    }

    private func sparkle(at alignment: Alignment, size: CGFloat,
                         delay: Double, inset: CGFloat) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size))
            .foregroundStyle(Color.white)
            .opacity(twinkle ? 0.9 : 0.15)
            .animation(.easeInOut(duration: 1.6)
                .repeatForever(autoreverses: true).delay(delay),
                       value: twinkle)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: alignment)
            .padding(inset)
    }
}

/// Hazard stripes for the override housing: diagonal
/// black bands over safety yellow, drawn fresh at
/// whatever size the housing takes.
private struct HazardStripes: View {
    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(red: 0.92, green: 0.72,
                                   blue: 0.10)))
            let stripe: CGFloat = 9
            var x = -size.height
            while x < size.width + stripe {
                var band = Path()
                band.move(to: CGPoint(x: x, y: size.height))
                band.addLine(to: CGPoint(x: x + stripe,
                                         y: size.height))
                band.addLine(to: CGPoint(x: x + stripe
                                        + size.height, y: 0))
                band.addLine(to: CGPoint(x: x + size.height,
                                         y: 0))
                band.closeSubpath()
                context.fill(band, with: .color(.black))
                x += stripe * 2
            }
        }
    }
}

/// An embossed lab label: white monospaced capitals on
/// a black strip, the letters given a raised edge the
/// way tape embossers and engraved equipment tags do
/// it. Used wherever the override housing speaks.
struct LabLabel: View {
    var text: String
    var size: CGFloat = 12

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .bold,
                          design: .monospaced))
            .tracking(size * 0.12)
            .foregroundStyle(Color.white.opacity(0.92))
            .shadow(color: .white.opacity(0.22),
                    radius: 0.5, x: 0, y: -0.5)
            .shadow(color: .black.opacity(0.85),
                    radius: 0.5, x: 0, y: 0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(white: 0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white.opacity(0.22),
                                  lineWidth: 0.75))
            .shadow(color: .black.opacity(0.4),
                    radius: 2, y: 1)
    }
}

/// The PNG limit override, built like the thing it is:
/// a guarded switch. Hazard striped housing, a cover
/// that slides up, and a red switch underneath. Closing
/// the cover knocks the switch off, the way the real
/// ones work, so the override never stays on by
/// accident. Session only: a fresh launch starts with
/// the cover down and the switch off.
struct GuardedOverride: View {
    @Binding var isOn: Bool
    @State private var coverOpen = false

    /// One fastener for the plexiglass corners: a little
    /// domed screw head with its highlight at the top.
    private var screwHead: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color.white.opacity(0.9),
                         Color(white: 0.45)],
                center: .topLeading,
                startRadius: 0, endRadius: 5))
            .frame(width: 7, height: 7)
            .overlay(
                Circle().strokeBorder(
                    Color.black.opacity(0.35),
                    lineWidth: 0.5))
    }

    /// One half of the rocker paddle: the pressed side
    /// sits darker, down in the bezel's shadow, and the
    /// raised side catches the light.
    private func rockerHalf(text: String, pressed: Bool)
        -> some View {
        ZStack {
            Rectangle()
                .fill(pressed
                    ? Color(red: 0.45, green: 0.05,
                            blue: 0.04)
                    : Color(red: 0.82, green: 0.14,
                            blue: 0.11))
            Text(text)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(Color.white.opacity(0.92))
                .shadow(color: .black.opacity(0.6),
                        radius: 1, y: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        VStack(spacing: 5) {
            LabLabel(text: "PNG LIMIT OVERRIDE", size: 13)
            ZStack {
                HazardStripes()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.13),
                                 Theme.leatherDeep,
                                 Color.black.opacity(0.35)],
                        startPoint: .top,
                        endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                Color.white.opacity(0.30),
                                lineWidth: 1))
                    .padding(7)
                // The switch itself: a power supply
                // rocker. ON is printed on the top half of
                // the paddle, OFF on the bottom, and the
                // paddle tilts so the live side sits
                // pressed into the bezel.
                Button {
                    if coverOpen {
                        withAnimation(.spring(
                            response: 0.22,
                            dampingFraction: 0.65)) {
                            isOn.toggle()
                        }
                    }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(white: 0.08))
                            .frame(width: 66, height: 78)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        Color.black.opacity(0.8),
                                        lineWidth: 2))
                        VStack(spacing: 0) {
                            rockerHalf(text: "ON",
                                       pressed: isOn)
                            rockerHalf(text: "OFF",
                                       pressed: !isOn)
                        }
                        .frame(width: 52, height: 64)
                        .clipShape(
                            RoundedRectangle(cornerRadius: 5))
                        .rotation3DEffect(
                            .degrees(isOn ? 9 : -9),
                            axis: (x: 1, y: 0, z: 0),
                            perspective: 0.55)
                    }
                }
                .buttonStyle(.plain)
                // The cover: a clear plexiglass plate over
                // the switch that slides up into the
                // housing. Light streaks across it, its
                // edges catch a bright line, and little
                // screw heads fasten the corners, the way
                // real acrylic boxes are put together.
                // Tapping it toggles it; closing it disarms.
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0.30),
                                     Color.white.opacity(0.08),
                                     Color.white.opacity(0.18)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing))
                    Rectangle()
                        .fill(LinearGradient(
                            colors: [Color.white.opacity(0),
                                     Color.white.opacity(0.35),
                                     Color.white.opacity(0)],
                            startPoint: .leading,
                            endPoint: .trailing))
                        .frame(width: 30)
                        .rotationEffect(.degrees(18))
                        .offset(x: -34)
                    VStack {
                        HStack {
                            screwHead
                            Spacer()
                            screwHead
                        }
                        Spacer()
                        HStack {
                            screwHead
                            Spacer()
                            screwHead
                        }
                    }
                    .padding(7)
                    LabLabel(text: "LIFT", size: 12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            Color.white.opacity(0.65),
                            lineWidth: 1.5))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .offset(y: coverOpen ? -64 : 0)
                    .opacity(coverOpen ? 0.45 : 1)
                    .onTapGesture {
                        withAnimation(.spring(
                            response: 0.35,
                            dampingFraction: 0.8)) {
                            coverOpen.toggle()
                            if !coverOpen { isOn = false }
                        }
                    }
            }
            .frame(width: 210, height: 118)
            .shadow(color: .black.opacity(0.35),
                    radius: 6, y: 3)
            LabLabel(
                text: coverOpen
                    ? (isOn ? "OVERRIDE ACTIVE: PNG LIMIT OFF"
                            : "COVER OPEN: FLIP SWITCH TO ARM")
                    : "SAFETY COVER ENGAGED",
                size: 11)
        }
    }
}


// MARK: - Monterey compatibility
//
// The Mac release runs back to macOS 12 (Monterey), so views
// go through these helpers instead of calling macOS 13 and
// newer SwiftUI directly. Each helper picks the modern API
// when it exists and the Monterey era equivalent otherwise.

/// A navigation container: NavigationStack on macOS 13 and
/// newer, NavigationView on Monterey.
struct NavContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 13.0, iOS 16.0, *) {
            NavigationStack(root: content)
        } else {
            NavigationView(content: content)
        }
    }
}

extension View {
    /// scrollContentBackground(.hidden) on macOS 13 and
    /// newer; on Monterey the scroll view simply keeps its
    /// default background.
    @ViewBuilder func hiddenScrollBackground() -> some View {
        if #available(macOS 13.0, iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    /// Hides a list row separator where the system
    /// offers it (macOS 13 and newer); Monterey lists
    /// keep their default separators.
    @ViewBuilder func hiddenRowSeparator() -> some View {
        if #available(macOS 13.0, iOS 16.0, *) {
            self.listRowSeparator(.hidden)
        } else {
            self
        }
    }

    /// The big control size on Mac: extraLarge where it
    /// exists (macOS 14 and newer), large on older systems.
    /// Other platforms always get large, as before.
    @ViewBuilder func buildControlSize() -> some View {
        #if os(macOS)
        if #available(macOS 14.0, *) {
            self.controlSize(.extraLarge)
        } else {
            self.controlSize(.large)
        }
        #else
        self.controlSize(.large)
        #endif
    }
}

/// Share button for a finished build file: ShareLink where
/// it exists, the system share picker on Monterey Macs.
struct FileShareButton<Label: View>: View {
    let url: URL
    @ViewBuilder var label: () -> Label

    var body: some View {
        if #available(macOS 13.0, iOS 16.0, *) {
            ShareLink(item: url, label: label)
        } else {
            #if os(macOS)
            MacSharePickerButton(url: url, label: label)
            #else
            ShareLink(item: url, label: label)
            #endif
        }
    }
}

#if os(macOS)
/// Monterey Mac share button: shows the system share
/// picker anchored to the button itself.
struct MacSharePickerButton<Label: View>: View {
    let url: URL
    @ViewBuilder var label: () -> Label

    @State private var anchorView: NSView?

    var body: some View {
        Button {
            guard let anchorView else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: anchorView.bounds,
                        of: anchorView, preferredEdge: .minY)
        } label: {
            label()
        }
        .background(ShareAnchorView(view: $anchorView))
    }
}

/// Captures the NSView behind a SwiftUI view so AppKit
/// pickers can anchor to it.
private struct ShareAnchorView: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        DispatchQueue.main.async { view = anchor }
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
