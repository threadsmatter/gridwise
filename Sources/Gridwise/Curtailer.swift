import Foundation
import AppKit

// Curtailment: while Amber charges you to export (feed-in price above zero), hold the inverter's output down
// so the house, the battery and as little export as possible use the solar. Afterwards, put the inverter's
// own limit back exactly as it was.
//
// How much to hold back comes from the battery system's meter, through SmartShift's site power: it measures
// the grid connection whether or not Amber has onboarded the solar inverter. Without SmartShift, a fixed
// limit the user chooses is used instead.
//
// Safety rules:
//   - off until the user sets it up, and in "dry run" (decides and logs, writes nothing) until they say live
//   - never raises the limit above what the inverter had before Gridwise touched it
//   - every write is read back; if the inverter does not keep it, or someone changes the limit elsewhere,
//     Gridwise stops, keeps the new value as the user's own, and says so
//   - the original limit goes back when prices return to normal, when curtailment is stopped, when the app
//     quits, when the Mac goes to sleep, and (if the app was killed) the next time Gridwise starts
//   - SunSpec inverters also undo the limit by themselves if it is not renewed for 10 minutes
//   - stands aside while Amber's own solar curtailment is switched on, so two controllers never fight

struct CurtailConfig: Codable, Equatable {
    var host: String
    var kind: String                  // GoodWe or SunSpec
    var model: String
    var ratedW: Double
    var live = false                  // false: dry run
    var fixedPct = 30                 // used when there is no SmartShift reading
    var originalPct: Double?          // the inverter's own limit before Gridwise (nil: no limit, SunSpec)
    var writtenPct: Int?              // what Gridwise last wrote and has not yet put back
    var writtenAt: Date?

    static let key = "curtailment"
    static func load() -> CurtailConfig? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(CurtailConfig.self, from: $0) }
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key) }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

@MainActor
final class Curtailer: ObservableObject {
    static let shared = Curtailer()

    @Published private(set) var config = CurtailConfig.load()
    @Published private(set) var state: InverterState?
    @Published private(set) var status = "Off"
    @Published private(set) var curtailing = false
    @Published private(set) var lastError: String?
    @Published private(set) var log: [String] = Curtailer.readLog()

    private var device: Inverter?
    private var loop: Task<Void, Never>?
    weak var store: Store?

    /// What the decisions are based on. From the Store in the app; a test can supply its own.
    struct Inputs { var feedIn: Double?; var amberCurtailing: Bool; var flow: SmartShiftFlow?; var flowAt: Date?; var battery: BatteryReading? = nil }
    var inputs: (() -> Inputs?)?
    private func currentInputs() -> Inputs? {
        if let inputs { return inputs() }
        guard let store else { return nil }
        let st = store.smartShift.status
        return Inputs(feedIn: store.now("feedIn")?.perKwh, amberCurtailing: st?.amberCurtailmentOn == true, flow: st?.flow, flowAt: st?.at, battery: store.battery)
    }
    var tickSeconds: Double = 30
    static let minPct = 3
    static let marginW = 200.0            // aim for a little import rather than a little export
    static let renewEvery: TimeInterval = 240

    var active: Bool { config != nil }

    static var testPort: UInt16?            // tests only: talk to a simulated inverter on another port
    static func make(kind: String, host: String) -> Inverter {
        kind == "GoodWe" ? GoodWeInverter(host: host, port: testPort ?? 8899) : SunSpecInverter(host: host, port: testPort ?? 502)
    }

    /// `forPutBack`: skip the model checks, so a limit Gridwise set can always be put back.
    static func identify(kind: String, host: String, forPutBack: Bool = false) async throws -> (Inverter, InverterState) {
        let d = make(kind: kind, host: host)
        if let g = d as? GoodWeInverter { try await g.identify(anyModel: forPutBack) }
        if let s = d as? SunSpecInverter { try await s.identify(anyModel: forPutBack) }
        return (d, try await d.read())
    }

    // MARK: start and stop

