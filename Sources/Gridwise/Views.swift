import SwiftUI
import Charts

// MARK: - Look

enum Tint {
    static let buy = Color(red: 1.0, green: 0.55, blue: 0.25)
    static let sell = Color(red: 0.20, green: 0.80, blue: 0.62)
    static let solar = Color(red: 1.0, green: 0.80, blue: 0.20)
    static let battery = Color(red: 0.35, green: 0.70, blue: 1.0)
    static let house = Color(red: 0.72, green: 0.58, blue: 1.0)
    static let grid = Color(red: 0.62, green: 0.66, blue: 0.72)
    static let good = Color(red: 0.25, green: 0.78, blue: 0.45)
    static let bad = Color(red: 0.95, green: 0.35, blue: 0.30)
}

struct Tile<Content: View>: View {
    var title: String
    var info: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if let info { InfoButton(info) }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
    }
}

struct InfoButton: View {
    let text: String
    @State private var show = false
    init(_ t: String) { text = t }
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
            .onHover { show = $0 }.onTapGesture { show.toggle() }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                Text(text).font(.callout).frame(width: 320, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(12)
            }
            .accessibilityLabel("More about this").accessibilityHint(text)
    }
}

struct Note: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

struct Problem: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
}

enum Fmt {
    static func cents(_ c: Double?) -> String { c.map { String(format: "%.1f c", $0) } ?? "–" }
    static func money(_ a: Double?, _ d: Int = 2) -> String {
        guard let a else { return "–" }
        return (a < 0 ? "−$" : "$") + String(format: "%.\(d)f", abs(a))
    }
    static func kwh(_ k: Double?) -> String { k.map { String(format: k! >= 100 ? "%.0f kWh" : "%.1f kWh", $0) } ?? "–" }
    static func kw(_ w: Double?) -> String {
        guard let w else { return "–" }
        return abs(w) >= 1000 ? String(format: "%.1f kW", w / 1000) : String(format: "%.0f W", w)
    }
    static func time(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU"); f.timeZone = tz; f.dateFormat = "h:mm a"
        return f.string(from: d).lowercased()
    }
    static func day(_ d: Date, _ tz: TimeZone, _ fmt: String = "EEE d MMM") -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU"); f.timeZone = tz; f.dateFormat = fmt
        return f.string(from: d)
    }
    /// Amber's feed-in price in words: negative means Amber pays you.
    static func feedIn(_ perKwh: Double?) -> String {
        guard let p = perKwh else { return "–" }
        return p <= 0 ? String(format: "pays %.1f c", -p) : String(format: "costs %.1f c", p)
    }
}

// MARK: - Main window

struct MainView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var ss = SmartShiftControl.shared

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 980
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if !store.hasToken {
                        Tile(title: "Welcome") {
                            Text("Gridwise shows your Amber prices, your bill so far, the wholesale market and the weather, and can send SmartShift overrides. To start, add your Amber API token.")
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Open Setup…") { store.showSetup = true }.buttonStyle(.borderedProminent)
                        }
                    } else {
                        PricesNow()
                        Pair(wide: wide) { PriceChart() } right: { SmartShiftTile() }
                        Pair(wide: wide) { BillTile() } right: { WeatherTile() }
                        Pair(wide: wide) { WholesaleTile() } right: { InverterTile() }
                        Text("Gridwise is not made or endorsed by Amber Electric. Prices from Amber's API; wholesale data from AEMO; generation mix from Open Electricity (CC BY 4.0); weather from Open-Meteo (CC BY 4.0).")
                            .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .frame(width: max(0, geo.size.width), alignment: .leading)
            }
        }
        .frame(minWidth: 560, minHeight: 500)
        .sheet(isPresented: $store.showSetup) { SetupSheet().environmentObject(store) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gridwise").font(.system(size: 30, weight: .semibold, design: .rounded))
                if let s = store.site {
                    Note("\(s.network ?? "Amber site") · \(store.region.name)" + (store.sites.count > 1 ? " · \(store.sites.count) sites" : ""))
                }
                if let a = store.advice(flow: ss.status?.flow), a.action == .charge {
                    Label(a.title, systemImage: "bolt.badge.clock")
                        .font(.callout.weight(.semibold)).foregroundStyle(a.now ? Color.orange : Tint.battery)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(.thinMaterial, in: Capsule())
                        .help(a.detail)
                }
            }
            Spacer()
            HStack(spacing: 10) {
                Button { Task { await store.reloadAll() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r")
                Button { store.showSetup = true } label: { Label("Setup", systemImage: "gearshape") }
            }
        }
    }
}

