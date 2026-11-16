//
//  ScryfallClient.swift
//  Version 7
//  Proxy Printer (native port) — Phase 1 engine
//
//  Scryfall API access over URLSession:
//    - bulk identifiers lookup (POST /cards/collection, batches of 50) for
//      lines that name an exact printing
//    - named lookup (GET /cards/named?exact=) for name-only lines
//    - PNG face URL selection, including card_faces for two sided cards
//
//  Every request carries a browser style User-Agent. This matters twice
//  over: Scryfall asks for an identifying agent, and the image CDN
//  (cards.scryfall.io) silently drops connections from custom agents —
//  a trap already paid for in the Python version, where image downloads
//  failed with RemoteDisconnected while API calls succeeded.
//

import Foundation

public nonisolated enum ScryfallClientError: Error, CustomStringConvertible {
    case message(String)
    /// A download the app refuses to use: not Scryfall, not
    /// HTTPS, or far too big. Never retried.
    case unsafe(String)
    public var description: String {
        switch self {
        case .message(let text), .unsafe(let text): return text
        }
    }
}

/// Identifies one exact printing, mirroring the Python (set, number) key.
/// Marked nonisolated: the app target isolates declarations to the
/// main actor by default, but this is a plain value pair that the
/// faces loader builds inside background lookup tasks.
public nonisolated struct PrintingKey: Hashable, Sendable {
    public var set: String
    public var collectorNumber: String
    public init(set: String, collectorNumber: String) {
        self.set = set.lowercased()
        // Some deck sources write collector numbers with a
        // leading "#" ("(teve) #3"). Scryfall's exact lookup
        // rejects that form, so the number is cleaned here,
        // at the one point every lookup key passes through.
        var number = collectorNumber
            .trimmingCharacters(in: .whitespaces)
        if number.hasPrefix("#") {
            number = String(number.dropFirst())
                .trimmingCharacters(in: .whitespaces)
        }
        self.collectorNumber = number
    }
}

