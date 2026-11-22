import Foundation
import CryptoKit
import Security

// The SRP maths behind Amber's sign-in (Amazon Cognito's USER_SRP_AUTH): the password is used here, in
// memory, to compute a proof, and is never sent anywhere. Checked against an independent simulation of the
// server side and against Cognito itself.

// MARK: - A small unsigned big integer (enough for SRP: compare, add, subtract, multiply, modular power)

struct Big: Equatable {
    var l: [UInt32]                      // little-endian limbs, no trailing zeros

    init(_ limbs: [UInt32] = []) { l = limbs; trim() }
    init(_ v: UInt32) { l = v == 0 ? [] : [v] }
    init?(hex: String) {
        var h = hex.lowercased()
        guard !h.isEmpty, h.allSatisfy({ $0.isHexDigit }) else { return nil }
        if h.count % 8 != 0 { h = String(repeating: "0", count: 8 - h.count % 8) + h }
        var out: [UInt32] = []
        var i = h.endIndex
        while i > h.startIndex {
            let j = h.index(i, offsetBy: -8)
            guard let v = UInt32(h[j..<i], radix: 16) else { return nil }
            out.append(v); i = j
        }
        l = out; trim()
    }
    init(bytes: Data) { self.init(hex: bytes.isEmpty ? "0" : bytes.map { String(format: "%02x", $0) }.joined())! }

    private mutating func trim() { while let last = l.last, last == 0 { l.removeLast() } }
    var isZero: Bool { l.isEmpty }
    var bitWidth: Int { l.isEmpty ? 0 : (l.count - 1) * 32 + (32 - l.last!.leadingZeroBitCount) }
    func bit(_ i: Int) -> Bool { i / 32 < l.count && (l[i / 32] >> UInt32(i % 32)) & 1 == 1 }
    var hex: String {
        guard let top = l.last else { return "0" }
        return String(top, radix: 16) + l.dropLast().reversed().map { String(format: "%08x", $0) }.joined()
    }

    static func cmp(_ a: Big, _ b: Big) -> Int {
        if a.l.count != b.l.count { return a.l.count < b.l.count ? -1 : 1 }
        for i in stride(from: a.l.count - 1, through: 0, by: -1) where a.l[i] != b.l[i] { return a.l[i] < b.l[i] ? -1 : 1 }
        return 0
    }
    static func + (a: Big, b: Big) -> Big {
        var out = [UInt32](); out.reserveCapacity(max(a.l.count, b.l.count) + 1)
        var c: UInt64 = 0
        for i in 0..<max(a.l.count, b.l.count) {
            let s = UInt64(i < a.l.count ? a.l[i] : 0) + UInt64(i < b.l.count ? b.l[i] : 0) + c
            out.append(UInt32(truncatingIfNeeded: s)); c = s >> 32
        }
        if c > 0 { out.append(UInt32(c)) }
        return Big(out)
    }
    /// a - b, for a >= b.
    static func - (a: Big, b: Big) -> Big {
        precondition(cmp(a, b) >= 0)
        var out = a.l
        var borrow: Int64 = 0
        for i in 0..<out.count {
            let d = Int64(out[i]) - Int64(i < b.l.count ? b.l[i] : 0) - borrow
            if d < 0 { out[i] = UInt32(truncatingIfNeeded: d + (1 << 32)); borrow = 1 } else { out[i] = UInt32(d); borrow = 0 }
        }
        return Big(out)
    }
    static func * (a: Big, b: Big) -> Big {
        if a.isZero || b.isZero { return Big() }
        var out = [UInt32](repeating: 0, count: a.l.count + b.l.count)
        for i in 0..<a.l.count {
            var c: UInt64 = 0
            for j in 0..<b.l.count {
                let s = UInt64(out[i + j]) + UInt64(a.l[i]) * UInt64(b.l[j]) + c
                out[i + j] = UInt32(truncatingIfNeeded: s); c = s >> 32
            }
            out[i + b.l.count] = UInt32(c)
        }
        return Big(out)
    }
    /// self mod n, one bit at a time (only used a handful of times per sign-in).
    func mod(_ n: Big) -> Big {
        if Big.cmp(self, n) < 0 { return self }
        var r = Big()
        for i in stride(from: bitWidth - 1, through: 0, by: -1) {
            r = r + r
            if bit(i) { r = r + Big(1) }
            if Big.cmp(r, n) >= 0 { r = r - n }
        }
        return r
    }
}

/// Modular multiplication and powers for an odd modulus (Montgomery form).
struct Modulus {
    let n: Big
    private let k: Int
    private let nl: [UInt32]
    private let n0inv: UInt32
    private let r2: [UInt32]

    init(_ n: Big) {
        precondition(!n.isZero && n.l[0] & 1 == 1)
        self.n = n; k = n.l.count; nl = n.l
        var inv = n.l[0]                                     // Newton: n0 * inv = 1 mod 2^32
        for _ in 0..<5 { inv = inv &* (2 &- n.l[0] &* inv) }
        n0inv = 0 &- inv
        var one = [UInt32](repeating: 0, count: 2 * k + 1); one[2 * k] = 1
        r2 = Modulus.pad(Big(one).mod(n).l, k)
    }