struct Pair<L: View, R: View>: View {
    let wide: Bool
    @ViewBuilder var left: L
    @ViewBuilder var right: R
    var body: some View {
        if wide {
            HStack(alignment: .top, spacing: 14) {
                left.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                right.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }.fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 14) { left; right }
        }
    }
}

// MARK: - Prices

struct PricesNow: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let buy = store.now("general"), sell = store.now("feedIn"), tz = store.region.timeZone
        HStack(spacing: 14) {
            Tile(title: "Buy now") {
                Text(Fmt.cents(buy?.perKwh)).font(.system(size: 34, weight: .medium, design: .rounded)).foregroundStyle(Tint.buy)
                Note(([buy?.descriptor.map(Self.word), buy?.renewables.map { String(format: "%.0f%% renewable", min(100, $0)) },
                       buy?.spikeStatus == "spike" ? "price spike" : nil] as [String?]).compactMap { $0 }.joined(separator: " · "))
            }
            Tile(title: "Exporting now") {
                Text(sell.map { Fmt.feedIn($0.perKwh) } ?? (store.site?.hasFeedIn == false ? "no feed-in" : "–"))
                    .font(.system(size: 34, weight: .medium, design: .rounded))
                    .foregroundStyle((sell?.perKwh ?? 0) <= 0 ? Tint.sell : Tint.bad)
                Note((sell?.perKwh ?? 0) > 0 ? "Exports cost money right now. Use the power at home or store it." : "Amber's feed-in price, per kWh")
            }
            Tile(title: "Next 12 hours", info: "Amber's own forecast. Dearest and cheapest half hours ahead, buy price.") {
                let ahead = store.prices.filter { $0.channelType == "general" && $0.isForecast }.prefix(24)
                if let hi = ahead.max(by: { $0.perKwh < $1.perKwh }), let lo = ahead.min(by: { $0.perKwh < $1.perKwh }) {
                    Text("\(Fmt.cents(lo.perKwh)) – \(Fmt.cents(hi.perKwh))").font(.system(size: 26, weight: .medium, design: .rounded))
                    Note("Cheapest \(Fmt.time(lo.startTime, tz)), dearest \(Fmt.time(hi.startTime, tz))")
                } else { Note("Waiting for Amber's forecast…") }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        if let e = store.errors["prices"] { Problem(e) }
    }

    static func word(_ d: String) -> String {
        ["extremelyLow": "extremely low", "veryLow": "very low", "low": "low", "neutral": "average", "high": "high", "spike": "spike"][d] ?? d
    }
}

struct PriceChart: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Tile(title: "Amber prices", info: "The last 12 hours and Amber's forecast for the next 12, in cents per kWh including GST. Feed-in is shown as what Amber pays you: below zero means exporting costs money.") {
            let cut = Date().addingTimeInterval(-12 * 3600), end = Date().addingTimeInterval(12 * 3600)
            let rows = store.prices.filter { $0.startTime >= cut && $0.startTime <= end }
            // actual and forecast as separate lines (a line keeps one style), joined at the current half hour
            let lines: [(name: String, channel: String, forecast: Bool, sign: Double, colour: Color)] = [
                ("Buy", "general", false, 1, Tint.buy), ("Buy forecast", "general", true, 1, Tint.buy),
                ("Feed-in", "feedIn", false, -1, Tint.sell), ("Feed-in forecast", "feedIn", true, -1, Tint.sell)]
            Chart {
                ForEach(lines, id: \.name) { l in
                    ForEach(rows.filter { $0.channelType == l.channel && (l.forecast ? ($0.isForecast || $0.isCurrent) : !$0.isForecast) }) { r in
                        LineMark(x: .value("Time", r.startTime), y: .value("c/kWh", l.sign * r.perKwh), series: .value("Line", l.name))
                            .interpolationMethod(.stepEnd).foregroundStyle(l.colour.opacity(l.forecast ? 0.75 : 1))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: l.forecast ? [4, 3] : []))
                    }
                }
                RuleMark(x: .value("Now", Date())).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.4))
            }
            .chartLegend(.hidden)
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) c") } } } }
            .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 3)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
            .frame(height: 200)
            HStack(spacing: 14) {
                Label("Buy", systemImage: "circle.fill").foregroundStyle(Tint.buy)
                Label("Feed-in (what Amber pays)", systemImage: "circle.fill").foregroundStyle(Tint.sell)
                Text("Dashed: Amber's forecast").foregroundStyle(.secondary)
            }
            .font(.caption).labelStyle(.titleAndIcon).imageScale(.small)
        }
    }
}