public nonisolated struct ScryfallCard: Decodable {
    public var name: String
    public var set: String
    public var collectorNumber: String
    public var layout: String
    public var typeLine: String?
    public var imageURIs: ImageURIs?
    public var cardFaces: [CardFace]?

    public struct ImageURIs: Decodable {
        public var png: String?
    }
    public struct CardFace: Decodable {
        public var name: String?
        public var imageURIs: ImageURIs?

        enum CodingKeys: String, CodingKey {
            case name
            case imageURIs = "image_uris"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, set, layout
        case typeLine = "type_line"
        case collectorNumber = "collector_number"
        case imageURIs = "image_uris"
        case cardFaces = "card_faces"
    }
}

/// Shared retrying transport used by both the API client and the image
/// pipeline. Retries transport failures and 429/5xx responses; any other
/// completed response is returned for the caller to judge. Every
/// request passes through here, so this is also where the app makes
/// sure it only ever talks to Scryfall over HTTPS and never takes in
/// more than it can safely hold.
public nonisolated enum ScryfallTransport {

    /// Larger than any Scryfall reply or card PNG by a wide
    /// margin.
    public static let maxResponseBytes = 32 * 1024 * 1024

    /// Only Scryfall, only HTTPS: the API host and the image
    /// CDN, or a subdomain of either.
    public static func isAllowed(_ url: URL?) -> Bool {
        guard let url = url, url.scheme == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        for domain in ["scryfall.com", "scryfall.io"] {
            if host == domain || host.hasSuffix("." + domain) {
                return true
            }
        }
        return false
    }
    public static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        // Bounded waits. Without a resource timeout, a
        // stalled connection can sit near idle for many
        // minutes per card while retries pile up, which
        // looks exactly like a frozen build: thirty
        // seconds without data fails the attempt, and
        // three minutes caps the whole fetch.
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        config.httpAdditionalHeaders = [
            "User-Agent": browserUserAgent,
            "Accept": "*/*",
        ]
        return URLSession(configuration: config)
    }

    public static func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    /// - Parameters:
    ///   - attempts: total tries, mirroring the Python retry counts.
    ///   - baseDelay: sleep before retry n is baseDelay * n seconds
    ///     (the Python code sleeps delay * (attempt + 1)).
    public static func data(for request: URLRequest, attempts: Int,
                            baseDelay: Double,
                            session: URLSession) async throws
        -> (Data, HTTPURLResponse) {
        guard isAllowed(request.url) else {
            throw ScryfallClientError.unsafe(
                "[PPG:BLOCKED-URL] Refused to download from "
                    + "\(request.url?.absoluteString ?? "?"): "
                    + "only Scryfall over HTTPS is allowed.")
        }
        var lastError: Error?
        for attempt in 0..<attempts {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ScryfallClientError.message(
                        "Non HTTP response for \(request.url?.absoluteString ?? "?")")
                }
                // A redirect must land on Scryfall too.
                if !isAllowed(http.url) {
                    throw ScryfallClientError.unsafe(
                        "[PPG:BLOCKED-URL] A download redirected "
                            + "somewhere that is not Scryfall "
                            + "over HTTPS, so it was not used.")
                }
                if http.expectedContentLength > Int64(maxResponseBytes)
                    || data.count > maxResponseBytes {
                    throw ScryfallClientError.unsafe(
                        "[PPG:TOO-BIG] The reply from "
                            + "\(http.url?.absoluteString ?? "?") "
                            + "is over 32 MB, far bigger than any "
                            + "card, so it was not used.")
                }
                if http.statusCode == 429 || http.statusCode >= 500 {
                    lastError = ScryfallClientError.message(
                        "HTTP \(http.statusCode) for \(request.url?.absoluteString ?? "?")")
                } else {
                    return (data, http)
                }
            } catch let error as ScryfallClientError {
                // A refused download is never retried.
                if case .unsafe = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(
                    nanoseconds: UInt64(baseDelay * Double(attempt + 1) * 1_000_000_000))
            }
        }
        throw lastError ?? ScryfallClientError.message(
            "Request failed: \(request.url?.absoluteString ?? "?")")
    }
}

