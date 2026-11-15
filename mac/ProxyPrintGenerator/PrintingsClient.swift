//
//  PrintingsClient.swift
//  Proxy Printer (native port) — Phase 4 selector: printing browser data
//
//  Fetches every printing of one card from Scryfall (unique=prints) for
//  the printing picker. Uses the shared Scryfall transport, so the
//  browser user agent, retries, and politeness rules match the rest
//  of the app.
//
//  App target only (used by the selector screens).
//

import Foundation

/// Preview resolution for face images. Grid tiles use small
/// (146 px wide, a few KB each); the picker uses normal; the zoom
/// view uses large.
public enum FaceImageQuality {
    case small
    case normal
    case large
}

public struct PrintingOption: Identifiable, Decodable, Sendable {
    public var name: String
    public var set: String
    public var collectorNumber: String
    public var layout: String
    public var typeLine: String?
    public var manaCost: String?
    public var imageURIs: ImageURIs?
    public var cardFaces: [Face]?

    public struct ImageURIs: Decodable, Sendable {
        public var png: String?
        public var large: String?
        public var normal: String?
        public var small: String?
    }
    public struct Face: Decodable, Sendable {
        public var imageURIs: ImageURIs?
        enum CodingKeys: String, CodingKey {
            case imageURIs = "image_uris"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, set, layout
        case collectorNumber = "collector_number"
        case typeLine = "type_line"
        case manaCost = "mana_cost"
        case imageURIs = "image_uris"
        case cardFaces = "card_faces"
    }

    public var id: String { "\(set)|\(collectorNumber)" }

    public var setAndNumber: String {
        "\(set.uppercased()) \(collectorNumber)"
    }

    /// Best image for the picker grid: the normal scan of the front
    /// face (or the top level image for single faced cards).
    public var displayImageURL: URL? {
        faceImageURL(0, quality: .normal)
    }

    /// True when this printing has a real back face to flip to.
    public var hasBackFace: Bool {
        ScryfallClient.twoSidedLayouts.contains(layout)
            && (cardFaces?.count ?? 0) > 1
    }

    /// Image for one face (0 front, 1 back). Two sided cards carry
    /// their images per face; everything else answers face 0 from the
    /// top level image and has no face 1.
    public func faceImageURL(_ faceIndex: Int,
                             quality: FaceImageQuality = .large) -> URL? {
        let uris: ImageURIs?
        if let faces = cardFaces, faces.indices.contains(faceIndex) {
            uris = faces[faceIndex].imageURIs
        } else if faceIndex == 0 {
            uris = imageURIs ?? cardFaces?.first?.imageURIs
        } else {
            uris = nil
        }
        let string: String?
        switch quality {
        case .small:
            string = uris?.small ?? uris?.normal ?? uris?.large ?? uris?.png
        case .normal:
            string = uris?.normal ?? uris?.large ?? uris?.png
        case .large:
            string = uris?.large ?? uris?.normal ?? uris?.png
        }
        guard let string else { return nil }
        return URL(string: string)
    }
}

private struct SearchPage: Decodable {
    var data: [PrintingOption]
    var has_more: Bool
    var next_page: String?
}

public enum PrintingsClient {

    /// Scryfall's canonical Magic card back image. Single faced cards
    /// flip over to this in the faces view.
    public static let cardBackImageURL =
        URL(string: "https://cards.scryfall.io/back.png")!