// MARK: - Bill

struct BillTile: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Tile(title: "Billing month so far", info: "From your metered usage, which reaches Amber a day or so late, so the last day or two may be missing. Fixed charges are the daily supply charge and membership you entered in Setup.") {
            let tz = store.region.timeZone
            if let b = store.bill {
                Text(Fmt.money(b.netAUD)).font(.system(size: 30, weight: .medium, design: .rounded))
                    .foregroundStyle(b.netAUD <= 0 ? Tint.good : .primary)
                Note("Since \(Fmt.day(b.start, tz, "d MMM"))" + (b.lastMetered.map { " · metered to \(Fmt.day($0, tz, "d MMM"))" } ?? "") + " · fixed charges to today")
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    GridRow { Text("Bought"); Text(Fmt.kwh(b.importKWh)).foregroundStyle(.secondary); Text(Fmt.money(b.importAUD)) }
                    GridRow { Text("Sold"); Text(Fmt.kwh(b.exportKWh)).foregroundStyle(.secondary); Text(Fmt.money(-b.exportAUD)).foregroundStyle(Tint.good) }
                    GridRow { Text("Fixed charges"); Text(""); Text(Fmt.money(b.fixedAUD)) }
                }
                .font(.callout).monospacedDigit()
                if store.setup.supplyCentsPerDay == nil { Note("Add your daily supply charge in Setup to include it.") }
                Divider()
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow { Text("Day").gridColumnAlignment(.leading); Text("Bought"); Text("Sold"); Text("Net") }.font(.caption).foregroundStyle(.secondary)
                    ForEach(b.days.suffix(7).reversed()) { d in
                        GridRow {
                            Text(Fmt.day(d.date, tz)).gridColumnAlignment(.leading)
                            Text(Fmt.kwh(d.importKWh)); Text(Fmt.kwh(d.exportKWh))
                            Text(Fmt.money(d.importAUD - d.exportAUD)).foregroundStyle(d.importAUD - d.exportAUD <= 0 ? Tint.good : .primary)
                        }
                    }
                }
                .font(.caption).monospacedDigit()
            } else if store.errors["bill"] == nil {
                Note("Reading your usage from Amber…")
            }
            if let e = store.errors["bill"] { Problem(e) }
        }
    }
}

// MARK: - SmartShift

