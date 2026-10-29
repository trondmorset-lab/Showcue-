import Foundation
import Darwin

// MARK: - Argumenter og meldinger

enum OscArg: Equatable, CustomStringConvertible {
    case int(Int32)
    case float(Float)
    case string(String)
    case bool(Bool)
    case int64(Int64)
    case double(Double)
    case char(Character)
    case blob(Data)
    case none

    var description: String {
        switch self {
        case .int(let i): return String(i)
        case .float(let f): return Osc.trimmed(Double(f))
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .int64(let i): return String(i)
        case .double(let d): return Osc.trimmed(d)
        case .char(let c): return String(c)
        case .blob(let d): return "<\(d.count) byte>"
        case .none: return "nil"
        }
    }

    /// Argumentet som tekst (for cuenummer o.l.).
    var text: String { description }

    /// 0, 0.0 og false regnes som «av» (knapp sluppet).
    var isOff: Bool {
        switch self {
        case .int(let i): return i == 0
        case .float(let f): return f == 0
        case .int64(let i): return i == 0
        case .double(let d): return d == 0
        case .bool(let b): return !b
        default: return false
        }
    }

    var isString: Bool { if case .string = self { return true }; return false }
}

struct OscMessage: Equatable, CustomStringConvertible {
    var address: String
    var args: [OscArg]

    var description: String { args.isEmpty ? address : address + " " + args.map(\.description).joined(separator: " ") }
}

// MARK: - Koding / dekoding (OSC 1.0)

enum Osc {
    static func trimmed(_ d: Double) -> String {
        var s = String(format: "%.3f", d)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Tolker tekst fra en OSC-cue: 1 = heltall, 0.5 = flyttall, true/false, "tekst med mellomrom", ellers tekst.
    static func parseArguments(_ text: String) -> [OscArg] {
        var result: [OscArg] = []
        var current = ""
        var inQuotes = false, wasQuoted = false
        func flush() {
            if !current.isEmpty || wasQuoted {
                if wasQuoted { result.append(.string(current)) }
                else if let i = Int32(current) { result.append(.int(i)) }
                else if let f = Float(current.replacingOccurrences(of: ",", with: ".")) { result.append(.float(f)) }
                else if current.lowercased() == "true" { result.append(.bool(true)) }
                else if current.lowercased() == "false" { result.append(.bool(false)) }
                else { result.append(.string(current)) }
            }
            current = ""; wasQuoted = false
        }
        for ch in text {
            if ch == "\"" { inQuotes.toggle(); wasQuoted = true; continue }
            if ch.isWhitespace && !inQuotes { flush(); continue }
            current.append(ch)
        }
        flush()
        return result
    }

    static func encode(_ address: String, _ args: [OscArg]) -> Data {
        var d = Data()
        writeString(&d, address)
        var tags = ","
        for a in args {
            switch a {
            case .int: tags += "i"
            case .float: tags += "f"
            case .string: tags += "s"
            case .bool(let b): tags += b ? "T" : "F"
            case .int64: tags += "h"
            case .double: tags += "d"
            case .char: tags += "c"
            case .blob: tags += "b"
            case .none: tags += "N"
            }
        }
        writeString(&d, tags)
        for a in args {
            switch a {
            case .int(let i): writeBE(&d, UInt32(bitPattern: i))
            case .float(let f): writeBE(&d, f.bitPattern)
            case .string(let s): writeString(&d, s)
            case .int64(let i): writeBE64(&d, UInt64(bitPattern: i))
            case .double(let x): writeBE64(&d, x.bitPattern)
            case .char(let c): writeBE(&d, UInt32(c.unicodeScalars.first?.value ?? 0))
            case .blob(let b):
                writeBE(&d, UInt32(b.count)); d.append(b)
                while d.count % 4 != 0 { d.append(0) }
            case .bool, .none: break
            }
        }
        return d
    }

    private static func writeString(_ d: inout Data, _ s: String) {
        d.append(contentsOf: Array(s.utf8))
        let pad = 4 - (s.utf8.count % 4) // alltid minst én null-byte
        d.append(contentsOf: [UInt8](repeating: 0, count: pad))
    }
    private static func writeBE(_ d: inout Data, _ v: UInt32) {
        d.append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
    private static func writeBE64(_ d: inout Data, _ v: UInt64) {
        writeBE(&d, UInt32(v >> 32)); writeBE(&d, UInt32(v & 0xFFFF_FFFF))
    }

    /// Pakker ut én UDP-pakke (støtter #bundle, også nøstet).
    static func decode(_ data: Data) -> [OscMessage] {
        let bytes = [UInt8](data)
        var out: [OscMessage] = []
        decode(bytes, 0, bytes.count, &out, 0)
        return out
    }

    private static func decode(_ d: [UInt8], _ start: Int, _ length: Int, _ out: inout [OscMessage], _ depth: Int) {
        guard length >= 4, depth <= 8, start + length <= d.count else { return }
        let end = start + length
        if d[start] == UInt8(ascii: "#") {
            var p = start
            guard readString(d, &p, end) == "#bundle" else { return }
            p += 8 // tidsstempel – alt utføres med en gang
            while p + 4 <= end {
                let size = Int(readInt(d, &p, end))
                if size <= 0 || p + size > end { break }
                decode(d, p, size, &out, depth + 1)
                p += size
            }
            return
        }
        guard d[start] == UInt8(ascii: "/") else { return }
        var pos = start
        let address = readString(d, &pos, end)
        var args: [OscArg] = []
        if pos < end && d[pos] == UInt8(ascii: ",") {
            let tags = readString(d, &pos, end)
            for t in tags.dropFirst() {
                let before = args.count
                switch t {
                case "i": args.append(.int(readInt(d, &pos, end)))
                case "f": args.append(.float(Float(bitPattern: UInt32(bitPattern: readInt(d, &pos, end)))))
                case "h":
                    let hi = UInt64(UInt32(bitPattern: readInt(d, &pos, end))), lo = UInt64(UInt32(bitPattern: readInt(d, &pos, end)))
                    args.append(.int64(Int64(bitPattern: hi << 32 | lo)))
                case "d":
                    let hi = UInt64(UInt32(bitPattern: readInt(d, &pos, end))), lo = UInt64(UInt32(bitPattern: readInt(d, &pos, end)))
                    args.append(.double(Double(bitPattern: hi << 32 | lo)))
                case "s", "S": args.append(.string(readString(d, &pos, end)))
                case "b":
                    let n = Int(readInt(d, &pos, end))
                    if n >= 0 && pos + n <= end { args.append(.blob(Data(d[pos..<(pos + n)]))) }
                    pos += (n + 3) & ~3
                case "T": args.append(.bool(true))
                case "F": args.append(.bool(false))
                case "N", "I": break
                case "t": pos += 8
                case "c": args.append(.char(Character(UnicodeScalar(UInt32(bitPattern: readInt(d, &pos, end))) ?? " ")))
                case "r", "m": pos += 4
                default: pos = end // ukjent type: stopp
                }
                if pos > end { if args.count > before { args.removeLast() }; break }
            }
        }
        out.append(OscMessage(address: address, args: args))
    }

    private static func readInt(_ d: [UInt8], _ p: inout Int, _ end: Int) -> Int32 {
        guard p + 4 <= end else { p += 4; return 0 }
        let v = UInt32(d[p]) << 24 | UInt32(d[p + 1]) << 16 | UInt32(d[p + 2]) << 8 | UInt32(d[p + 3])
        p += 4
        return Int32(bitPattern: v)
    }

    private static func readString(_ d: [UInt8], _ p: inout Int, _ end: Int) -> String {
        let s = p
        while p < end && d[p] != 0 { p += 1 }
        let str = String(decoding: d[s..<p], as: UTF8.self)
        p = s + ((p - s) / 4 + 1) * 4
        return str
    }
}

// MARK: - UDP

enum UDP {
    /// Lager en IPv4-adresse fra IP eller vertsnavn. nil hvis det ikke går.
    static func resolve(_ host: String, _ port: Int) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) == 1 { return addr }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        guard let sa = first.pointee.ai_addr else { return nil }
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr.sin_addr = $0.pointee.sin_addr }
        return addr
    }

    static func ipString(_ addr: sockaddr_in) -> String {
        var a = addr.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    /// Maskinens IPv4-adresser (for å vise hva Companion/lysbord skal sende til).
    static func localAddresses() -> [String] {
        var result: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            if let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipString($0.pointee) }
                if !result.contains(ip) { result.append(ip) }
            }
            p = cur.pointee.ifa_next
        }
        return result
    }
}

