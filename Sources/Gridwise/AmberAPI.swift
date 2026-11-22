import Foundation

// Amber's public API (https://api.amber.com.au/v1), with the user's own API token from
// app.amber.com.au/developers. Read-only: sites, prices and metered usage. Amber allows 50 requests per
// 5 minutes per token; the app stays well under that.

struct AmberSite: Decodable, Identifiable, Equatable {
    let id: String
    let network: String?
    let status: String?
    let activeFrom: String?
    let channels: [Channel]?
    struct Channel: Decodable, Equatable { let type: String?; let tariff: String? }

    var hasFeedIn: Bool { channels?.contains { $0.type == "feedIn" } ?? false }
}

/// One half hour of prices for one channel. Amber's sign convention is kept: a negative feed-in price
/// means Amber pays you to export, a positive one means exporting costs you.
struct PriceInterval: Decodable, Identifiable {
    let type: String                 // ActualInterval, CurrentInterval, ForecastInterval
    let startTime: Date
    let endTime: Date
    let perKwh: Double
    let spotPerKwh: Double?
    let renewables: Double?
    let channelType: String          // general, feedIn, controlledLoad
    let spikeStatus: String?
    let descriptor: String?
    let advancedPrice: Advanced?
    struct Advanced: Decodable { let low: Double?; let predicted: Double?; let high: Double? }

    var id: String { channelType + startTime.description }
    var isForecast: Bool { type == "ForecastInterval" }
    var isCurrent: Bool { type == "CurrentInterval" }
}

/// One metered interval. cost is in cents; feed-in rows have a negative cost when you were paid.
struct UsageInterval: Decodable {
    let date: String?                // the billing day Amber files it under (NEM time, so up to 30 min off local midnight)
    let startTime: Date
    let kwh: Double
    let cost: Double
    let channelType: String
    let quality: String?
}

enum AmberAPIError: LocalizedError {
    case noToken, rejected, limited(Int), http(Int), network(String)
    var errorDescription: String? {
        switch self {
        case .noToken: return "No Amber API token yet."
        case .rejected: return "Amber did not accept the API token. Make a new one at app.amber.com.au/developers."
        case .limited(let s): return "Amber is limiting requests; trying again in about \(s) seconds."
        case .http(let c): return "Amber's API answered with an error (\(c))."
        case .network(let m): return "Could not reach Amber: \(m)"
        }
    }
}

struct AmberAPI {
    let token: String
    private static let base = URL(string: "https://api.amber.com.au/v1")!
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpCookieStorage = nil; c.urlCache = nil
        return URLSession(configuration: c)
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let full = ISO8601DateFormatter(); full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let t = plain.date(from: s) ?? full.date(from: s) { return t }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        var c = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await Self.session.data(for: r) } catch { throw AmberAPIError.network(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 401, 403: throw AmberAPIError.rejected
        case 429: throw AmberAPIError.limited(Int((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60)
        default: throw AmberAPIError.http(code)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    func sites() async throws -> [AmberSite] { try await get("sites") }

    /// The last `previous` and next `next` half hours, both channels.
    func prices(site: String, previous: Int = 24, next: Int = 24) async throws -> [PriceInterval] {
        try await get("sites/\(site)/prices/current", ["previous": "\(previous)", "next": "\(next)", "resolution": "30"])
    }

    /// Metered usage, day by day; Amber answers at most about a week per request.
    func usage(site: String, from: Date, to: Date, calendar: Calendar) async throws -> [UsageInterval] {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_AU_POSIX"); f.dateFormat = "yyyy-MM-dd"
        var rows: [UsageInterval] = []
        var d = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        while d <= end {
            let chunkEnd = min(end, calendar.date(byAdding: .day, value: 6, to: d)!)
            rows += try await get("sites/\(site)/usage", ["startDate": f.string(from: d), "endDate": f.string(from: chunkEnd)])
            d = calendar.date(byAdding: .day, value: 1, to: chunkEnd)!
        }
        return rows
    }
}