public nonisolated final class ScryfallClient {

    /// Layouts that truly print a back face. Adventure, split, and saga
    /// cards print from their top level image on one side only.
    public static let twoSidedLayouts: Set<String> = [
        "transform", "modal_dfc", "reversible_card",
    ]

    private let session: URLSession

    public init(session: URLSession = ScryfallTransport.makeSession()) {
        self.session = session
    }

    // MARK: - Bulk lookup

    private struct CollectionRequest: Encodable {
        struct Identifier: Encodable {
            var set: String
            var collector_number: String
        }
        var identifiers: [Identifier]
    }

    private struct CollectionResponse: Decodable {
        struct NotFound: Decodable {
            var set: String?
            var collector_number: String?
            var name: String?
        }
        var data: [ScryfallCard]
        var not_found: [NotFound]
    }

    /// Looks up exact printings in batches of 50, like the Python
    /// script. In strict mode (the default), throws if Scryfall
    /// reports any identifier as not found. A lenient lookup
    /// returns the printings it did find and leaves the missing
    /// ones for the caller to resolve another way.
    public func lookupPrintings(_ keys: [PrintingKey],
                                strict: Bool = true) async throws
        -> [PrintingKey: ScryfallCard] {
        var out: [PrintingKey: ScryfallCard] = [:]
        var index = 0
        while index < keys.count {
            let batch = Array(keys[index..<min(index + 50, keys.count)])
            var request = ScryfallTransport.makeRequest(
                url: URL(string: "https://api.scryfall.com/cards/collection")!)
            request.httpMethod = "POST"
            request.setValue("application/json",
                             forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                CollectionRequest(identifiers: batch.map {
                    .init(set: $0.set, collector_number: $0.collectorNumber)
                }))
            let (data, http) = try await ScryfallTransport.data(
                for: request, attempts: 4, baseDelay: 3, session: session)
            guard http.statusCode == 200 else {
                throw ScryfallClientError.message(
                    "Scryfall collection lookup failed: HTTP \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(CollectionResponse.self,
                                                   from: data)
            for card in decoded.data {
                out[PrintingKey(set: card.set,
                                collectorNumber: card.collectorNumber)] = card
            }
            if strict, let missing = decoded.not_found.first {
                throw ScryfallClientError.message(
                    "Scryfall could not find: (\(missing.set ?? "?")) \(missing.collector_number ?? "?")")
            }
            index += batch.count
            if index < keys.count {
                // Scryfall rate guidance, same pause as the Python script.
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        return out
    }


    /// Which of these names Scryfall cannot find, asked in
    /// batches of 50 through the collection endpoint with name
    /// identifiers, the way the Windows text editor checks the
    /// names in a deck being edited. The returned set holds the
    /// names it could not find, spelled as they were sent.
    public func unknownNames(_ names: [String]) async throws
        -> Set<String> {
        struct NameRequest: Encodable {
            struct Identifier: Encodable { var name: String }
            var identifiers: [Identifier]
        }
        var unknown: Set<String> = []
        var index = 0
        while index < names.count {
            let batch = Array(names[index..<min(index + 50,
                                                 names.count)])
            var request = ScryfallTransport.makeRequest(
                url: URL(string:
                    "https://api.scryfall.com/cards/collection")!)
            request.httpMethod = "POST"
            request.setValue("application/json",
                             forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                NameRequest(identifiers: batch.map {
                    .init(name: $0)
                }))
            let (data, http) = try await ScryfallTransport.data(
                for: request, attempts: 4, baseDelay: 3,
                session: session)
            guard http.statusCode == 200 else {
                throw ScryfallClientError.message(
                    "Scryfall name check failed: HTTP \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(
                CollectionResponse.self, from: data)
            for missing in decoded.not_found {
                if let name = missing.name {
                    unknown.insert(name)
                }
            }
            index += batch.count
            if index < names.count {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        return unknown
    }

    // MARK: - Named lookup

    /// Resolves a name-only line to a concrete printing. When a set is
    /// given (a "(set)" suffix with no collector number) it is passed as
    /// the preferred set.
    public func lookupNamed(name: String, set: String?,
                            maxAttempts: Int = 6) async throws
        -> ScryfallCard {
        // Politeness pause before each named request. Lines without a
        // printing are resolved one at a time, and a full deck can fire
        // dozens of these back to back; Scryfall answers that burst
        // with HTTP 429 (rate limited), which is what this prevents.
        try? await Task.sleep(nanoseconds: 150_000_000)
        var components = URLComponents(
            string: "https://api.scryfall.com/cards/named")!
        var query = [URLQueryItem(name: "exact", value: name)]
        if let set = set { query.append(URLQueryItem(name: "set", value: set)) }
        components.queryItems = query
        let request = ScryfallTransport.makeRequest(url: components.url!)
        let (data, http) = try await ScryfallTransport.data(
            for: request, attempts: maxAttempts, baseDelay: 4,
            session: session)
        if http.statusCode == 404 {
            throw ScryfallClientError.message(
                "Scryfall could not find a card named: \(name)")
        }
        guard http.statusCode == 200 else {
            throw ScryfallClientError.message(
                "Scryfall named lookup failed: HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(ScryfallCard.self, from: data)
    }

    // MARK: - Face images

    /// PNG scan URLs for every printable face of a card: two URLs for a
    /// true two sided card (front, back), one for everything else.
    public static func facePNGURLs(for card: ScryfallCard) throws -> [URL] {
        let strings: [String?]
        if twoSidedLayouts.contains(card.layout),
           let faces = card.cardFaces, !faces.isEmpty {
            strings = faces.map { $0.imageURIs?.png }
        } else {
            strings = [card.imageURIs?.png]
        }
        return try strings.enumerated().map { idx, string in
            guard let string = string, let url = URL(string: string) else {
                throw ScryfallClientError.message(
                    "No PNG image for \(card.name) face \(idx)")
            }
            return url
        }
    }
}
