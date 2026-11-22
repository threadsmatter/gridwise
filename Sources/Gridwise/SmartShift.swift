import Foundation
import Security
import SwiftUI

// SmartShift, through the same private interface Amber's phone app uses (Amber does not publish it, so it
// may change). Sign-in is Amazon Cognito SRP (AmberSRP.swift): the password is used once, in memory, and
// never stored or sent. Only the renewal token is kept, in the Keychain.
//
// What Gridwise does with it: shows SmartShift's power flow, battery level and any override, and sends a
// manual override (charge, discharge, preserve, self-consume, at most 3 hours) when the user presses Send
// and confirms. SmartShift's on/off switch and Amber's own solar curtailment switch are only read.

enum AmberError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

struct AmberOverride: Equatable {
    let id: String
    let value: String            // charge, discharge, preserve-charge, self-consume
    let from: Date?
    let to: Date?
    let state: String?
}

struct AmberStatus: Equatable {
    var smartShiftOn: Bool?
    var amberCurtailmentOn: Bool?
    var override: AmberOverride?
    var flow: SmartShiftFlow?
    var at = Date()
}

/// SmartShift's live view of the house. Watts; positive grid = importing, positive battery = discharging.
struct SmartShiftFlow: Equatable {
    var solarW: Double
    var houseW: Double
    var batteryW: Double
    var gridW: Double
    var batteryKWh: Double?
    var batteryMaxKWh: Double?
    var action: String?            // what SmartShift is doing this interval: charge, discharge, preserve...
    var batteryPct: Double? {
        guard let e = batteryKWh, let m = batteryMaxKWh, m > 0 else { return nil }
        return max(0, min(100, e / m * 100))
    }
}

enum AmberCommand: String, CaseIterable, Identifiable {
    case charge, discharge, preserve = "preserve-charge", consume = "self-consume"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .charge: return "Charge"
        case .discharge: return "Discharge"
        case .preserve: return "Preserve"
        case .consume: return "Self-consume"
        }
    }
    /// What it does, for the confirmation.
    var meaning: String {
        switch self {
        case .charge: return "charge the battery, from the grid if the solar is not enough"
        case .discharge: return "discharge the battery to the house and the grid"
        case .preserve: return "hold the battery's charge, running the house from solar and the grid"
        case .consume: return "run the house from solar and the battery, without trading with the grid"
        }
    }
    static func label(for value: String) -> String { AmberCommand(rawValue: value)?.label ?? value }
}

@MainActor
final class SmartShiftControl: ObservableObject {
    static let shared = SmartShiftControl()

    // Amber's app's sign-in pool at Amazon Cognito (public identifiers, the same for every customer)
    private static let pool = "ap-southeast-2_vPQVymJLn", client = "11naqf0mbruts1osrjsnl2ee1"
    private static let cognito = URL(string: "https://cognito-idp.ap-southeast-2.amazonaws.com/")!
    private static let backend = URL(string: "https://backend.amber.com.au/graphql")!
    static let maxMinutes = 180

    @Published var signedIn = Keychain.load(Keychain.smartShiftRefresh) != nil
    @Published var busy = false
    @Published var error: String?
    @Published var status: AmberStatus?
    @Published var log: [String] = SmartShiftControl.readLog()