    private static func pad(_ a: [UInt32], _ k: Int) -> [UInt32] { a + [UInt32](repeating: 0, count: k - a.count) }

    private func mont(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var t = [UInt32](repeating: 0, count: k + 2)
        for i in 0..<k {
            var c: UInt64 = 0
            let bi = UInt64(b[i])
            for j in 0..<k {
                let s = UInt64(t[j]) + UInt64(a[j]) * bi + c
                t[j] = UInt32(truncatingIfNeeded: s); c = s >> 32
            }
            var s = UInt64(t[k]) + c
            t[k] = UInt32(truncatingIfNeeded: s); t[k + 1] = UInt32(s >> 32)
            let m = UInt64(t[0] &* n0inv)
            var s2 = UInt64(t[0]) + m * UInt64(nl[0])
            c = s2 >> 32
            for j in 1..<k {
                s2 = UInt64(t[j]) + m * UInt64(nl[j]) + c
                t[j - 1] = UInt32(truncatingIfNeeded: s2); c = s2 >> 32
            }
            s = UInt64(t[k]) + c
            t[k - 1] = UInt32(truncatingIfNeeded: s)
            t[k] = t[k + 1] &+ UInt32(s >> 32)
            t[k + 1] = 0
        }
        var r = Big(Array(t[0...k]))
        if Big.cmp(r, n) >= 0 { r = r - n }
        return Modulus.pad(r.l, k)
    }

    func mul(_ a: Big, _ b: Big) -> Big {
        let x = mont(Modulus.pad(a.mod(n).l, k), Modulus.pad(b.mod(n).l, k))
        return Big(mont(x, r2))
    }

    func pow(_ base: Big, _ exp: Big) -> Big {
        var one = [UInt32](repeating: 0, count: k); one[0] = 1
        let b = mont(Modulus.pad(base.mod(n).l, k), r2)
        var r = mont(one, r2)
        for i in stride(from: exp.bitWidth - 1, through: 0, by: -1) {
            r = mont(r, r)
            if exp.bit(i) { r = mont(r, b) }
        }
        return Big(mont(r, one))
    }
}

// MARK: - SRP, as Amazon Cognito does it

enum SRP {
    /// The 3072-bit group Cognito uses (RFC 3526 group 15), generator 2.
    static let nHex =
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74" +
        "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437" +
        "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED" +
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05" +
        "98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB" +
        "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B" +
        "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718" +
        "3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33" +
        "A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7" +
        "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864" +
        "D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2" +
        "08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF"
    static let N = Big(hex: nHex)!
    static let g = Big(2)
    static let field = Modulus(N)

    static func bytes(hex: String) -> Data {
        var h = hex; if h.count % 2 == 1 { h = "0" + h }
        var d = Data(capacity: h.count / 2)
        var i = h.startIndex
        while i < h.endIndex { let j = h.index(i, offsetBy: 2); d.append(UInt8(h[i..<j], radix: 16)!); i = j }
        return d
    }
    /// Hex as a positive two's-complement number: even length, and a 00 in front if the top bit is set.
    static func pad(_ hex: String) -> String {
        var h = hex; if h.count % 2 == 1 { h = "0" + h }
        if let first = UInt8(h.prefix(2), radix: 16), first >= 0x80 { h = "00" + h }
        return h
    }
    static func sha(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }
    static func hmac(key: Data, _ msg: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))) }
    static func hexOf(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static let k = Big(bytes: sha(bytes(hex: pad(N.hex) + pad(g.hex))))

    static func publicA(_ a: Big) -> Big { field.pow(g, a) }

    /// The PASSWORD_CLAIM_SIGNATURE for Cognito's PASSWORD_VERIFIER challenge, or nil if the server's values are unsafe.
    static func signature(a: Big, bHex: String, saltHex: String, secretBlock: Data, pool: String, user: String,
                          password: String, timestamp: String) -> String? {
        guard let B = Big(hex: bHex), !B.mod(N).isZero else { return nil }
        let A = publicA(a)
        let uData = sha(bytes(hex: pad(A.hex) + pad(B.hex)))
        let u = Big(bytes: uData)
        guard !u.isZero else { return nil }
        let inner = sha(Data((pool + user + ":" + password).utf8))
        let x = Big(bytes: sha(bytes(hex: pad(saltHex)) + inner))
        let kgx = field.mul(k, field.pow(g, x))
        let b = B.mod(N)
        let base = Big.cmp(b, kgx) >= 0 ? b - kgx : (b + N) - kgx
        let s = field.pow(base, a + u * x)
        let prk = hmac(key: bytes(hex: pad(hexOf(uData))), bytes(hex: pad(s.hex)))
        let key = hmac(key: prk, Data("Caldera Derived Key".utf8) + Data([1])).prefix(16)
        let msg = Data(pool.utf8) + Data(user.utf8) + secretBlock + Data(timestamp.utf8)
        return hmac(key: Data(key), msg).base64EncodedString()
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss 'UTC' yyyy"
        return f.string(from: date)
    }

    static func randomA() -> Big {
        var raw = [UInt8](repeating: 0, count: 128)
        guard SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess else { fatalError("no random numbers") }
        return Big(bytes: Data(raw))
    }
}
