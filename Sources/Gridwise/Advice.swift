import Foundation

// "Is it worth charging the battery from the grid now, to sell or use in a dearer evening?" A suggestion
// only: nothing is sent to the battery unless the user sends an override themselves.
//
// From Amber's own forecast for the next 12 hours:
//   evening    the dearest half hours ahead, as many as a full battery can discharge into
//   charging   the cheapest half hours before the evening starts, as many as the shortfall needs
//   shortfall  what the battery still needs to be full, less the solar expected to reach it first
// Worth saying when a kWh bought now is worth at least `marginCents` more in the evening after the round
// trip's losses. Forecast evening spikes often fall short, so the gain is quoted as "up to".

struct Advice: Equatable {
    enum Action { case charge, hold, none }
    let action: Action
    let title: String
    let detail: String
    let now: Bool              // the cheap time is now (or there is no time to spare)
    let gainAUD: Double?
}

enum AdviceEngine {
    static let reserve = 0.05            // SmartShift keeps this much back
    static let roundTrip = 0.90          // what comes back out of each kWh put in
    static let marginCents = 15.0
    static let highCents = 60.0          // an evening worth hedging for: feed-in (or buy) at or above this
    static let minKWh = 2.0
    static let houseKW = 0.4             // what the house takes from the solar before the battery sees any

    private static func clock(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU"); f.timeZone = tz; f.dateFormat = "h:mm a"
        return f.string(from: d).replacingOccurrences(of: ":00", with: "").lowercased()
    }

    /// prices: Amber's intervals (both channels); battery: SmartShift's view. rateKW: the battery's charge rate.
    static func advise(prices: [PriceInterval], flow: SmartShiftFlow, rateKW: Double, solarLeftKWh: (Date) -> Double?,
                       timeZone: TimeZone, at: Date = Date()) -> Advice? {
        guard let pct = flow.batteryPct, let size = flow.batteryMaxKWh, size > 0 else { return nil }
        // pair up each half hour's buy and sell price; sell is what Amber pays (Amber's feed-in sign flipped)
        var sell: [Date: Double] = [:]
        for p in prices where p.channelType == "feedIn" { sell[p.startTime] = -p.perKwh }
        let ahead = prices.filter { $0.channelType == "general" && ($0.isCurrent || $0.isForecast) && $0.endTime > at }
            .sorted { $0.startTime < $1.startTime }
            .map { (t: $0.startTime, buy: $0.perKwh, sell: max(0, sell[$0.startTime] ?? 0)) }
            .prefix(24)
        guard ahead.count >= 6 else { return nil }
        let need = max(0, (1 - pct / 100) * size)
        let usable = (1 - reserve) * size
        let k = Int((usable / (rateKW / 2)).rounded(.up))
        let peak = ahead.sorted { $0.sell > $1.sell }.prefix(k)
            .filter { $0.sell >= highCents || $0.buy >= highCents * 1.5 }
            .sorted { $0.t < $1.t }
        guard let first = peak.first, let top = peak.max(by: { $0.sell < $1.sell }) else {
            return Advice(action: .none, title: "", detail: "No dear evening in Amber's forecast.", now: false, gainAUD: nil)
        }
        let starts = first.t
        let sellAvg = peak.map(\.sell).reduce(0, +) / Double(peak.count)
        let before = ahead.filter { $0.t < starts }
        guard !before.isEmpty else {
            return Advice(action: .none, title: "", detail: "The dear prices have already started.", now: false, gainAUD: nil)
        }
        let hours = max(0, starts.timeIntervalSince(at) / 3600)
        let solar = solarLeftKWh(starts)
        let toBattery = max(0, (solar ?? 0) - houseKW * hours) * 0.95
        let shortfall = max(0, min(need, rateKW * hours) - toBattery)
        let n = Int((shortfall / (rateKW / 2)).rounded(.up))
        let cheap = before.sorted { $0.buy < $1.buy }.prefix(max(n, 1))
        let buy = cheap.map(\.buy).reduce(0, +) / Double(cheap.count)
        let gainC = sellAvg * roundTrip - buy
        let tight = need > rateKW * (hours - 0.5) || n >= before.count - 1
        let cheapNow = cheap.contains { $0.t == ahead.first!.t } || tight
        let gain = shortfall * gainC / 100
        let evening = String(format: "Amber forecasts feed-in up to %.0f c around %@", top.sell, clock(top.t, timeZone))
        if shortfall < minKWh || gainC < marginCents {
            let why: String
            if need < minKWh { why = "the battery is nearly full" }
            else if shortfall < minKWh { why = String(format: "the solar still to come (about %.0f kWh) should fill it", solar ?? 0) }
            else { why = String(format: "buying now at %.0f c leaves too little after losses", buy) }
            return Advice(action: .hold, title: "No need to charge from the grid", detail: "\(evening); \(why).", now: false, gainAUD: nil)
        }
        let charging = flow.gridW > 1000 && flow.batteryW < -1000
        let when = cheapNow ? "now" : "from " + clock(cheap.min(by: { $0.t < $1.t })!.t, timeZone)
        let title = charging ? "SmartShift is charging for tonight" : "Worth charging from the grid \(when)"
        let solarBit = solar != nil ? String(format: "solar should add about %.0f kWh", toBattery)
                                    : "with no panel size in Setup, this counts no solar"
        var detail = String(format: "%@, against about %.0f c to buy before %@. The battery is at %.0f%% and needs %.0f kWh; %@, leaving %.0f kWh to buy. Worth up to $%.0f if the forecast holds",
                            evening, buy, clock(starts, timeZone), pct, need, solarBit, shortfall, gain)
        detail += tight && !charging ? ", and there is no time to spare." : "."
        detail += " A suggestion only: SmartShift decides unless you send an override. Forecast evening spikes often come in lower."
        return Advice(action: .charge, title: title, detail: detail, now: cheapNow, gainAUD: gain)
    }

    /// Solar expected between now and `until`, from the hourly sunlight forecast and the day's expected total.
    static func solarLeft(weather: Weather?, panelKW: Double?, until: Date, at: Date = Date(), calendar: Calendar) -> Double? {
        guard let w = weather, let today = w.days.first, let expected = WeatherService.expectedKWh(today, panelKW: panelKW) else { return nil }
        let todays = w.hourly.filter { calendar.isDate($0.t, inSameDayAs: at) }
        let total = todays.map(\.w).reduce(0, +)
        guard total > 0 else { return nil }
        let left = todays.filter { $0.t > at && $0.t <= until }.map(\.w).reduce(0, +)
        return expected * left / total
    }
}