    private var idToken: String?
    private var idExpires = Date.distantPast
    private var siteId: String?, configId: String?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral                 // no cookies, no cache, nothing on disk
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = nil; c.urlCache = nil
        return URLSession(configuration: c)
    }()

    // MARK: sign-in

    private func cognito(_ target: String, _ payload: [String: Any]) async throws -> [String: Any] {
        var r = URLRequest(url: Self.cognito)
        r.httpMethod = "POST"
        r.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        r.setValue("AWSCognitoIdentityProviderService." + target, forHTTPHeaderField: "X-Amz-Target")
        r.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await session.data(for: r)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if (resp as? HTTPURLResponse)?.statusCode != 200 || body["__type"] != nil {
            let kind = (body["__type"] as? String)?.split(separator: "#").last.map(String.init) ?? "error"
            switch kind {
            case "NotAuthorizedException", "UserNotFoundException": throw AmberError.message("Amber did not accept that email and password.")
            case "TooManyRequestsException", "LimitExceededException": throw AmberError.message("Amber's sign-in is limiting attempts. Try again in a few minutes.")
            default: throw AmberError.message("Amber's sign-in refused the request (\(kind)).")
            }
        }
        return body
    }

    /// The password is used here, in memory, to compute the proof. It is not stored and not sent.
    func signIn(email: String, password: String) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let a = SRP.randomA()
            let bigA = await Task.detached { SRP.publicA(a).hex }.value
            let start = try await cognito("InitiateAuth", ["AuthFlow": "USER_SRP_AUTH", "ClientId": Self.client,
                                                           "AuthParameters": ["USERNAME": email, "SRP_A": bigA]])
            guard start["ChallengeName"] as? String == "PASSWORD_VERIFIER", let p = start["ChallengeParameters"] as? [String: String],
                  let b = p["SRP_B"], let salt = p["SALT"], let block = p["SECRET_BLOCK"], let user = p["USER_ID_FOR_SRP"],
                  let blockData = Data(base64Encoded: block) else {
                throw AmberError.message("Amber asked for a sign-in step this app does not handle (\(start["ChallengeName"] as? String ?? "unknown")).")
            }
            let stamp = SRP.timestamp(), poolName = String(Self.pool.split(separator: "_")[1])
            let sig = await Task.detached {
                SRP.signature(a: a, bHex: b, saltHex: salt, secretBlock: blockData, pool: poolName, user: user, password: password, timestamp: stamp)
            }.value
            guard let sig else { throw AmberError.message("Amber's sign-in sent values that are not safe to use. Nothing was sent back.") }
            var answer: [String: Any] = ["ChallengeName": "PASSWORD_VERIFIER", "ClientId": Self.client,
                                         "ChallengeResponses": ["USERNAME": p["USERNAME"] ?? user, "PASSWORD_CLAIM_SECRET_BLOCK": block,
                                                                "TIMESTAMP": stamp, "PASSWORD_CLAIM_SIGNATURE": sig]]
            if let s = start["Session"] as? String { answer["Session"] = s }
            let done = try await cognito("RespondToAuthChallenge", answer)
            guard let res = done["AuthenticationResult"] as? [String: Any], let id = res["IdToken"] as? String,
                  let renewal = res["RefreshToken"] as? String else {
                throw AmberError.message("Amber wants another sign-in step (\(done["ChallengeName"] as? String ?? "unknown")), such as a code. This app cannot do that step.")
            }
            guard Keychain.save(renewal, as: Keychain.smartShiftRefresh) else { throw AmberError.message("Signed in, but the Keychain would not store the sign-in. Nothing was kept.") }
            idToken = id
            idExpires = Date().addingTimeInterval(((res["ExpiresIn"] as? Double) ?? 3600) - 120)
            signedIn = true
            note("signed in")
            await refresh()
        } catch {
            self.error = (error as? AmberError)?.errorDescription ?? "Could not reach Amber's sign-in: \(error.localizedDescription)"
        }
    }

    /// Revokes the refresh token at Amazon, then forgets everything here.
    func signOut() async {
        if let t = Keychain.load(Keychain.smartShiftRefresh) { _ = try? await cognito("RevokeToken", ["Token": t, "ClientId": Self.client]) }
        Keychain.delete(Keychain.smartShiftRefresh)
        idToken = nil; idExpires = .distantPast; siteId = nil; configId = nil
        status = nil; signedIn = false; error = nil
        note("signed out")
    }

    private func currentToken() async throws -> String {
        if let t = idToken, idExpires > Date() { return t }
        guard let refresh = Keychain.load(Keychain.smartShiftRefresh) else { signedIn = false; throw AmberError.message("Not signed in to Amber.") }
        do {
            let r = try await cognito("InitiateAuth", ["AuthFlow": "REFRESH_TOKEN_AUTH", "ClientId": Self.client,
                                                       "AuthParameters": ["REFRESH_TOKEN": refresh]])
            guard let res = r["AuthenticationResult"] as? [String: Any], let id = res["IdToken"] as? String else {
                throw AmberError.message("Amber did not renew the sign-in.")
            }
            idToken = id
            idExpires = Date().addingTimeInterval(((res["ExpiresIn"] as? Double) ?? 3600) - 120)
            return id
        } catch let e as AmberError {
            if e.errorDescription?.contains("did not accept") == true {          // the refresh token has expired or been revoked
                Keychain.delete(Keychain.smartShiftRefresh); signedIn = false; status = nil
                throw AmberError.message("The Amber sign-in has expired. Sign in again.")
            }
            throw e
        }
    }

    // MARK: Amber's backend

    private func graph(_ query: String, _ variables: [String: Any] = [:]) async throws -> [String: Any] {
        var r = URLRequest(url: Self.backend)
        r.httpMethod = "POST"
        r.setValue(try await currentToken(), forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let errs = body["errors"] as? [[String: Any]], let first = errs.first {
            throw AmberError.message("Amber refused: \((first["message"] as? String ?? "unknown error").prefix(160))")
        }
        guard code == 200, let d = body["data"] as? [String: Any] else { throw AmberError.message("Amber's service answered with an error (\(code)).") }
        return d
    }

    private func site() async throws -> (site: String, config: String) {
        if let s = siteId, let c = configId { return (s, c) }
        let d = try await graph("query { smartshift { batterySetting { siteId selectedConfigId } } }")
        guard let b = (d["smartshift"] as? [String: Any])?["batterySetting"] as? [String: Any],
              let s = b["siteId"] as? String, let c = b["selectedConfigId"] as? String else {
            throw AmberError.message("Amber has no SmartShift battery on this account.")
        }
        siteId = s; configId = c
        return (s, c)
    }

    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let isoPlain = ISO8601DateFormatter()
    private static func date(_ s: Any?) -> Date? { (s as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) } }
    private static func stamp(_ d: Date) -> String {            // whole seconds, as Amber's app sends
        isoPlain.string(from: d).replacingOccurrences(of: "Z", with: ".000Z")
    }

    private func readStatus() async throws -> AmberStatus {
        let s = try await site()
        let d = try await graph("""
            query Status($siteId: String) {
              smartshift { batteryOverridesInfo(siteId: $siteId) { effectiveOverride { overrideId value validFrom validTo state } } }
              smartshiftBatteryStrategyConfig(siteId: $siteId) { status solarCurtailmentStatus }
            }
            """, ["siteId": s.site])
        var out = AmberStatus()
        if let c = d["smartshiftBatteryStrategyConfig"] as? [String: Any] {
            out.smartShiftOn = (c["status"] as? String).map { $0 == "enabled" }
            out.amberCurtailmentOn = (c["solarCurtailmentStatus"] as? String).map { $0 == "enabled" }
        }
        if let o = ((d["smartshift"] as? [String: Any])?["batteryOverridesInfo"] as? [String: Any])?["effectiveOverride"] as? [String: Any],
           let id = o["overrideId"] as? String, let v = o["value"] as? String {
            out.override = AmberOverride(id: id, value: v, from: Self.date(o["validFrom"]), to: Self.date(o["validTo"]), state: o["state"] as? String)
        }
        out.flow = try? await readFlow(site: s.site)      // a separate query, so the controls still work if this part changes
        return out
    }

    private func readFlow(site: String) async throws -> SmartShiftFlow? {
        let d = try await graph("""
            query Flow($siteId: String) {
              smartshift {
                plan(siteId: $siteId) {
                  sitePowerW solarPowerW fixedLoadPowerW batteryPowerW batteryMaxEnergyWh
                  forecastData {
                    ... on PastAndForecastData {
                      past { periodStart batteryEnergyWh actionDecisions { ... on SmartShiftBatteryActionDecision { batteryAction: action } } }
                    }
                  }
                }
              }
            }
            """, ["siteId": site])
        guard let p = (d["smartshift"] as? [String: Any])?["plan"] as? [String: Any] else { return nil }
        let num = { (k: String) -> Double? in (p[k] as? NSNumber)?.doubleValue }
        let past = ((p["forecastData"] as? [String: Any])?["past"] as? [[String: Any]]) ?? []
        let last = past.last
        let action = ((last?["actionDecisions"] as? [[String: Any]])?.first?["batteryAction"] as? String)
        return SmartShiftFlow(solarW: max(0, num("solarPowerW") ?? 0), houseW: max(0, num("fixedLoadPowerW") ?? 0),
                              batteryW: num("batteryPowerW") ?? 0, gridW: num("sitePowerW") ?? 0,
                              batteryKWh: (last?["batteryEnergyWh"] as? NSNumber).map { $0.doubleValue / 1000 },
                              batteryMaxKWh: num("batteryMaxEnergyWh").map { $0 / 1000 }, action: action)
    }

    func refresh() async {
        guard signedIn else { return }
        do { status = try await readStatus(); error = nil }
        catch { self.error = (error as? AmberError)?.errorDescription ?? "Could not reach Amber: \(error.localizedDescription)" }
    }

    private func cancelExisting() async throws -> Bool {
        let s = try await site()
        guard let o = try await readStatus().override else { return false }
        _ = try await graph("""
            mutation Cancel($input: CancelBatteryOverrideInput!) {
              smartshift { cancelBatteryOverride(input: $input) { overrideId } }
            }
            """, ["input": ["siteId": s.site, "configId": s.config, "overrideId": o.id]])
        return true
    }

    /// Cancels the override in force, if any, handing the battery straight back to SmartShift.
    func cancel() async {
        busy = true; defer { busy = false }
        do {
            let had = try await cancelExisting()
            note(had ? "cancelled the override" : "cancel asked for, but no override was in force")
            status = try await readStatus(); error = nil
        } catch { fail(error, doing: "cancel") }
    }

    /// One override, from now for `minutes` (capped), replacing any in force. Only ever called from a confirmed button.
    func send(_ command: AmberCommand, minutes: Int) async {
        busy = true; defer { busy = false }
        let mins = max(5, min(Self.maxMinutes, minutes))
        do {
            let s = try await site()
            guard try await readStatus().smartShiftOn != false else {
                throw AmberError.message("SmartShift is switched off in Amber's app, so Amber would ignore an override.")
            }
            if try await cancelExisting() { try await Task.sleep(for: .seconds(1)) }
            let from = Date(), to = from.addingTimeInterval(Double(mins) * 60)
            _ = try await graph("""
                mutation Add($input: AddBatteryOverrideInput!) {
                  smartshift { addBatteryOverride(input: $input) { overrideId value validFrom validTo } }
                }
                """, ["input": ["siteId": s.site, "configId": s.config, "overrideValue": command.rawValue,
                                "validFrom": Self.stamp(from), "validTo": Self.stamp(to)]])
            note("sent \(command.label.lowercased()) for \(mins) min, until \(Self.clock.string(from: to))")
            status = try await readStatus(); error = nil
        } catch { fail(error, doing: "send \(command.label.lowercased())") }
    }

    private func fail(_ error: Error, doing: String) {
        let text = (error as? AmberError)?.errorDescription ?? "Could not reach Amber: \(error.localizedDescription)"
        self.error = text
        note("could not \(doing): \(text)")
    }

    // MARK: the record of what was sent (no tokens, no account details)

    private static let clock: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_AU"); f.dateFormat = "h:mm a"; return f }()
    private static let logStamp: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_AU_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
    private static var logFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Gridwise", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("smartshift_overrides.log")
    }
    private static func readLog() -> [String] {
        ((try? String(contentsOf: logFile, encoding: .utf8)) ?? "").split(separator: "\n").suffix(8).map(String.init)
    }
    private func note(_ what: String) {
        let line = "\(Self.logStamp.string(from: Date())) \(what)"
        let all = ((try? String(contentsOf: Self.logFile, encoding: .utf8)) ?? "").split(separator: "\n").suffix(499).map(String.init) + [line]
        try? (all.joined(separator: "\n") + "\n").write(to: Self.logFile, atomically: true, encoding: .utf8)
        log = Array(all.suffix(8))
    }
}

// MARK: - The tile


/// Email and password, typed by the user. The password field is cleared as soon as the attempt ends.
struct AmberSignInSheet: View {
    @ObservedObject var amber: SmartShiftControl
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to SmartShift").font(.title3.weight(.semibold))
            Text("Use the email and password you sign in to Amber's app with. The password goes no further than this Mac: it is used once to prove who you are to Amber's sign-in service at Amazon, and is not saved. Gridwise keeps only a renewal token, in your Keychain.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Email", text: $email).textContentType(.username).textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password).textContentType(.password).textFieldStyle(.roundedBorder)
                .onSubmit { go() }
            if let e = amber.error { Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.orange) }
            HStack {
                if amber.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign in") { go() }.keyboardShortcut(.defaultAction)
                    .disabled(amber.busy || email.isEmpty || password.isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }

    private func go() {
        guard !email.isEmpty, !password.isEmpty, !amber.busy else { return }
        let e = email.trimmingCharacters(in: .whitespaces), pw = password
        password = ""
        Task {
            await amber.signIn(email: e, password: pw)
            if amber.signedIn { dismiss() }
        }
    }
}
