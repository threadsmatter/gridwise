import Foundation

// Weather and a solar outlook from Open-Meteo (no account, no key). The only thing sent is the location,
// rounded to about a kilometre, which the user chose in Setup. Finding a place by name uses Open-Meteo's
// geocoding service with the text the user typed.

struct WeatherDay: Identifiable {
    let date: Date
    let code: Int?
    let tMax: Double?
    let tMin: Double?
    let rainChance: Double?
    let sunMJ: Double?            // shortwave radiation, MJ/m² for the day
    var id: Date { date }
    var sunKWhPerM2: Double? { sunMJ.map { $0 / 3.6 } }
}

struct WeatherNow {
    let temp: Double?
    let code: Int?
    let cloud: Double?
    let wind: Double?
}

struct Weather {
    let now: WeatherNow
    let days: [WeatherDay]
    let hourly: [(t: Date, w: Double)]       // shortwave radiation, W/m², today and tomorrow
}

struct Place: Identifiable, Hashable {
    let name: String
    let detail: String
    let latitude: Double
    let longitude: Double
    var id: String { "\(name)|\(latitude)|\(longitude)" }
}

enum WeatherService {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.httpCookieStorage = nil; c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private static func get(_ url: URL) async throws -> [String: Any] {
        var last: Error = URLError(.unknown)
        for attempt in 0..<3 {                 // Open-Meteo's servers drop out for minutes at a time: try again soon
            do {
                let (data, resp) = try await session.data(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            } catch { last = error }
            if attempt < 2 { try? await Task.sleep(for: .seconds(3)) }
        }
        throw last
    }

    static func places(matching text: String) async throws -> [Place] {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: text), .init(name: "count", value: "8"), .init(name: "countryCode", value: "AU"),
                        .init(name: "language", value: "en"), .init(name: "format", value: "json")]
        let d = try await get(c.url!)
        return (d["results"] as? [[String: Any]] ?? []).compactMap { r in
            guard let n = r["name"] as? String, let la = (r["latitude"] as? NSNumber)?.doubleValue,
                  let lo = (r["longitude"] as? NSNumber)?.doubleValue else { return nil }
            let detail = [r["admin1"] as? String, (r["postcodes"] as? [String])?.first].compactMap { $0 }.joined(separator: " ")
            return Place(name: n, detail: detail, latitude: la, longitude: lo)
        }
    }

    static func forecast(latitude: Double, longitude: Double, timeZone: TimeZone) async throws -> Weather {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", latitude)), .init(name: "longitude", value: String(format: "%.2f", longitude)),
            .init(name: "timezone", value: timeZone.identifier), .init(name: "forecast_days", value: "7"),
            .init(name: "current", value: "temperature_2m,weather_code,cloud_cover,wind_speed_10m"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,shortwave_radiation_sum"),
            .init(name: "hourly", value: "shortwave_radiation"),
        ]
        let d = try await get(c.url!)
        let dayF = DateFormatter(); dayF.locale = Locale(identifier: "en_US_POSIX"); dayF.timeZone = timeZone; dayF.dateFormat = "yyyy-MM-dd"
        let hourF = DateFormatter(); hourF.locale = Locale(identifier: "en_US_POSIX"); hourF.timeZone = timeZone; hourF.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let num = { (a: [Any]?, i: Int) -> Double? in a.flatMap { i < $0.count ? ($0[i] as? NSNumber)?.doubleValue : nil } }
        let cur = d["current"] as? [String: Any] ?? [:]
        let daily = d["daily"] as? [String: Any] ?? [:]
        let times = daily["time"] as? [String] ?? []
        var days: [WeatherDay] = []
        for (i, t) in times.enumerated() {
            guard let date = dayF.date(from: t) else { continue }
            days.append(WeatherDay(date: date, code: num(daily["weather_code"] as? [Any], i).map(Int.init),
                                   tMax: num(daily["temperature_2m_max"] as? [Any], i), tMin: num(daily["temperature_2m_min"] as? [Any], i),
                                   rainChance: num(daily["precipitation_probability_max"] as? [Any], i), sunMJ: num(daily["shortwave_radiation_sum"] as? [Any], i)))
        }
        let hourly = d["hourly"] as? [String: Any] ?? [:]
        let hTimes = hourly["time"] as? [String] ?? []
        let rad = hourly["shortwave_radiation"] as? [Any]
        let hours = hTimes.prefix(48).enumerated().compactMap { i, s -> (t: Date, w: Double)? in
            hourF.date(from: s).map { (t: $0, w: num(rad, i) ?? 0) }
        }
        return Weather(now: WeatherNow(temp: (cur["temperature_2m"] as? NSNumber)?.doubleValue, code: (cur["weather_code"] as? NSNumber)?.intValue,
                                       cloud: (cur["cloud_cover"] as? NSNumber)?.doubleValue, wind: (cur["wind_speed_10m"] as? NSNumber)?.doubleValue),
                       days: days, hourly: hours)
    }

    /// A rough day's solar from the panels' size: sunlight on flat ground x panel kW x 0.8. Good enough to
    /// rank the week, not to plan by the kilowatt-hour.
    static func expectedKWh(_ day: WeatherDay, panelKW: Double?) -> Double? {
        guard let p = panelKW, p > 0, let sun = day.sunKWhPerM2 else { return nil }
        return sun * p * 0.8
    }

    static func describe(_ code: Int?) -> (String, String) {
        switch code ?? -1 {
        case 0: return ("Clear", "sun.max.fill")
        case 1, 2: return ("Partly cloudy", "cloud.sun.fill")
        case 3: return ("Overcast", "cloud.fill")
        case 45, 48: return ("Fog", "cloud.fog.fill")
        case 51...57: return ("Drizzle", "cloud.drizzle.fill")
        case 61...67, 80...82: return ("Rain", "cloud.rain.fill")
        case 71...77, 85, 86: return ("Snow", "cloud.snow.fill")
        case 95...99: return ("Storms", "cloud.bolt.rain.fill")
        default: return ("–", "questionmark")
        }
    }
}
