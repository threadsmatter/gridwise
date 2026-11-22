import Foundation
import Security

/// Secrets live in the login Keychain, never in a file: the Amber API token, and the SmartShift sign-in's
/// renewal token. Readable only by this Mac while it is unlocked.
enum Keychain {
    static let service = "Gridwise"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    @discardableResult
    static func save(_ value: String, as account: String) -> Bool {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrLabel as String] = "Gridwise: \(account)"
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    static func load(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }

    static let amberToken = "amber-api-token"
    static let smartShiftRefresh = "smartshift-refresh-token"
}

/// Everything else the user sets, in the app's own preferences. Nothing here is secret.
struct Setup: Codable, Equatable {
    var siteId: String?                  // which Amber site, when the account has more than one
    var place: String?                   // as the user typed it, for display only
    var latitude: Double?                // rounded to 2 decimal places (about 1 km) before it is saved
    var longitude: Double?
    var panelKW: Double?                 // size of the solar panels, for the solar outlook
    var supplyCentsPerDay: Double?       // daily supply charge on the Amber bill
    var membershipPerMonth: Double = 25  // Amber's monthly membership fee
    var billDay: Int = 1                 // the day of the month each Amber billing month starts
    var region: String?                  // NEM region override; otherwise from the site's network

    static let key = "setup"
    static func load() -> Setup {
        guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(Setup.self, from: d) else { return Setup() }
        return s
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Setup.key) }

    var hasPlace: Bool { latitude != nil && longitude != nil }
}

/// The five NEM price regions, and which one a distribution network sits in.
enum Region: String, CaseIterable, Identifiable {
    case NSW1, QLD1, VIC1, SA1, TAS1
    var id: String { rawValue }
    var name: String {
        switch self {
        case .NSW1: return "NSW and ACT"
        case .QLD1: return "Queensland"
        case .VIC1: return "Victoria"
        case .SA1: return "South Australia"
        case .TAS1: return "Tasmania"
        }
    }
    var timeZone: TimeZone {
        switch self {
        case .NSW1, .VIC1, .TAS1: return TimeZone(identifier: "Australia/Sydney")!
        case .QLD1: return TimeZone(identifier: "Australia/Brisbane")!
        case .SA1: return TimeZone(identifier: "Australia/Adelaide")!
        }
    }

    /// From the network name Amber gives for a site ("SA Power", "Ausgrid", "Energex", ...).
    static func from(network: String?) -> Region? {
        let n = (network ?? "").lowercased()
        let map: [(String, Region)] = [
            ("sa power", .SA1), ("ausgrid", .NSW1), ("endeavour", .NSW1), ("essential", .NSW1), ("evoenergy", .NSW1),
            ("actewagl", .NSW1), ("energex", .QLD1), ("ergon", .QLD1), ("citipower", .VIC1), ("powercor", .VIC1),
            ("jemena", .VIC1), ("ausnet", .VIC1), ("united", .VIC1), ("tasnetworks", .TAS1), ("aurora", .TAS1),
        ]
        return map.first { n.contains($0.0) }?.1
    }
}