struct SmartShiftTile: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var amber = SmartShiftControl.shared
    @State private var showSignIn = false
    @State private var command = AmberCommand.charge
    @State private var minutes = 60
    @State private var askSend = false
    @State private var askCancel = false
    @State private var askSignOut = false

    var body: some View {
        Tile(title: "SmartShift", info: "For Amber SmartShift customers. Shows SmartShift's power flow and battery, and sends a manual override like the one in Amber's app: charge, discharge, preserve or self-consume, for up to 3 hours. Nothing is sent unless you press Send and confirm. It signs in the way Amber's app does, through an interface Amber does not publish, so it may stop working if Amber changes it. Your password is not kept; a renewal token is held in your Keychain.") {
            if amber.signedIn {
                signedIn
                HStack {
                    if amber.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Sign out") { askSignOut = true }.buttonStyle(.borderless).font(.caption)
                }
            } else {
                Note("Sign in with your Amber app login to see your battery and send overrides. Skip this if you don't have SmartShift.")
                Button("Sign in to SmartShift…") { showSignIn = true }
            }
            if let e = amber.error { Problem(e) }
        }
        .sheet(isPresented: $showSignIn) { AmberSignInSheet(amber: amber) }
        .confirmationDialog(sendTitle, isPresented: $askSend, titleVisibility: .visible) {
            Button("Send to Amber") { Task { await amber.send(command, minutes: minutes) } }
            Button("Don't send", role: .cancel) {}
        } message: { Text(sendMessage) }
        .confirmationDialog("Cancel the override and hand the battery back to SmartShift now?", isPresented: $askCancel, titleVisibility: .visible) {
            Button("Cancel the override") { Task { await amber.cancel() } }
            Button("Leave it", role: .cancel) {}
        }
        .confirmationDialog("Sign out of SmartShift on this Mac?", isPresented: $askSignOut, titleVisibility: .visible) {
            Button("Sign out") { Task { await amber.signOut() } }
            Button("Stay signed in", role: .cancel) {}
        } message: { Text("The saved sign-in is revoked and removed from the Keychain. An override already sent keeps running until its end time.") }
    }

    private var tz: TimeZone { store.region.timeZone }
    private var until: Date { Date().addingTimeInterval(Double(minutes) * 60) }
    private var sendTitle: String { "\(command.label) until \(Fmt.time(until, tz))?" }
    private var sendMessage: String {
        var s = "Amber will \(command.meaning) for \(minutes) minutes, then SmartShift takes over again."
        if let o = amber.status?.override { s += " This replaces the \(AmberCommand.label(for: o.value).lowercased()) override now in force." }
        if command == .charge { s += " Charging from the grid is paid for at the buy price." }
        return s
    }

    @ViewBuilder private var signedIn: some View {
        if let st = amber.status {
            if let f = st.flow { FlowGrid(flow: f) }
            if let o = st.override {
                HStack {
                    Label("Override: \(AmberCommand.label(for: o.value))" + (o.to.map { " until " + Fmt.time($0, tz) } ?? ""), systemImage: "hand.point.up.left.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                    Spacer()
                    Button("Cancel override") { askCancel = true }.disabled(amber.busy)
                }
            } else {
                Label("No override: SmartShift is deciding" + (st.flow?.action.map { " (\($0.lowercased()))" } ?? ""), systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if st.smartShiftOn == false { Problem("SmartShift is switched off in Amber's app, so overrides would be ignored.") }
            if let a = store.advice(flow: st.flow), a.action != .none, !a.detail.isEmpty {
                Text(a.action == .charge ? "\(a.title). \(a.detail)" : "\(a.title). \(a.detail)").font(.caption)
                    .foregroundStyle(a.action == .charge ? .primary : .secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Picker("Command", selection: $command) { ForEach(AmberCommand.allCases) { Text($0.label).tag($0) } }
                    .labelsHidden().frame(maxWidth: 150)
                Picker("For", selection: $minutes) {
                    Text("30 min").tag(30); Text("1 hour").tag(60); Text("2 hours").tag(120); Text("3 hours").tag(180)
                }
                .labelsHidden().frame(maxWidth: 110)
                Button("Send…") { askSend = true }.buttonStyle(.borderedProminent).disabled(amber.busy || st.smartShiftOn == false)
            }
            if let last = amber.log.last { Note("Last: \(last)").help(amber.log.joined(separator: "\n")) }
        } else if amber.error == nil {
            Note("Reading SmartShift from Amber…")
        }
    }
}

struct FlowGrid: View {
    let flow: SmartShiftFlow
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                cell("Solar", "sun.max.fill", Tint.solar, Fmt.kw(flow.solarW), nil)
                cell("House", "house.fill", Tint.house, Fmt.kw(flow.houseW), nil)
            }
            GridRow {
                cell("Battery", "battery.75percent", Tint.battery, flow.batteryPct.map { String(format: "%.0f%%", $0) } ?? "–",
                     abs(flow.batteryW) < 50 ? "idle" : flow.batteryW > 0 ? "discharging \(Fmt.kw(flow.batteryW))" : "charging \(Fmt.kw(-flow.batteryW))")
                cell("Grid", "bolt.horizontal.fill", Tint.grid, Fmt.kw(abs(flow.gridW)),
                     abs(flow.gridW) < 50 ? "balanced" : flow.gridW > 0 ? "importing" : "exporting")
            }
        }
    }
    private func cell(_ name: String, _ icon: String, _ c: Color, _ value: String, _ sub: String?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(c).frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(.title3, design: .rounded)).monospacedDigit()
                Text(sub.map { "\(name) · \($0)" } ?? name).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Weather

struct WeatherTile: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Tile(title: "Weather and solar outlook", info: "From Open-Meteo for the place you chose in Setup. Expected solar is a rough figure: the day's sunlight on flat ground times your panel size times 0.8.") {
            if let w = store.weather {
                let (word, icon) = WeatherService.describe(w.now.code)
                HStack(spacing: 10) {
                    Image(systemName: icon).symbolRenderingMode(.multicolor).font(.system(size: 28))
                    VStack(alignment: .leading) {
                        Text(w.now.temp.map { String(format: "%.0f°", $0) } ?? "–").font(.system(size: 28, design: .rounded))
                        Note([word, w.now.cloud.map { String(format: "cloud %.0f%%", $0) }, w.now.wind.map { String(format: "wind %.0f km/h", $0) }]
                            .compactMap { $0 }.joined(separator: " · ") + (store.setup.place.map { " · \($0)" } ?? ""))
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(w.days) { d in
                        GridRow {
                            Text(Fmt.day(d.date, store.region.timeZone, "EEE d")).frame(width: 56, alignment: .leading)
                            Image(systemName: WeatherService.describe(d.code).1).symbolRenderingMode(.multicolor)
                            Text("\(d.tMin.map { String(format: "%.0f°", $0) } ?? "–") – \(d.tMax.map { String(format: "%.0f°", $0) } ?? "–")").monospacedDigit()
                            Text(d.rainChance.map { String(format: "%.0f%% rain", $0) } ?? "").foregroundStyle(.secondary)
                            Text(WeatherService.expectedKWh(d, panelKW: store.setup.panelKW).map { "about " + Fmt.kwh($0) } ??
                                 d.sunKWhPerM2.map { String(format: "%.1f kWh/m² sun", $0) } ?? "").foregroundStyle(Tint.solar)
                        }
                    }
                }
                .font(.callout)
                if store.setup.panelKW == nil { Note("Add your panel size in Setup to see expected solar in kWh.") }
            } else if !store.setup.hasPlace {
                Note("Choose your suburb in Setup to see the weather and a solar outlook.")
            } else if store.errors["weather"] == nil { Note("Getting the forecast…") }
            if let e = store.errors["weather"] { Problem(e) }
        }
    }
}

