import Foundation
import Network

// Looks for solar inverters on the home network and says what it found. Read-only: it sends the
// manufacturers' own "who is there?" messages and checks which common ports answer, and never writes a
// setting. Results stay on this Mac.
//
//   GoodWe      UDP broadcast "WIFIKIT-214028-READ" to port 48899; the Wi-Fi stick answers with IP, MAC, name
//   Fronius     HTTP GET /solar_api/GetAPIVersion.cgi
//   Any brand   TCP port 502 open (Modbus TCP: SMA, Sungrow, Huawei, SolarEdge, Fronius and others)

struct FoundDevice: Identifiable, Hashable {
    let ip: String
    let kind: String            // what answered
    let detail: String
    var id: String { ip + kind }
}

enum InverterScan {
    /// The Mac's own IPv4 address and netmask on its main network interface.
    static func localNetwork() -> (ip: UInt32, mask: UInt32)? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var best: (UInt32, UInt32)?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), let nm = a.ifa_netmask else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // private ranges only
            let isPrivate = (ip >> 24 == 10) || (ip >> 20 == 0xAC1) || (ip >> 16 == 0xC0A8)
            if isPrivate { best = (ip, mask); if name == "en0" { break } }
        }
        return best
    }

    static func dotted(_ v: UInt32) -> String { "\(v >> 24).\((v >> 16) & 255).\((v >> 8) & 255).\(v & 255)" }

    /// Everything the scan can find, in about 10 seconds. Only scans networks of 1,024 addresses or fewer.
    static func run() async -> (devices: [FoundDevice], note: String?) {
        guard let net = localNetwork() else { return ([], "This Mac is not on a home network the scan can read.") }
        let size = ~net.mask &+ 1
        guard size <= 1024, size > 2 else { return ([], "The network is too large to scan (\(size) addresses).") }
        let base = net.ip & net.mask
        let hosts = (1..<(size - 1)).map { base &+ $0 }.filter { $0 != net.ip }.map(dotted)
        let broadcast = dotted(base | ~net.mask)

        async let goodwe = goodWeDiscovery(broadcast: broadcast)
        var found: [FoundDevice] = []
        await withTaskGroup(of: FoundDevice?.self) { g in
            var it = hosts.makeIterator()
            var running = 0
            func next() -> Bool {
                guard let h = it.next() else { return false }
                g.addTask { await portOpen(h, 502, timeout: 1.2) ? FoundDevice(ip: h, kind: "Modbus TCP (port 502)", detail: "Many inverters and batteries answer here") : nil }
                return true
            }
            while running < 64, next() { running += 1 }
            for await r in g {
                if let r { found.append(r) }
                _ = next()
            }
        }
        found += await goodwe
        // a Fronius answers its own web API; ask the hosts that answered on 502 and any others quickly
        for h in Set(found.map(\.ip)) {
            if let v = await froniusVersion(h) { found.append(FoundDevice(ip: h, kind: "Fronius", detail: v)) }
        }
        let order = ["GoodWe": 0, "Fronius": 1]
        return (found.sorted { (order[$0.kind] ?? 9, $0.ip) < (order[$1.kind] ?? 9, $1.ip) }, nil)
    }

    static func portOpen(_ host: String, _ port: UInt16, timeout: Double) async -> Bool {
        await withCheckedContinuation { cont in
            let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let done = Once()
            c.stateUpdateHandler = { s in
                switch s {
                case .ready: if done.first() { c.cancel(); cont.resume(returning: true) }
                case .failed, .cancelled: if done.first() { cont.resume(returning: false) }
                case .waiting: if done.first() { c.cancel(); cont.resume(returning: false) }
                default: break
                }
            }
            c.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if done.first() { c.cancel(); cont.resume(returning: false) } }
        }
    }

    /// GoodWe's discovery broadcast, the one its SolarGo app uses.
    static func goodWeDiscovery(broadcast: String) async -> [FoundDevice] {
        await Task.detached { () -> [FoundDevice] in
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return [] }
            defer { close(fd) }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 0, tv_usec: 400_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let msg = Array("WIFIKIT-214028-READ".utf8)
            func ask() {
                for target in [broadcast, "255.255.255.255"] {
                    var addr = sockaddr_in()
                    addr.sin_family = sa_family_t(AF_INET); addr.sin_port = in_port_t(48899).bigEndian
                    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    inet_pton(AF_INET, target, &addr.sin_addr)
                    _ = withUnsafePointer(to: &addr) { p in
                        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                    }
                }
            }
            // the sticks sometimes ignore one query (seen 22 Nov 2026), so ask three times over the wait
            var out: [FoundDevice] = []
            let started = Date(), end = started.addingTimeInterval(4.5)
            var asked = 0
            var buf = [UInt8](repeating: 0, count: 512)
            while Date() < end {
                if asked < 3 && Date().timeIntervalSince(started) >= Double(asked) * 1.4 { ask(); asked += 1 }
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0 else { continue }
                // "192.168.1.50,AABBCCDDEEFF,Solar-WiFi..."
                let parts = (String(bytes: buf[0..<n], encoding: .utf8) ?? "").split(separator: ",").map(String.init)
                if parts.count >= 3, !out.contains(where: { $0.ip == parts[0] }) {
                    out.append(FoundDevice(ip: parts[0], kind: "GoodWe", detail: "Wi-Fi stick \(parts[2])"))
                }
            }
            return out
        }.value
    }

    static func froniusVersion(_ host: String) async -> String? {
        guard let url = URL(string: "http://\(host)/solar_api/GetAPIVersion.cgi") else { return nil }
        var r = URLRequest(url: url); r.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession(configuration: .ephemeral).data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["APIVersion"] != nil else { return nil }
        return "Solar API version \(j["APIVersion"] ?? "?")"
    }
}

/// True the first time only: lets one of several callbacks finish a continuation.
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
