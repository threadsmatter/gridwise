import Foundation

// Talking to inverters on the home network, for curtailment. Two families:
//
//   GoodWe       Modbus RTU framed over UDP port 8899 (the Wi-Fi/LAN stick), the protocol of the open-source
//                `goodwe` Python library, byte for byte. Grid-tied models (MS, DT, D-NS, XS) use address 0x7F.
//                The power limit is register 40480, whole per cent of rated power: the same setting as
//                "Power limit" in GoodWe's SolarGo app. Verified on a GW10K-MS (22 Oct 2026). On other models
//                it is a trial: every write is read back and anything unexpected stops curtailment.
//
//   SunSpec      Modbus TCP port 502, the open standard used by Fronius, SMA, SolarEdge and others. Model 123
//                (immediate controls) sets WMaxLimPct with a revert time, so the inverter undoes the limit by
//                itself if Gridwise stops renewing it. Needs Modbus TCP control switched on in the inverter's
//                own settings (Fronius: "Inverter control via Modbus"). Not yet tried on a real inverter.
//
// Nothing here is called unless the user has switched curtailment on for that inverter.

struct InverterState: Equatable {
    var outputW: Double?          // AC output now
    var limitPct: Double?         // the power limit in force, % of rated (nil: no limit set)
}

protocol Inverter: AnyObject {
    var host: String { get }
    var kind: String { get }              // "GoodWe" or "SunSpec"
    var model: String { get }
    var ratedW: Double { get }
    var tested: Bool { get }              // this model's limit setting has been proven on real hardware
    var revertsByItself: Bool { get }     // the inverter undoes the limit if it stops being renewed
    func read() async throws -> InverterState
    /// Sets the limit (whole per cent, 1...100) and reads it back; throws if the inverter does not hold it.
    func setLimit(_ pct: Int) async throws
    /// Takes the limit off again, back to what it was before Gridwise touched it.
    func restore(to original: InverterState) async throws
}

enum InverterError: LocalizedError {
    case noAnswer(String), badAnswer(String), refused(String), mismatch(String), unsupported(String)
    var errorDescription: String? {
        switch self {
        case .noAnswer(let s): return "The inverter did not answer (\(s))."
        case .badAnswer(let s): return "The inverter's answer did not make sense (\(s))."
        case .refused(let s): return "The inverter refused the request (\(s))."
        case .mismatch(let s): return "The inverter did not keep the setting (\(s)). Curtailment has stopped."
        case .unsupported(let s): return s
        }
    }
}

// MARK: - Modbus CRC (the RTU flavour)

enum ModbusCRC {
    private static let table: [UInt16] = (0..<256).map { i -> UInt16 in
        var crc: UInt16 = 0, buf = UInt16(i)
        for _ in 0..<8 {
            if (buf ^ crc) & 1 != 0 { crc = (crc >> 1) ^ 0xA001 } else { crc >>= 1 }
            buf >>= 1
        }
        return crc
    }
    static func of(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes { crc = (crc >> 8) ^ table[Int((crc ^ UInt16(b)) & 0xFF)] }
        return crc
    }
}

// MARK: - Plain sockets with timeouts

enum Wire {
    static func sockaddr(_ host: String, _ port: UInt16) -> sockaddr_in? {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &a.sin_addr) == 1 else { return nil }
        return a
    }

    /// One UDP request and its answer, trying `tries` times.
    static func udp(_ host: String, _ port: UInt16, _ request: [UInt8], timeout: Double = 1.5, tries: Int = 3,
                    accept: ([UInt8]) -> Bool) throws -> [UInt8] {
        guard var addr = sockaddr(host, port) else { throw InverterError.noAnswer("bad address \(host)") }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw InverterError.noAnswer("no socket") }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 1024)
        for _ in 0..<tries {
            let sent = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { sendto(fd, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard sent == request.count else { continue }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                let got = Array(buf[0..<n])
                if accept(got) { return got }
            }
        }
        throw InverterError.noAnswer("\(host):\(port), \(tries) tries")
    }

    /// A TCP connection with a connect timeout, then blocking reads and writes with timeouts.
    static func tcp(_ host: String, _ port: UInt16, timeout: Double = 3) throws -> Int32 {
        guard var addr = sockaddr(host, port) else { throw InverterError.noAnswer("bad address \(host)") }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw InverterError.noAnswer("no socket") }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 && errno != EINPROGRESS { close(fd); throw InverterError.noAnswer("\(host):\(port) refused") }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        guard ready == 1, err == 0 else { close(fd); throw InverterError.noAnswer("\(host):\(port) did not connect") }
        _ = fcntl(fd, F_SETFL, flags)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func readExactly(_ fd: Int32, _ n: Int) throws -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(n)
        var buf = [UInt8](repeating: 0, count: n)
        while out.count < n {
            let got = recv(fd, &buf, n - out.count, 0)
            guard got > 0 else { throw InverterError.noAnswer("connection closed or timed out") }
            out += buf[0..<got]
        }
        return out
    }
}