// MARK: - Wholesale

struct WholesaleTile: View {
    @EnvironmentObject var store: Store
    var body: some View {
        Tile(title: "Wholesale market · \((store.wholesale?.region ?? store.region).name)", info: "AEMO's wholesale price for your region: the last 24 hours as half-hour averages, then AEMO's forecast (dashed). Cents per kWh before GST and network charges; Amber's prices follow it. The mix is what is generating right now, from Open Electricity.") {
            let tz = store.region.timeZone
            if let w = store.wholesale {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.cents(w.cents)).font(.system(size: 26, weight: .medium, design: .rounded))
                    Note("at \(Fmt.time(w.at, tz))" + (w.demandMW.map { String(format: " · demand %.0f MW", $0) } ?? ""))
                }
                Chart(w.series) { p in
                    LineMark(x: .value("Time", p.t), y: .value("c/kWh", p.cents), series: .value("Kind", p.forecast ? "Forecast" : "Actual"))
                        .interpolationMethod(.stepEnd).foregroundStyle(p.forecast ? Tint.grid : Tint.buy)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: p.forecast ? [4, 3] : []))
                    RuleMark(x: .value("Now", Date())).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) c") } } } }
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                .frame(height: 140)
            } else if let e = store.errors["wholesale"] { Problem(e) } else { Note("Reading AEMO's feed…") }
            if let m = store.mix {
                let total = max(1, m.mw.reduce(0) { $0 + $1.mw })
                GeometryReader { g in
                    HStack(spacing: 1) {
                        ForEach(m.mw, id: \.fuel) { f in
                            Rectangle().fill(Self.colour(f.fuel)).frame(width: max(1, g.size.width * f.mw / total))
                                .help("\(f.fuel): \(Int(f.mw)) MW")
                        }
                    }
                }
                .frame(height: 14).clipShape(RoundedRectangle(cornerRadius: 4))
                Note(m.mw.map { "\($0.fuel) \(Int(($0.mw / total * 100).rounded()))%" }.joined(separator: " · ")
                     + (m.renewableShare.map { String(format: " · %.0f%% renewable", $0 * 100) } ?? ""))
            }
        }
    }
    static func colour(_ fuel: String) -> Color {
        switch fuel {
        case "Coal": return Color(white: 0.35)
        case "Gas": return .orange
        case "Hydro": return .teal
        case "Wind": return .green
        case "Solar farms": return Tint.solar
        case "Rooftop solar": return Color(red: 1, green: 0.9, blue: 0.5)
        case "Batteries": return Tint.battery
        case "Imports": return .purple
        default: return .gray
        }
    }
}

