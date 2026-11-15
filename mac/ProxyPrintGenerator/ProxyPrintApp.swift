//
//  ProxyPrintApp.swift
//  Proxy Printer (native port) — Phase 2 app entry point
//
//  One SwiftUI app that runs on Mac and iPhone. The engine files
//  (DeckList, ScryfallClient, ImagePipeline, PDFBuilder) are shared
//  with the command line harness; main.swift belongs to the harness
//  only and must NOT be added to the app target (it has its own
//  top level entry point and would collide with this one).
//
//  At startup the app registers the bundled fantasy fonts (the
//  Printing Selector theme: Cinzel Decorative, Cinzel, IM Fell
//  English) so Theme.swift can use them on both platforms without
//  any Info.plist entries. A missing font file is skipped quietly;
//  the views fall back to the system font.
//

import SwiftUI
import CoreText

@main
struct ProxyPrintApp: App {

    init() {
        #if os(macOS)
        // Before DeckStore opens decks.json: bring decks over from
        // the old App Sandbox container, once.
        AppData.migrateFromSandboxContainer()
        #endif
        for name in ["CinzelDecorative-Bold", "CinzelDecorative-Regular",
                     "Cinzel-Bold", "Cinzel-Regular",
                     "IMFellEnglish-Regular", "IMFellEnglish-Italic",
                     "RiseofKingdom", "FaerieMootSimple"] {
            if let url = Bundle.main.url(forResource: name,
                                         withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL,
                                                 .process, nil)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
