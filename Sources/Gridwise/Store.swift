import Foundation
import SwiftUI

/// The billing month so far, from Amber's metered usage (which runs a day or so behind).
struct BillSoFar {
    struct Day: Identifiable { let date: Date; let importKWh, exportKWh, importAUD, exportAUD: Double; var id: Date { date } }
    let start: Date
    let days: [Day]
    let fixedAUD: Double            // supply charge and membership for the days so far
    var importAUD: Double { days.reduce(0) { $0 + $1.importAUD } }
    var exportAUD: Double { days.reduce(0) { $0 + $1.exportAUD } }
    var importKWh: Double { days.reduce(0) { $0 + $1.importKWh } }
    var exportKWh: Double { days.reduce(0) { $0 + $1.exportKWh } }
    var netAUD: Double { importAUD - exportAUD + fixedAUD }
    var lastMetered: Date? { days.last?.date }
}

@MainActor
final class Store: ObservableObject {
    @Published var setup = Setup.load() { didSet { if setup != oldValue { setup.save() } } }
    @Published var hasToken = Keychain.load(Keychain.amberToken) != nil
    @Published var sites: [AmberSite] = []
    @Published var prices: [PriceInterval] = []
    @Published var bill: BillSoFar?
    @Published var wholesale: Wholesale?
    @Published var mix: FuelMix?
    @Published var weather: Weather?
    @Published var errors: [String: String] = [:]          // per source, shown on its tile
    @Published var updated: [String: Date] = [:]
    @Published var scan: (devices: [FoundDevice], note: String?)?
    @Published var scanning = false
    @Published var showSetup = false
    @Published var battery: BatteryReading?               // from the battery maker's cloud (AlphaESS), when set up

    let smartShift = SmartShiftControl.shared
    private var tasks: [Task<Void, Never>] = []