// MARK: - Inverters and curtailment

struct InverterTile: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var amber = SmartShiftControl.shared
    @ObservedObject private var cur = Curtailer.shared
    @State private var setup: FoundDevice?
    @State private var askLive = false
    @State private var askStop = false

    var body: some View {
        Tile(title: "Curtailment", info: "While Amber charges you to export, Gridwise can hold your inverter's output down so the solar goes to the house and battery instead of the grid, then put the inverter's own limit back. It works with GoodWe inverters and with inverters that support SunSpec over Modbus (Fronius, SMA, SolarEdge and others). It starts in dry run, which shows what it would do without changing anything.") {
            if let on = amber.status?.amberCurtailmentOn {
                Label(on ? "Amber's own solar curtailment is on" : "Amber's own solar curtailment is off", systemImage: on ? "checkmark.circle.fill" : "circle")
                    .font(.callout).foregroundStyle(on ? Tint.good : .secondary)
            }
            if let c = cur.config { running(c) } else { finder }
            if let e = cur.lastError { Problem(e) }
        }
        .sheet(item: $setup) { d in CurtailSetupSheet(device: d).environmentObject(store) }
        .confirmationDialog("Let Gridwise change the inverter's limit for real?", isPresented: $askLive, titleVisibility: .visible) {
            Button("Go live") { cur.setLive(true) }
            Button("Stay in dry run", role: .cancel) {}
        } message: { Text("While exports cost money, Gridwise will lower \(cur.config?.model ?? "the inverter")'s power limit, never above its own limit, and put it back afterwards. Don't do this if another program or app already controls this inverter.") }
        .confirmationDialog("Stop curtailment and put the inverter's own limit back?", isPresented: $askStop, titleVisibility: .visible) {
            Button("Stop and put back") { Task { await cur.stop() } }
            Button("Keep going", role: .cancel) {}
        }
    }

    @ViewBuilder private func running(_ c: CurtailConfig) -> some View {
        HStack {
            Text("\(c.model) · \(c.host)").font(.callout.weight(.medium))
            Spacer()
            Text(c.live ? "LIVE" : "DRY RUN").font(.caption.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(c.live ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.2), in: Capsule())
        }
        Text(cur.status).font(.callout).fixedSize(horizontal: false, vertical: true)
        if let s = cur.state {
            Note("Inverter making \(Fmt.kw(s.outputW)) · limit now \(s.limitPct.map { "\(Int($0))%" } ?? "none") · its own limit \(c.originalPct.map { "\(Int($0))%" } ?? "none")")
        }
        Stepper("Without battery meter readings, hold at \(c.fixedPct)%", value: Binding(get: { c.fixedPct }, set: { cur.setFixed($0) }), in: Curtailer.minPct...100, step: 5)
            .font(.callout)
        HStack {
            if c.live { Button("Back to dry run") { cur.setLive(false) } } else { Button("Go live…") { askLive = true }.buttonStyle(.borderedProminent) }
            Button("Stop…", role: .destructive) { askStop = true }
        }
        if !cur.log.isEmpty { Note("Last: \(cur.log.last!)").help(cur.log.joined(separator: "\n")) }
    }

    @ViewBuilder private var finder: some View {
        if let r = store.scan {
            if let n = r.note { Problem(n) }
            if r.devices.isEmpty && r.note == nil { Note("Nothing answered. Inverters on Wi-Fi only may talk only to their maker's cloud.") }
            ForEach(r.devices) { d in
                HStack {
                    Text(d.kind).font(.callout.weight(.medium))
                    Text(d.ip).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Set up…") { setup = d }
                }
                Note(d.detail)
            }
        }
        HStack {
            Button(store.scan == nil ? "Look for inverters" : "Look again") { Task { await store.runScan() } }.disabled(store.scanning)
            if store.scanning { ProgressView().controlSize(.small); Note("About 10 seconds…") }
        }
        Note("For a solar-only inverter Amber can't curtail, next to a separate AC-coupled battery. Hybrid inverters are refused. The scan only asks devices who they are; macOS may ask to let Gridwise find devices on your local network.")
        if let b = store.battery {
            Note("Battery meter (AlphaESS): grid \(b.gridW > 0 ? "importing" : "exporting") \(Fmt.kw(abs(b.gridW))), battery \(b.socPct.map { String(format: "%.0f%%", $0) } ?? "–"), \(Fmt.time(b.at, store.region.timeZone))")
        }
        if let e = store.errors["battery"] { Problem(e) }
    }
}

