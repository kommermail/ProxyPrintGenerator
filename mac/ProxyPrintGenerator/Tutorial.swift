//
//  Tutorial.swift
//  ProxyPrintGenerator
//
//  The quick tutorial for new users, mirrored from the Windows
//  build (Nov 14, 2026): a foil "Click me for a tutorial!"
//  sticker with a wobbling WOW! burst under the Deck Library
//  masthead, opening a sheet that walks through finding a deck
//  on Moxfield, adding it, and building and printing it at top
//  quality. The Moxfield link opens in the web browser; the app
//  itself never connects to Moxfield.
//

import SwiftUI

enum Tutorial {
    /// Featured, ready-to-print decks.
    static let decksURL = URL(string: "https://moxfield.com/users/derptron4000")!
}

/// The tilted foil sticker with a WOW! burst on its corner, in
/// the same spirit as the realism sticker. Click it to open the
/// tutorial.
struct TutorialSticker: View {
    let onTap: () -> Void
    @State private var wobble = false
    @State private var hovering = false

    var body: some View {
        Button {
            onTap()
        } label: {
            ZStack(alignment: .topLeading) {
                ZStack {
                    GlitterOverlay(seed: 77)
                    Text("Click me for a tutorial!")
                        .font(Theme.plaqueFont(size: isMacUI ? 21 : 18))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(.leading, 52)
                .padding(.trailing, 22)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14,
                                     style: .continuous)
                        .fill(Theme.foilLinear))
                .overlay(
                    RoundedRectangle(cornerRadius: 14,
                                     style: .continuous)
                        .strokeBorder(Color.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.45),
                        radius: 4.5, x: 0, y: 3)
                WowBurst()
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(wobble ? -2 : -12))
                    .offset(x: -28, y: -30)
                    .allowsHitTesting(false)
            }
            .padding(.top, 30)
            .padding(.leading, 28)
            .rotationEffect(.degrees(-1.5))
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("A quick walkthrough: find a deck, add it, and print it in high quality")
        .accessibilityLabel("Click me for a tutorial")
        .onHover { hovering = $0 }
        .onAppear {
            // A slow wobble on the burst, so a first-time eye
            // lands on it.
            withAnimation(.easeInOut(duration: 1.4)
                            .repeatForever(autoreverses: true)) {
                wobble = true
            }
        }
    }
}

/// The WOW! starburst itself: the realism sticker's colors
/// cut in BurstShape, with a white rim.
private struct WowBurst: View {
    var body: some View {
        ZStack {
            BurstShape()
                .fill(LinearGradient(
                    colors: [Color(red: 1.00, green: 0.25, blue: 0.55),
                             Color(red: 1.00, green: 0.55, blue: 0.20),
                             Color(red: 1.00, green: 0.80, blue: 0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
            BurstShape()
                .stroke(Color.white, lineWidth: 3)
            Text("WOW!")
                .font(.system(size: 19, weight: .black,
                              design: .rounded))
                .foregroundStyle(Color.white)
                .shadow(color: .black.opacity(0.45),
                        radius: 1.2, x: 0, y: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 2)
    }
}

/// The tutorial sheet: five numbered steps on leather.
struct TutorialSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavContainer {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    OrnamentCaption(
                        text: "Five easy steps from a deck list to proxies that look like the real thing.",
                        size: isMacUI ? 19 : 17)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 10)

                    step(1, "Find a deck", [
                        "Ready-to-print decks are waiting at **moxfield.com/users/derptron4000**, and any other Moxfield account's public decks work too.",
                        "Open a deck, click **More**, then **Export**, then **Copy for Moxfield**. That copies the list with every card's exact printing.",
                    ]) {
                        Button("Browse derptron4000's decks on Moxfield") {
                            openURL(Tutorial.decksURL)
                        }
                        .buttonStyle(FantasyButtonStyle(
                            fontSize: isMacUI ? 17 : 15))
                        .fixedSize()
                        .padding(.top, 6)
                        .help("Opens moxfield.com/users/derptron4000 in your web browser")
                    }
                    step(2, "Add it to your library", [
                        "Click **ADD A DECK**, choose **Paste a deck list**, give it a name and paste. A saved .txt list works too: choose **Open a .txt file**.",
                        "Just want to print once without saving? Paste it on the **Quick Build** tab instead.",
                    ])
                    step(3, "Check your cards", [
                        "Open the deck from your library. Click a card to flip it, double-click to zoom in, and swap any card to a printing whose art you like better.",
                    ])
                    step(4, "Set it up for top quality", [
                        "**Scale:** 600 is right for home printers. Save 1200 or 1800 for a print shop.",
                        "Click the **POP!** realism sticker to turn on auto vibrance. It adds vibrance and lifts the midtones, so cards print bright and punchy instead of dull.",
                        "Pick your **Paper** size. If a card edge gets cut off, open **Print options** and set **Safe area** to **Fit to my printer**.",
                        "Want your printer maker's exact paper types, like matte photo paper? The print window's **Printer setup guide** walks you through it in a few minutes. It's optional; everything prints fine without it.",
                    ])
                    step(5, "Build and print", [
                        "Click **Build PDF**, then **Print**. The app always prints at actual size, so every card comes out true to size.",
                        "For the richest colors, print on matte photo paper and pick its preset under **Print with a preset**.",
                        "Cut along the guides and slide each proxy into a sleeve in front of an old card. It feels just like the real thing.",
                    ])

                    OrnamentCaption(
                        text: "For personal playtesting only. Don't sell proxies or use them in sanctioned play.",
                        size: isMacUI ? 16 : 15)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 6)

                    Button("Got it, let's print!") { dismiss() }
                        .buttonStyle(FantasyButtonStyle(
                            fontSize: isMacUI ? 20 : 18))
                        .frame(maxWidth: 320)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .background(LeatherBackground())
            .navigationTitle("Quick tutorial")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 820,
               minHeight: 560, idealHeight: 760)
        #endif
    }

    private func step(_ number: Int, _ title: String,
                      _ lines: [String]) -> some View {
        step(number, title, lines) { EmptyView() }
    }

    /// One numbered step: a gold medallion, a title, and its
    /// lines, with anything extra (a button) under them.
    private func step<Extra: View>(
        _ number: Int, _ title: String, _ lines: [String],
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.98, green: 0.87, blue: 0.50),
                                 Color(red: 0.63, green: 0.44, blue: 0.14)],
                        startPoint: .top, endPoint: .bottom))
                Circle()
                    .strokeBorder(Theme.parchment.opacity(0.9),
                                  lineWidth: 2)
                Text("\(number)")
                    .font(Theme.plaqueFont(size: 21))
                    .foregroundStyle(Theme.ink)
            }
            .frame(width: 40, height: 40)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                PlaqueTitleText(text: title, size: isMacUI ? 25 : 22)
                    .fixedSize()
                ForEach(lines, id: \.self) { line in
                    Text(Self.styled(line))
                        .font(Theme.fellFont(size: isMacUI ? 18 : 16))
                        .foregroundStyle(Theme.parchment.opacity(0.94))
                        .fixedSize(horizontal: false, vertical: true)
                }
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    /// A line of help text; **words** in double asterisks are
    /// the names of buttons and settings, set in bold gold.
    static func styled(_ text: String) -> AttributedString {
        var out = AttributedString()
        for (i, part) in text.components(separatedBy: "**")
            .enumerated() where !part.isEmpty {
            var run = AttributedString(part)
            if i % 2 == 1 {
                run.foregroundColor = Theme.gold
                run.inlinePresentationIntent = .stronglyEmphasized
            }
            out += run
        }
        return out
    }
}