    var site: AmberSite? { sites.first { $0.id == setup.siteId } ?? sites.first }
    var region: Region { setup.region.flatMap(Region.init(rawValue:)) ?? Region.from(network: site?.network) ?? .NSW1 }
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = region.timeZone; return c }
    private var api: AmberAPI? { Keychain.load(Keychain.amberToken).map { AmberAPI(token: $0) } }

    init() {
        if !hasToken { showSetup = true }
        start()
    }

    func start() {
        tasks.forEach { $0.cancel() }
        tasks = [
            loop(60) { await self.loadPrices() },
            loop(3600) { await self.loadBill() },
            loop(300) { await self.loadGrid() },
            loop(1800) { await self.loadWeather() },
            loop(60) { await self.smartShift.refresh() },
            loop(30) { await self.loadBattery() },          // AlphaESS asks for 10 s or more between calls
        ]
    }

    private func loop(_ seconds: Double, _ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                await body()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func reloadAll() async {
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await self.loadPrices() }
            g.addTask { await self.loadBill() }
            g.addTask { await self.loadGrid() }
            g.addTask { await self.loadWeather() }
            g.addTask { await self.smartShift.refresh() }
        }
    }

    private func record(_ key: String, _ error: Error?) {
        if let error { errors[key] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        else { errors[key] = nil; updated[key] = Date() }
    }

    // MARK: Amber

    /// Checks a token by listing its sites; saves it only if Amber accepts it.
    func useToken(_ token: String) async -> String? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Paste your API token first." }
        do {
            let s = try await AmberAPI(token: t).sites()
            guard !s.isEmpty else { return "Amber accepted the token, but there are no sites on the account." }
            guard Keychain.save(t, as: Keychain.amberToken) else { return "The Keychain would not store the token." }
            sites = s
            if setup.siteId == nil || !s.contains(where: { $0.id == setup.siteId }) {
                setup.siteId = (s.first { $0.status == "active" } ?? s[0]).id
            }
            hasToken = true
            await reloadAll()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func forgetToken() {
        Keychain.delete(Keychain.amberToken)
        hasToken = false; sites = []; prices = []; bill = nil
    }

    func loadPrices() async {
        guard let api else { return }
        do {
            if sites.isEmpty { sites = try await api.sites() }
            guard let s = site else { return }
            prices = try await api.prices(site: s.id)
            record("prices", nil)
        } catch { record("prices", error) }
    }

    func loadBill() async {
        guard let api else { return }
        if sites.isEmpty, let fetched = try? await api.sites() { sites = fetched }
        guard let s = site else { return }
        let cal = calendar, now = Date()
        // the start of this billing month: the most recent bill day, clamped to short months
        var comps = cal.dateComponents([.year, .month], from: now)
        func billDate(_ c: DateComponents) -> Date {
            let first = cal.date(from: c)!
            let len = cal.range(of: .day, in: .month, for: first)!.count
            return cal.date(byAdding: .day, value: min(setup.billDay, len) - 1, to: first)!
        }
        var start = billDate(comps)
        if start > now { comps.month! -= 1; start = billDate(comps) }
        do {
            let rows = try await api.usage(site: s.id, from: start, to: now, calendar: cal)
            let dayF = DateFormatter(); dayF.calendar = cal; dayF.timeZone = cal.timeZone
            dayF.locale = Locale(identifier: "en_AU_POSIX"); dayF.dateFormat = "yyyy-MM-dd"
            var byDay: [Date: (Double, Double, Double, Double)] = [:]
            for r in rows {
                let d = r.date.flatMap { dayF.date(from: $0) } ?? cal.startOfDay(for: r.startTime)
                var v = byDay[d] ?? (0, 0, 0, 0)
                if r.channelType == "feedIn" { v.1 += r.kwh; v.3 += -r.cost / 100 } else { v.0 += r.kwh; v.2 += r.cost / 100 }
                byDay[d] = v
            }
            // a day with nothing metered yet (Amber's meter data runs a day or so behind) is left out
            let days = byDay.sorted { $0.key < $1.key }
                .filter { $0.value.0 + $0.value.1 > 0.001 || abs($0.value.2) + abs($0.value.3) > 0.001 }
                .map { BillSoFar.Day(date: $0.key, importKWh: $0.value.0, exportKWh: $0.value.1, importAUD: $0.value.2, exportAUD: $0.value.3) }
            // fixed charges run every day of the billing month, metered or not
            let n = Double((cal.dateComponents([.day], from: start, to: cal.startOfDay(for: now)).day ?? 0) + 1)
            let fixed = n * ((setup.supplyCentsPerDay ?? 0) / 100 + setup.membershipPerMonth * 12 / 365)
            bill = BillSoFar(start: start, days: days, fixedAUD: fixed)
            record("bill", nil)
        } catch { record("bill", error) }
    }

    // MARK: grid and weather

    /// The site list, once: the region (and so the wholesale feed) depends on it.
    private func ensureSites() async {
        guard sites.isEmpty, let api else { return }
        if let s = try? await api.sites() { sites = s }
    }

    func loadGrid() async {
        await ensureSites()
        guard hasToken ? !sites.isEmpty || setup.region != nil : true else { return }   // never guess the region
        let region = self.region
        do { wholesale = try await GridData.wholesale(region); record("wholesale", nil) }
        catch { wholesale = nil; record("wholesale", error) }
        do { mix = try await GridData.mix(region); record("mix", nil) } catch { record("mix", error) }
    }

    func loadWeather() async {
        await ensureSites()
        guard let la = setup.latitude, let lo = setup.longitude else { return }
        do { weather = try await WeatherService.forecast(latitude: la, longitude: lo, timeZone: region.timeZone); record("weather", nil) }
        catch { record("weather", error) }     // keeps the last forecast
    }

    func loadBattery() async {
        guard let a = AlphaESS.saved(), let sn = setup.alphaSn else { battery = nil; return }
        do { battery = try await a.lastPower(sn: sn); record("battery", nil) } catch { record("battery", error) }
    }

    func runScan() async {
        scanning = true
        scan = await InverterScan.run()
        scanning = false
    }

    // MARK: derived

    func now(_ channel: String) -> PriceInterval? { prices.first { $0.channelType == channel && $0.isCurrent } }

    func advice(flow: SmartShiftFlow?) -> Advice? {
        guard let flow, !prices.isEmpty else { return nil }
        let rate = max(2.5, min(10, (flow.batteryMaxKWh ?? 10) / 3))      // a typical home battery charges in about three hours
        return AdviceEngine.advise(prices: prices, flow: flow, rateKW: rate, solarLeftKWh: { until in
            AdviceEngine.solarLeft(weather: self.weather, panelKW: self.setup.panelKW, until: until, calendar: self.calendar)
        }, timeZone: region.timeZone)
    }
}