struct CurtailSetupSheet: View {
    let device: FoundDevice
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var found: (Inverter, InverterState)?
    @State private var error: String?
    @State private var rated: Double?
    @State private var fixed = 30
    @State private var agreed = false

    private var kind: String { device.kind == "GoodWe" ? "GoodWe" : "SunSpec" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up curtailment").font(.title3.weight(.semibold))
            if let (d, s) = found {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { Text("Inverter"); Text("\(d.model) at \(d.host)") }
                    GridRow { Text("Making now"); Text(Fmt.kw(s.outputW)) }
                    GridRow { Text("Its own limit"); Text(s.limitPct.map { "\(Int($0))%" } ?? "none") }
                    GridRow { Text("Rated power"); Text(d.ratedW > 0 ? Fmt.kw(d.ratedW) : "unknown") }
                }
                .font(.callout)
                if d.ratedW <= 0 {
                    LabeledContent("Rated power") {
                        TextField("", value: $rated, format: .number, prompt: Text("kW")).frame(width: 80).textFieldStyle(.roundedBorder)
                    }
                }
                Label(d.tested ? "This model's power limit has been tested with Gridwise." :
                      "Trial: this model's power limit hasn't been tested with Gridwise yet. Every change is read back, and Gridwise stops and puts the limit back if the inverter doesn't keep it.",
                      systemImage: d.tested ? "checkmark.seal" : "flask")
                    .font(.callout).foregroundStyle(d.tested ? Tint.good : .orange).fixedSize(horizontal: false, vertical: true)
                if let a = amberCurtails(d.model) {
                    Label(a, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if d.revertsByItself {
                    Note("This inverter undoes the limit by itself if Gridwise stops talking to it for 10 minutes.")
                } else {
                    Note("This inverter keeps whatever limit it was last given. Gridwise puts yours back when exports pay again, when you stop it, when it quits and when the Mac sleeps. If the Mac loses power, it puts it back the next time Gridwise opens.")
                }
                Stepper("Without battery meter readings, hold at \(fixed)%", value: $fixed, in: Curtailer.minPct...100, step: 5).font(.callout)
                Note("With SmartShift signed in or an AlphaESS key in Setup, Gridwise follows your battery's meter instead: just enough output for the house and battery.")
                Toggle(isOn: $agreed) {
                    Text("I understand Gridwise will change this inverter's power limit once I switch it from dry run to live, and that no other program or app should be controlling it at the same time.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            } else if let error {
                Problem(error)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Reading the inverter…") }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start in dry run") { begin() }.keyboardShortcut(.defaultAction)
                    .disabled(found == nil || !agreed || ((found?.0.ratedW ?? 0) <= 0 && (rated ?? 0) <= 0))
            }
        }
        .padding(20).frame(width: 480)
        .task {
            do { found = try await Curtailer.identify(kind: kind, host: device.ip) }
            catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private func begin() {
        guard let (d, s) = found else { return }
        let c = CurtailConfig(host: d.host, kind: d.kind, model: d.model, ratedW: d.ratedW > 0 ? d.ratedW : (rated ?? 0) * 1000,
                              live: false, fixedPct: fixed, originalPct: s.limitPct)
        Curtailer.shared.start(c, device: d)
        dismiss()
    }
}
