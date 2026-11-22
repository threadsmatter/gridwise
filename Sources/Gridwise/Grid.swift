import Foundation

// The wholesale side: AEMO's price and demand for the user's region (now, the last 24 hours and AEMO's
// forecast), and what is generating, from Open Electricity (CC BY 4.0, built from AEMO data). Neither
// needs an account. Nothing about the user is sent: the only thing that varies is the region code.

struct WholesalePoint: Identifiable {
    let t: Date
    let cents: Double            // c/kWh, ex GST, before network charges
    let demandMW: Double?
    let forecast: Bool
    var id: Date { t }
}

struct Wholesale {
    let region: Region
    let at: Date
    let cents: Double
    let demandMW: Double?
    let series: [WholesalePoint]
}

struct FuelMix {
    let at: Date
    let mw: [(fuel: String, mw: Double)]      // stacking order
    var renewableShare: Double? {
        let total = mw.filter { $0.fuel != "Imports" }.reduce(0) { $0 + $1.mw }
        guard total > 0 else { return nil }
        return mw.filter { GridData.renewable.contains($0.fuel) }.reduce(0) { $0 + $1.mw } / total
    }
}

enum GridError: LocalizedError {
    case stale(Date), empty, http(Int), network(String)
    var errorDescription: String? {
        switch self {
        case .stale(let t):
            let f = DateFormatter(); f.locale = Locale(identifier: "en_AU"); f.dateFormat = "h:mm a 'on' d MMM"
            return "AEMO's price feed has not updated since \(f.string(from: t))."
        case .empty: return "AEMO's feed had no prices for this region."
        case .http(let c): return c == 429 ? "AEMO is limiting requests; trying again shortly." : "AEMO's feed answered with an error (\(c))."
        case .network(let m): return "Could not reach AEMO: \(m)"
        }
    }
}