/// Sender OSC over UDP (én felles socket, trådsikker).
final class OscSender {
    static let shared = OscSender()
    private let fd: Int32
    private let lock = NSLock()
    private var cache: [String: sockaddr_in] = [:]

    init() {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
    }

    deinit { if fd >= 0 { close(fd) } }

    @discardableResult
    func send(host: String, port: Int, address: String, args: [OscArg]) -> Bool {
        guard fd >= 0 else { return false }
        let packet = Osc.encode(address, args)
        lock.lock(); defer { lock.unlock() }
        let key = "\(host):\(port)"
        var addr: sockaddr_in
        if let a = cache[key] { addr = a } else {
            guard let a = UDP.resolve(host, port) else { return false }
            cache[key] = a; addr = a
        }
        let sent = packet.withUnsafeBytes { buf -> Int in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == packet.count
    }
}

/// Lytter etter OSC på en UDP-port. Meldinger leveres på `queue` (standard: hovedtråden).
final class OscServer {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private(set) var port = 0
    var queue: DispatchQueue = .main
    var onMessage: ((OscMessage, String) -> Void)?

    var isRunning: Bool { source != nil }

    func start(port: Int) throws {
        stop()
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { throw NSError(domain: "OSC", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Kunne ikke lage socket"]) }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let err = errno
            close(s)
            throw NSError(domain: "OSC", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Port \(port) er opptatt eller utilgjengelig"])
        }
        fd = s
        self.port = port
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: DispatchQueue(label: "showcue.osc.in"))
        src.setEventHandler { [weak self] in self?.readPacket() }
        src.setCancelHandler { close(s) }
        source = src
        src.resume()
    }

    private func readPacket() {
        let size = 65536
        var buf = [UInt8](repeating: 0, count: size)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let socketFd = fd
        let n = withUnsafeMutablePointer(to: &from) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                buf.withUnsafeMutableBytes { raw in recvfrom(socketFd, raw.baseAddress, size, 0, sa, &len) }
            }
        }
        guard n > 0 else { return }
        let msgs = Osc.decode(Data(buf[0..<n]))
        let ip = UDP.ipString(from)
        guard !msgs.isEmpty else { return }
        queue.async { [weak self] in msgs.forEach { self?.onMessage?($0, ip) } }
    }

    func stop() {
        source?.cancel() // lukker socketen
        source = nil
        fd = -1
    }

    deinit { stop() }
}