// MARK: - GoodWe

final class GoodWeInverter: Inverter {
    static let limitRegister: UInt16 = 40480
    let host: String
    let kind = "GoodWe"
    private(set) var model = "GoodWe"
    private(set) var ratedW: Double = 0
    var tested: Bool { model.uppercased().hasSuffix("-MS") || model.uppercased().hasSuffix("MS") }
    let revertsByItself = false
    private let address: UInt8 = 0x7F
    private let port: UInt16
    private let lock = NSLock()          // one request on the wire at a time

    init(host: String, port: UInt16 = 8899) { self.host = host; self.port = port }

    static func request(_ addr: UInt8, _ cmd: UInt8, _ reg: UInt16, _ value: UInt16) -> [UInt8] {
        var d: [UInt8] = [addr, cmd, UInt8(reg >> 8), UInt8(reg & 0xFF), UInt8(value >> 8), UInt8(value & 0xFF)]
        let crc = ModbusCRC.of(d)
        d += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return d
    }

    /// Answers start AA 55, then address and command; the CRC covers everything after AA 55.
    static func valid(_ r: [UInt8], cmd: UInt8, reg: UInt16, value: UInt16) -> Bool {
        guard r.count > 4, r[0] == 0xAA, r[1] == 0x55 else { return false }
        let length: Int
        if r[3] == 0x03 {
            guard Int(r[4]) == Int(value) * 2 else { return false }
            length = Int(r[4]) + 7
        } else if r[3] == 0x06 {
            guard r.count >= 10, UInt16(r[4]) << 8 | UInt16(r[5]) == reg, UInt16(r[6]) << 8 | UInt16(r[7]) == value else { return false }
            length = 10
        } else {
            length = r.count                 // an error answer: command with the top bit set, then a code
        }
        guard r.count >= length, length >= 4 else { return false }
        let crc = ModbusCRC.of(Array(r[2..<(length - 2)]))
        guard crc == UInt16(r[length - 1]) << 8 | UInt16(r[length - 2]) else { return false }
        return r[3] == cmd || r[3] == cmd | 0x80
    }