enum GridData {
    static let renewable: Set<String> = ["Rooftop solar", "Solar farms", "Wind", "Hydro"]
    static let fuels: [(String, [String])] = [
        ("Coal", ["coal_black", "coal_brown"]), ("Gas", ["gas_ccgt", "gas_ocgt", "gas_recip", "gas_steam", "gas_wcmg"]),
        ("Hydro", ["hydro"]), ("Wind", ["wind"]), ("Solar farms", ["solar_utility"]), ("Rooftop solar", ["solar_rooftop"]),
        ("Batteries", ["battery_discharging"]), ("Other", ["distillate", "bioenergy_biomass", "bioenergy_biogas"]), ("Imports", ["imports"]),
    ]

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 45
        c.httpCookieStorage = nil; c.urlCache = nil
        c.httpAdditionalHeaders = ["User-Agent": "Gridwise (Mac app)"]
        return URLSession(configuration: c)
    }()

    private static func json(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        var r = URLRequest(url: url)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: r) } catch { throw GridError.network(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw GridError.http(code) }
        return try JSONSerialization.jsonObject(with: data)
    }

    // AEMO's NEM Dashboard feed wants the key its own page hands every visitor (config.json). It is fetched
    // when needed, kept in memory only, and fetched again if AEMO changes it.
    private static let aemoSite = URL(string: "https://dashboards.public.aemo.com.au")!
    private static var aemoKey: String?

    private static func aemo(_ path: String) async throws -> [String: Any] {
        for fresh in [false, true] {
            if fresh || aemoKey == nil {
                let cfg = try await json(aemoSite.appendingPathComponent("config.json")) as? [String: Any]
                aemoKey = cfg?["xApiKey"] as? String
            }
            do {
                let url = URL(string: aemoSite.absoluteString + "/NEM/v1/PWS/NEMDashboard/" + path)!
                let d = try await json(url, headers: ["x-api-key": aemoKey ?? "", "Accept": "*/*"]) as? [String: Any]
                return d?["data"] as? [String: Any] ?? [:]
            } catch GridError.http(let c) where !fresh && (c == 401 || c == 403) {
                continue
            }
        }
        return [:]
    }

    private static func nemDate(_ s: String) -> Date? {
        // AEMO writes NEM time (UTC+10) with or without the offset
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        let g = DateFormatter(); g.locale = Locale(identifier: "en_US_POSIX"); g.timeZone = TimeZone(secondsFromGMT: 36000)
        g.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return g.date(from: String(s.prefix(19)))
    }

    /// Price and demand for one region: the last 24 hours as half-hour averages, then AEMO's forecast.
    /// Throws `.stale` when the feed has stopped moving (it froze for a day on 15 Nov 2026 and kept answering).
    static func wholesale(_ region: Region) async throws -> Wholesale {
        let items = (try await aemo("priceAndDemand?timescale=30MIN")["items"] as? [[String: Any]] ?? [])
            .filter { $0["regionId"] as? String == region.rawValue }
        var halves: [Date: [(Double, Double)]] = [:]
        var forecast: [WholesalePoint] = []
        var newest: (Date, Double, Double)?
        for x in items {
            guard let s = x["settlementDate"] as? String, let t = nemDate(s), let rrp = (x["rrp"] as? NSNumber)?.doubleValue else { continue }
            let demand = (x["totalDemand"] as? NSNumber)?.doubleValue ?? 0
            if x["periodType"] as? String == "ACTUAL" {
                let end = Date(timeIntervalSince1970: (t.timeIntervalSince1970 / 1800).rounded(.up) * 1800)
                halves[end, default: []].append((rrp, demand))
                if newest == nil || t > newest!.0 { newest = (t, rrp, demand) }
            } else {
                forecast.append(WholesalePoint(t: t, cents: rrp / 10, demandMW: demand, forecast: true))
            }
        }
        guard let now = newest else { throw GridError.empty }
        if Date().timeIntervalSince(now.0) > 1200 { throw GridError.stale(now.0) }
        let cut = Date().addingTimeInterval(-86400)
        let past = halves.filter { $0.key >= cut }.sorted { $0.key < $1.key }.map { t, v in
            WholesalePoint(t: t, cents: v.map(\.0).reduce(0, +) / Double(v.count) / 10, demandMW: v.map(\.1).reduce(0, +) / Double(v.count), forecast: false)
        }
        let last = past.last?.t ?? now.0
        return Wholesale(region: region, at: now.0, cents: now.1 / 10, demandMW: now.2,
                         series: past + forecast.filter { $0.t > last }.sorted { $0.t < $1.t })
    }

    /// What is generating in the region now (the newest 5 minutes every fuel has reported).
    static func mix(_ region: Region) async throws -> FuelMix {
        let url = URL(string: "https://data.openelectricity.org.au/v4/stats/au/NEM/\(region.rawValue)/power/7d.json")!
        let d = try await json(url) as? [String: Any]
        var byTech: [String: [Date: Double]] = [:]
        let iso = ISO8601DateFormatter()
        for x in (d?["data"] as? [[String: Any]] ?? []) where x["type"] as? String == "power" {
            guard let tech = x["fuel_tech"] as? String, let h = x["history"] as? [String: Any],
                  let startS = h["start"] as? String, let start = iso.date(from: startS),
                  let vals = h["data"] as? [Any] else { continue }
            let step: Double = (h["interval"] as? String) == "30m" ? 1800 : 300
            var pts: [Date: Double] = [:]
            for (i, v) in vals.enumerated() { if let n = (v as? NSNumber)?.doubleValue { pts[start.addingTimeInterval(Double(i) * step)] = n } }
            byTech[tech] = pts
        }
        // fuels report at different lags (rooftop solar runs behind), so "now" is the newest time all recent ones reached
        let latestEach = byTech.values.compactMap { $0.keys.max() }
        guard let newest = latestEach.max() else { throw GridError.empty }
        let now = latestEach.filter { $0 >= newest.addingTimeInterval(-3 * 3600) }.min() ?? newest
        let out = fuels.map { name, techs in (fuel: name, mw: techs.reduce(0.0) { $0 + max(0, byTech[$1]?[now] ?? 0) }) }.filter { $0.mw >= 1 }
        return FuelMix(at: now, mw: out)
    }
}