    /// After a crash or forced quit the inverter may still hold Gridwise's limit: put the original back first.
    func resume() {
        guard let c = config else { return }
        loop?.cancel()
        loop = Task {
            if c.writtenPct != nil {
                do {
                    let (d, s) = try await Self.identify(kind: c.kind, host: c.host, forPutBack: true)
                    device = d
                    await putBack(reason: "Gridwise was not shut down properly last time", current: s)
                } catch { note("could not reach the inverter to put its limit back: \(error.localizedDescription)") }
            }
            await run()
        }
    }

    func start(_ c: CurtailConfig, device d: Inverter) {
        var c = c
        c.writtenPct = nil
        config = c; c.save()
        device = d
        note("set up: \(c.kind) \(c.model) at \(c.host), \(c.live ? "live" : "dry run"), own limit \(c.originalPct.map { "\(Int($0))%" } ?? "none")")
        loop?.cancel()
        loop = Task { await run() }
    }

    func setLive(_ on: Bool) {
        guard var c = config else { return }
        c.live = on; config = c; c.save()
        note(on ? "switched to live" : "switched to dry run")
        if !on { Task { await putBack(reason: "dry run") } }
    }

    func setFixed(_ pct: Int) {
        guard var c = config else { return }
        c.fixedPct = max(Self.minPct, min(100, pct)); config = c; c.save()
    }

    /// Stops curtailment for good and puts the inverter back as it was.
    func stop() async {
        loop?.cancel(); loop = nil
        await putBack(reason: "curtailment switched off")
        note("switched off")
        CurtailConfig.clear(); config = nil; device = nil; state = nil; curtailing = false; status = "Off"
    }

