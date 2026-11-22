import Foundation
import CryptoKit

// AlphaESS Open API (open.alphaess.com): the battery maker's own cloud, which also serves systems sold as
// Bytewatt and Neovolt in Australia. An owner registers for free, adds their system with its serial number
// and check code, and gets an AppID and AppSecret. getLastPowerData gives live watts every 10 seconds or so,
// from the battery system's own meter: good enough to follow the house load for curtailment.
//
// Signing, as AlphaESS documents it and the open-source clients do it: headers appId, timeStamp (Unix seconds)
// and sign = SHA-512 hex of appId + appSecret + timeStamp. AlphaESS asks for at least 10 seconds between calls.
// Signs, the same as the battery's own: pgrid > 0 importing, pbat > 0 discharging.

struct BatteryReading: Equatable {
    let at: Date
    let gridW: Double
    let batteryW: Double
    let houseW: Double?
    let solarW: Double?
    let socPct: Double?
}

enum AlphaESSError: LocalizedError {
    case api(Int, String), http(Int), network(String), noSystems
    var errorDescription: String? {
        switch self {
        case .api(let c, let m): return "AlphaESS refused (\(c)): \(m)"
        case .http(let c): return "AlphaESS answered with an error (\(c))."
        case .network(let m): return "Could not reach AlphaESS: \(m)"
        case .noSystems: return "AlphaESS accepted the key, but no system is added to it yet. Add yours at open.alphaess.com with its serial number and check code."
        }
    }
}

struct AlphaESS {
    let appID: String
    let appSecret: String
    static let base = URL(string: "https://openapi.alphaess.com/api/")!
    static let keychainID = "alphaess-app-id", keychainSecret = "alphaess-app-secret"
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = nil; c.urlCache = nil
        return URLSession(configuration: c)
    }()

    static func saved() -> AlphaESS? {
        guard let i = Keychain.load(keychainID), let s = Keychain.load(keychainSecret) else { return nil }
        return AlphaESS(appID: i, appSecret: s)
    }
    func save() -> Bool { Keychain.save(appID, as: Self.keychainID) && Keychain.save(appSecret, as: Self.keychainSecret) }
    static func forget() { Keychain.delete(keychainID); Keychain.delete(keychainSecret) }

    static func sign(_ id: String, _ secret: String, _ stamp: String) -> String {
        SHA512.hash(data: Data((id + secret + stamp).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func get(_ path: String) async throws -> Any? {
        let stamp = String(Int(Date().timeIntervalSince1970))
        var r = URLRequest(url: URL(string: path, relativeTo: Self.base)!)
        r.setValue(appID, forHTTPHeaderField: "appId")
        r.setValue(stamp, forHTTPHeaderField: "timeStamp")
        r.setValue(Self.sign(appID, appSecret, stamp), forHTTPHeaderField: "sign")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await Self.session.data(for: r) } catch { throw AlphaESSError.network(error.localizedDescription) }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw AlphaESSError.http((resp as? HTTPURLResponse)?.statusCode ?? 0) }
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (j["code"] as? NSNumber)?.intValue ?? -1
        guard code == 200 else { throw AlphaESSError.api(code, j["msg"] as? String ?? "unknown") }
        return j["data"]
    }

    /// The systems on this key: serial number and model.
    func systems() async throws -> [(sn: String, model: String)] {
        let list = try await get("getEssList") as? [[String: Any]] ?? []
        let out = list.compactMap { s -> (sn: String, model: String)? in
            guard let sn = s["sysSn"] as? String else { return nil }
            return (sn, (s["minv"] as? String) ?? (s["mbat"] as? String) ?? "AlphaESS system")
        }
        if out.isEmpty { throw AlphaESSError.noSystems }
        return out
    }

    func lastPower(sn: String) async throws -> BatteryReading {
        let enc = sn.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sn
        let d = try await get("getLastPowerData?sysSn=\(enc)") as? [String: Any] ?? [:]
        let n = { (k: String) -> Double? in (d[k] as? NSNumber)?.doubleValue }
        guard let grid = n("pgrid") else { throw AlphaESSError.api(0, "no grid reading in the answer") }
        return BatteryReading(at: Date(), gridW: grid, batteryW: n("pbat") ?? 0, houseW: n("pload"), solarW: n("ppv"), socPct: n("soc"))
    }
}