    private func exchange(_ cmd: UInt8, _ reg: UInt16, _ value: UInt16) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        let req = Self.request(address, cmd, reg, value)
        let r = try Wire.udp(host, port, req) { Self.valid($0, cmd: cmd, reg: reg, value: value) }
        if r[3] & 0x80 != 0 { throw InverterError.refused("Modbus error \(r.count > 4 ? r[4] : 0)") }
        return r
    }

    func readRegisters(_ start: UInt16, _ count: UInt16) throws -> [UInt8] {
        let r = try exchange(0x03, start, count)
        return Array(r[5..<(5 + Int(count) * 2)])
    }

    /// GoodWe's solar-only lines, the ones that use address 0x7F and the 40480 power limit.
    static let solarOnly: Set<String> = ["MS", "DT", "NS", "DNS", "XS", "SDT", "MT", "SMT"]
    /// Hybrid and battery lines (ET, EH, BT, BH, ES, EM, BP and their variants): solar and battery on one
    /// inverter, often run by Amber's SmartShift. Gridwise never writes to these.
    static func family(of model: String) -> (solarOnly: Bool, hybrid: Bool) {
        let parts = model.uppercased().split(separator: "-").dropFirst().map(String.init)
        if parts.contains(where: { solarOnly.contains($0) }) { return (true, false) }
        let hybrid = parts.contains { $0.hasPrefix("E") || $0.hasPrefix("B") || $0.contains("BP") }
        return (false, hybrid)
    }
    static let hybridNote = "Gridwise doesn't control GoodWe hybrid or battery inverters (ET, EH, BT, BH, ES, EM, BP): a power limit would also cut the battery, and Amber or your installer manages these."

    /// Model name (registers 30012-30016) and rated power from it ("GW10K-MS" is 10 kW).
    /// Refuses anything that isn't a known solar-only model, unless `anyModel` (only for putting a limit back).
    func identify(anyModel: Bool = false) async throws {
        let d: [UInt8]
        do { d = try await Task.detached { try self.readRegisters(0x7531, 0x28) }.value }
        catch InverterError.noAnswer(let why) where !anyModel {
            throw InverterError.unsupported("This GoodWe didn't answer as a solar-only model (MS, DT, D-NS, XS) (\(why)). \(Self.hybridNote) If it is solar-only, check it's switched on and on the network.")
        }
        let name = String(bytes: d[22..<32], encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        model = name.isEmpty ? "GoodWe" : name
        if let m = model.range(of: #"(\d+(?:\.\d+)?)K"#, options: .regularExpression),
           let kw = Double(model[m].dropLast()) { ratedW = kw * 1000 }
        if anyModel { return }
        let f = Self.family(of: name)
        if f.hybrid { throw InverterError.unsupported("\(model) is a hybrid. \(Self.hybridNote)") }
        if !f.solarOnly { throw InverterError.unsupported("Gridwise doesn't recognise this GoodWe model (\(name.isEmpty ? "no model name" : name)), so it won't change its settings. Solar-only models it knows: MS, DT, D-NS, XS, SDT, MT.") }
    }

    func read() async throws -> InverterState {
        try await Task.detached { () -> InverterState in
            let run = try self.readRegisters(0x7594, 0x49)               // 30100 on
            let o = (30127 - 30100) * 2                                  // total inverter power, 4 bytes
            let raw = UInt32(run[o]) << 24 | UInt32(run[o + 1]) << 16 | UInt32(run[o + 2]) << 8 | UInt32(run[o + 3])
            let lim = try self.readRegisters(Self.limitRegister, 1)
            let pct = Double(UInt16(lim[0]) << 8 | UInt16(lim[1]))
            return InverterState(outputW: raw == 0xFFFFFFFF ? nil : Double(raw), limitPct: pct)
        }.value
    }

    func setLimit(_ pct: Int) async throws {
        guard (1...100).contains(pct) else { throw InverterError.refused("limit \(pct)% is out of range") }
        try await Task.detached {
            _ = try self.exchange(0x06, Self.limitRegister, UInt16(pct))
            let back = try self.readRegisters(Self.limitRegister, 1)
            let v = Int(UInt16(back[0]) << 8 | UInt16(back[1]))
            if v != pct { throw InverterError.mismatch("wrote \(pct)%, it reads \(v)%") }
        }.value
    }

    func restore(to original: InverterState) async throws {
        try await setLimit(Int((original.limitPct ?? 100).rounded()))
    }
}

// MARK: - SunSpec over Modbus TCP

final class SunSpecInverter: Inverter {
    let host: String
    let kind = "SunSpec"
    private(set) var model = "SunSpec inverter"
    private(set) var ratedW: Double = 0
    let tested = false
    let revertsByItself = true
    static let revertSeconds: UInt16 = 600          // the inverter drops the limit by itself after 10 minutes unrenewed
    private var unit: UInt8 = 1
    private var base: UInt16 = 40000
    private var inverterAt: UInt16?                 // start of model 101/102/103
    private var controlsAt: UInt16?                 // start of model 123
    private var limitSF: Int = 0
    private var tid: UInt16 = 0
    private let port: UInt16
    private let lock = NSLock()

    init(host: String, port: UInt16 = 502) { self.host = host; self.port = port }

    private func call(_ fn: UInt8, _ body: [UInt8]) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        let fd = try Wire.tcp(host, port)
        defer { close(fd) }
        tid &+= 1
        let len = UInt16(body.count + 2)
        let req: [UInt8] = [UInt8(tid >> 8), UInt8(tid & 0xFF), 0, 0, UInt8(len >> 8), UInt8(len & 0xFF), unit, fn] + body
        guard send(fd, req, req.count, 0) == req.count else { throw InverterError.noAnswer("send failed") }
        let head = try Wire.readExactly(fd, 8)
        guard head[0] == req[0], head[1] == req[1] else { throw InverterError.badAnswer("wrong transaction") }
        let rest = Int(UInt16(head[4]) << 8 | UInt16(head[5])) - 2
        guard rest >= 0, rest < 300 else { throw InverterError.badAnswer("length \(rest)") }
        let data = try Wire.readExactly(fd, rest)
        if head[7] & 0x80 != 0 { throw InverterError.refused("Modbus exception \(data.first ?? 0)") }
        return data
    }

    func readRegs(_ start: UInt16, _ count: UInt16) throws -> [UInt16] {
        let d = try call(0x03, [UInt8(start >> 8), UInt8(start & 0xFF), UInt8(count >> 8), UInt8(count & 0xFF)])
        guard d.count == 1 + Int(count) * 2, Int(d[0]) == Int(count) * 2 else { throw InverterError.badAnswer("read of \(count) registers") }
        return (0..<Int(count)).map { UInt16(d[1 + $0 * 2]) << 8 | UInt16(d[2 + $0 * 2]) }
    }

    func writeRegs(_ start: UInt16, _ values: [UInt16]) throws {
        var body: [UInt8] = [UInt8(start >> 8), UInt8(start & 0xFF), 0, UInt8(values.count), UInt8(values.count * 2)]
        for v in values { body += [UInt8(v >> 8), UInt8(v & 0xFF)] }
        _ = try call(0x10, body)
    }

    private static func text(_ regs: ArraySlice<UInt16>) -> String {
        let bytes = regs.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
    }
    private static func sf(_ v: UInt16) -> Int { Int(Int16(bitPattern: v)) }
    private static func scaled(_ v: Int, _ sf: Int) -> Double { Double(v) * pow(10, Double(sf)) }

    /// Finds the SunSpec map ("SunS" at 40000, 0 or 50000; unit 1 or 126), then the models Gridwise uses.
    /// SunSpec models that mean a battery is part of this inverter: 124 (storage), 713 (DER storage capacity),
    /// 802-805 (battery). Gridwise refuses these unless `anyModel` (only for putting a limit back).
    static let storageModels: Set<UInt16> = [124, 713, 802, 803, 804, 805]

    func identify(anyModel: Bool = false) async throws {
        try await Task.detached {
            var found = false
            var storage = false
            outer: for u in [UInt8(1), 126] {
                for b in [UInt16(40000), 0, 50000] {
                    self.unit = u
                    if let r = try? self.readRegs(b, 2), r == [0x5375, 0x6E53] { self.base = b; found = true; break outer }
                }
            }
            guard found else { throw InverterError.unsupported("No SunSpec map found. Check that Modbus TCP is switched on in the inverter's settings.") }
            var at = self.base + 2
            for _ in 0..<40 {
                let h = try self.readRegs(at, 2)
                let id = h[0], len = h[1]
                if id == 0xFFFF { break }
                switch id {
                case 1:
                    let c = try self.readRegs(at + 2, 32)
                    let mn = Self.text(c[0..<16]), md = Self.text(c[16..<32])
                    self.model = [mn, md].filter { !$0.isEmpty }.joined(separator: " ")
                case 101, 102, 103: self.inverterAt = at
                case 120:
                    let n = try self.readRegs(at + 2, 3)
                    self.ratedW = Self.scaled(Int(n[1]), Self.sf(n[2]))
                case 123:
                    self.controlsAt = at
                    self.limitSF = Self.sf(try self.readRegs(at + 23, 1)[0])
                default: if Self.storageModels.contains(id) { storage = true }
                }
                at = at &+ 2 &+ len
            }
            guard self.inverterAt != nil else { throw InverterError.unsupported("This inverter's SunSpec map has no integer inverter model (101–103).") }
            guard self.controlsAt != nil else { throw InverterError.unsupported("This inverter does not offer SunSpec power limiting (model 123).") }
            if storage && !anyModel { throw InverterError.unsupported("\(self.model) reports a battery (hybrid inverter). Gridwise doesn't control hybrids: a power limit would also cut the battery, and Amber or your installer manages these.") }
        }.value
    }

    func read() async throws -> InverterState {
        try await Task.detached { () -> InverterState in
            guard let inv = self.inverterAt, let ctl = self.controlsAt else { throw InverterError.unsupported("not identified") }
            let w = try self.readRegs(inv + 14, 2)
            let c = try self.readRegs(ctl + 5, 5)                        // WMaxLimPct ... WMaxLim_Ena
            let output = Self.scaled(Int(Int16(bitPattern: w[0])), Self.sf(w[1]))
            let pct = Self.scaled(Int(c[0]), self.limitSF)
            return InverterState(outputW: output, limitPct: c[4] == 1 ? pct : nil)
        }.value
    }

    func setLimit(_ pct: Int) async throws {
        guard (1...100).contains(pct) else { throw InverterError.refused("limit \(pct)% is out of range") }
        try await Task.detached {
            guard let ctl = self.controlsAt else { throw InverterError.unsupported("not identified") }
            let raw = UInt16(Double(pct) / pow(10, Double(self.limitSF)))
            // limit, no window, revert time, no ramp, enabled
            try self.writeRegs(ctl + 5, [raw, 0, Self.revertSeconds, 0, 1])
            let back = try self.readRegs(ctl + 5, 5)
            if back[0] != raw || back[4] != 1 { throw InverterError.mismatch("wrote \(pct)%, it reads \(Self.scaled(Int(back[0]), self.limitSF))%, enabled \(back[4])") }
        }.value
    }

    func restore(to original: InverterState) async throws {
        try await Task.detached {
            guard let ctl = self.controlsAt else { throw InverterError.unsupported("not identified") }
            if let p = original.limitPct {
                let raw = UInt16(p / pow(10, Double(self.limitSF)))
                try self.writeRegs(ctl + 5, [raw, 0, 0, 0, 1])
            } else {
                try self.writeRegs(ctl + 9, [0])                         // WMaxLim_Ena: disabled
            }
        }.value
    }
}