    /// For quit and sleep: put the limit back now, waiting at most a few seconds.
    func putBackNow() async {
        guard config?.writtenPct != nil else { return }
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await self.putBack(reason: "Gridwise quitting or the Mac sleeping") }
            g.addTask { try? await Task.sleep(for: .seconds(5)) }
            await g.next(); g.cancelAll()
        }
    }

    // MARK: the loop

    private func run() async {
        while !Task.isCancelled, config != nil {
            await tick()
            try? await Task.sleep(for: .seconds(tickSeconds))
        }
    }

    func tick() async {
        guard var c = config else { return }
        do {
            if device == nil { device = try await Self.identify(kind: c.kind, host: c.host).0 }
            guard let d = device else { return }
            let s = try await d.read()
            state = s; lastError = nil

            // someone changed the limit elsewhere (SolarGo, the inverter's own web page): stand back for good
            if let w = c.writtenPct, let now = s.limitPct, abs(now - Double(w)) >= 1 {
                note("the limit was changed elsewhere to \(Int(now))% while Gridwise held it at \(w)%; stopping and keeping \(Int(now))% as yours")
                c.writtenPct = nil; c.originalPct = now; c.live = false
                config = c; c.save(); curtailing = false
                status = "Stopped: the limit was changed outside Gridwise. Switched to dry run."
                return
            }
            if c.writtenPct == nil, let own = s.limitPct, own != c.originalPct, c.kind == "GoodWe" {
                c.originalPct = own; config = c; c.save()          // the user changed their own limit meanwhile
            }

            guard let input = currentInputs() else { return }
            let amberCurtailing = input.amberCurtailing
            let feedIn = input.feedIn
            let costs = (feedIn ?? 0) > 0
            if amberCurtailing || !costs || feedIn == nil {
                curtailing = false
                if c.writtenPct != nil { await putBack(reason: amberCurtailing ? "Amber's own curtailment is on" : "exports pay again") }
                status = amberCurtailing ? "Standing aside: Amber's own solar curtailment is switched on."
                       : feedIn == nil ? "Waiting for Amber's prices." : "Amber \(Fmt.feedIn(feedIn)) for exports: no limit needed."
                return
            }

            // exporting costs money: work out the limit
            let ceiling = Int((c.originalPct ?? 100).rounded(.down))
            let (pct, why) = target(c, s, input, ceiling: ceiling)
            curtailing = true
            let changed = c.writtenPct.map { abs($0 - pct) >= 2 } ?? (pct < ceiling)
            let renew = d.revertsByItself && c.writtenPct != nil && Date().timeIntervalSince(c.writtenAt ?? .distantPast) > Self.renewEvery
            guard changed || renew else {
                status = "Exports cost \(Fmt.cents(feedIn)): holding \(c.writtenPct.map { "\($0)%" } ?? "the inverter's own limit"). \(why)"
                return
            }
            if !c.live {
                status = "Dry run: would set \(pct)%. \(why)"
                if changed { note("dry run: would set \(pct)% (\(why))") }
                return
            }
            try await d.setLimit(pct)
            if changed { note("set \(pct)% (\(why))") }
            c.writtenPct = pct; c.writtenAt = Date(); config = c; c.save()
            status = "Exports cost \(Fmt.cents(feedIn)): limit \(pct)%. \(why)"
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if case InverterError.mismatch = error {
                c.live = false; config = c; c.save()
                note("stopped: \(lastError!)")
                await putBack(reason: "the inverter did not keep the setting")
            }
            device = nil                                   // reconnect next time
            status = "Can't reach the inverter right now."
        }
    }

    /// The limit to hold, and why. Follows SmartShift's grid reading when it is fresh; otherwise the fixed limit.
    private func target(_ c: CurtailConfig, _ s: InverterState, _ input: Inputs, ceiling: Int) -> (Int, String) {
        let clamp = { (p: Int) in max(Self.minPct, min(ceiling, p)) }
        guard c.ratedW > 0 else { return (clamp(c.fixedPct), "Fixed limit (rated power unknown).") }
        // the grid reading from the battery's meter: the battery maker's cloud if fresh, else SmartShift's
        var grid: (w: Double, from: String)?
        if let b = input.battery, Date().timeIntervalSince(b.at) < 90 { grid = (b.gridW, "Battery meter (AlphaESS)") }
        else if let f = input.flow, let at = input.flowAt, Date().timeIntervalSince(at) < 180 { grid = (f.gridW, "Battery meter (SmartShift)") }
        if let g = grid, let out = s.outputW {
            // grid > 0 is import. Lower the output by what is being exported, raise it by what is being imported.
            let capW = max(0, out + g.w + Self.marginW)
            let pct = Int((capW / c.ratedW * 100).rounded(.up))
            let what = g.w < -50 ? "exporting \(Fmt.kw(-g.w))" : g.w > 50 ? "importing \(Fmt.kw(g.w))" : "grid balanced"
            return (clamp(pct), "\(g.from): \(what), inverter making \(Fmt.kw(out)).")
        }
        return (clamp(c.fixedPct), "Fixed limit (no fresh battery meter reading).")
    }

    private func putBack(reason: String, current: InverterState? = nil) async {
        guard var c = config, let w = c.writtenPct else { return }
        do {
            if device == nil { device = try await Self.identify(kind: c.kind, host: c.host, forPutBack: true).0 }
            guard let d = device else { return }
            let now = try await (current != nil ? current! : d.read())
            if let l = now.limitPct, abs(l - Double(w)) >= 1 {
                note("not putting back: the limit is \(Int(l))%, changed since Gridwise set \(w)%")
            } else {
                try await d.restore(to: InverterState(outputW: nil, limitPct: c.originalPct))
                note("put back the inverter's own limit (\(c.originalPct.map { "\(Int($0))%" } ?? "none")): \(reason)")
            }
            c.writtenPct = nil; c.writtenAt = nil; config = c; c.save()
        } catch {
            lastError = "Could not put the limit back: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            note(lastError!)
        }
    }

    // MARK: log (no account details; the inverter's local address and model only)

    private static var logFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Gridwise", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("curtailment.log")
    }
    private static func readLog() -> [String] {
        ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").split(separator: "\n").suffix(12).map(String.init)
    }
    private func note(_ what: String) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date())) \(what)"
        let all = ((try? String(contentsOf: Self.logFile, encoding: .utf8)) ?? "").split(separator: "\n").suffix(999).map(String.init) + [line]
        try? (all.joined(separator: "\n") + "\n").write(to: Self.logFile, atomically: true, encoding: .utf8)
        log = Array(all.suffix(12))
    }
}

/// Puts the inverter's limit back before quitting and before the Mac sleeps.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await Curtailer.shared.putBackNow() }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MainActor.assumeIsolated({ Curtailer.shared.config?.writtenPct }) != nil else { return .terminateNow }
        Task { @MainActor in
            await Curtailer.shared.putBackNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }   // keep curtailing from the menu bar
}