    /// All printings of the named card, oldest first. Follows
    /// Scryfall's pagination with the usual politeness pause.
    public static func allPrintings(of cardName: String) async throws
        -> [PrintingOption] {
        let session = ScryfallTransport.makeSession()
        let query = "!\"\(cardName)\""
        var components = URLComponents(
            string: "https://api.scryfall.com/cards/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "unique", value: "prints"),
            URLQueryItem(name: "order", value: "released"),
        ]
        var nextURL: URL? = components.url
        var options: [PrintingOption] = []
        var pages = 0
        while let url = nextURL, pages < 20 {
            if pages > 0 {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            let request = ScryfallTransport.makeRequest(url: url)
            let (data, http) = try await ScryfallTransport.data(
                for: request, attempts: 4, baseDelay: 3, session: session)
            guard http.statusCode == 200 else {
                throw ScryfallClientError.message(
                    "Scryfall printing search failed: HTTP \(http.statusCode)")
            }
            let page = try JSONDecoder().decode(SearchPage.self, from: data)
            options += page.data
            nextURL = (page.has_more ? page.next_page : nil)
                .flatMap { URL(string: $0) }
            pages += 1
        }
        return options
    }

    /// Free form card search for the replace card sheet: one
    /// printing per card (unique=cards), name order, capped so a
    /// wide filter cannot pull thousands of rows into the sheet.
    /// A query with no matches is a normal outcome here, so
    /// Scryfall's 404 for an empty result set reads as an empty
    /// array rather than an error.
    public static func searchCards(query: String) async throws
        -> [PrintingOption] {
        let session = ScryfallTransport.makeSession()
        var components = URLComponents(
            string: "https://api.scryfall.com/cards/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "unique", value: "cards"),
            URLQueryItem(name: "order", value: "name"),
        ]
        var nextURL: URL? = components.url
        var options: [PrintingOption] = []
        var pages = 0
        while let url = nextURL, pages < 3, options.count < 150 {
            if pages > 0 {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            let request = ScryfallTransport.makeRequest(url: url)
            let (data, http) = try await ScryfallTransport.data(
                for: request, attempts: 4, baseDelay: 3, session: session)
            if http.statusCode == 404 { return options }
            guard http.statusCode == 200 else {
                throw ScryfallClientError.message(
                    "Scryfall card search failed: HTTP \(http.statusCode)")
            }
            let page = try JSONDecoder().decode(SearchPage.self, from: data)
            options += page.data
            nextURL = (page.has_more ? page.next_page : nil)
                .flatMap { URL(string: $0) }
            pages += 1
        }
        return options
    }

    /// Resolves many card names in a few search requests, asking
    /// for all of them at once with an OR query instead of one
    /// lookup per card. Returns one printing per name found,
    /// keyed by the card's name as Scryfall spells it. A deck's
    /// worth of bare names costs one or two requests total,
    /// which keeps the faces loader clear of the rate limits
    /// that per card lookups trip.
    public static func resolveByNames(_ names: [String]) async throws
        -> [String: PrintingOption] {
        let session = ScryfallTransport.makeSession()
        var out: [String: PrintingOption] = [:]
        var start = 0
        while start < names.count {
            let batch = Array(names[start..<min(start + 20, names.count)])
            let query = batch
                .map { "name:\"\($0)\"" }
                .joined(separator: " or ")
            var components = URLComponents(
                string: "https://api.scryfall.com/cards/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "unique", value: "cards"),
            ]
            var nextURL: URL? = components.url
            var pages = 0
            while let url = nextURL, pages < 5 {
                if pages > 0 || start > 0 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                let request = ScryfallTransport.makeRequest(url: url)
                let (data, http) = try await ScryfallTransport.data(
                    for: request, attempts: 4, baseDelay: 3,
                    session: session)
                guard http.statusCode == 200 else {
                    throw ScryfallClientError.message(
                        "Scryfall name batch failed: HTTP \(http.statusCode)")
                }
                let page = try JSONDecoder().decode(SearchPage.self,
                                                    from: data)
                for option in page.data {
                    out[option.name] = option
                }
                nextURL = (page.has_more ? page.next_page : nil)
                    .flatMap { URL(string: $0) }
                pages += 1
            }
            start += batch.count
        }
        return out
    }

    /// Batch resolves exact printings through the collection endpoint
    /// into picker shaped options. The deck faces view uses this to
    /// get every card's images in a couple of requests instead of one
    /// search per card.
    public static func options(for keys: [PrintingKey]) async throws
        -> [PrintingKey: PrintingOption] {
        struct RequestBody: Encodable {
            struct Identifier: Encodable {
                var set: String
                var collector_number: String
            }
            var identifiers: [Identifier]
        }
        struct ResponseBody: Decodable {
            var data: [PrintingOption]
        }
        let session = ScryfallTransport.makeSession()
        var out: [PrintingKey: PrintingOption] = [:]
        var index = 0
        while index < keys.count {
            let batch = Array(keys[index..<min(index + 50, keys.count)])
            var request = ScryfallTransport.makeRequest(
                url: URL(string: "https://api.scryfall.com/cards/collection")!)
            request.httpMethod = "POST"
            request.setValue("application/json",
                             forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                RequestBody(identifiers: batch.map {
                    .init(set: $0.set, collector_number: $0.collectorNumber)
                }))
            let (data, http) = try await ScryfallTransport.data(
                for: request, attempts: 4, baseDelay: 3, session: session)
            guard http.statusCode == 200 else {
                throw ScryfallClientError.message(
                    "Scryfall collection lookup failed: HTTP \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(ResponseBody.self,
                                                   from: data)
            for option in decoded.data {
                out[PrintingKey(set: option.set,
                                collectorNumber: option.collectorNumber)] = option
            }
            index += batch.count
            if index < keys.count {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        return out
    }
}
