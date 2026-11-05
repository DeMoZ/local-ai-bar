import Foundation
import Darwin

struct FoundHost: Identifiable, Hashable {
    var id: String { ip }
    var ip: String
    var name: String?
    var display: String { name ?? ip }
    /// What to save as the host: the .local name if we got one (survives DHCP changes), else the IP.
    var address: String { name ?? ip }
}

/// Finds machines in the local IPv4 subnets that answer like the control service on `port`.
enum Discovery {
    static func scan(port: Int, progress: @escaping @Sendable (Double) -> Void) async -> [FoundHost] {
        let candidates = localCandidates()
        guard !candidates.isEmpty else { return [] }
        let session: URLSession = {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 1.2
            c.timeoutIntervalForResource = 2
            return URLSession(configuration: c)
        }()
        var found: [FoundHost] = []
        var done = 0
        let maxParallel = 64
        await withTaskGroup(of: String?.self) { group in
            var it = candidates.makeIterator()
            for _ in 0..<maxParallel {
                guard let ip = it.next() else { break }
                group.addTask { await probe(ip: ip, port: port, session: session) ? ip : nil }
            }
            while let result = await group.next() {
                done += 1
                progress(Double(done) / Double(candidates.count))
                if let ip = result { found.append(FoundHost(ip: ip, name: nil)) }
                if let ip = it.next() {
                    group.addTask { await probe(ip: ip, port: port, session: session) ? ip : nil }
                }
            }
        }
        for i in found.indices { found[i].name = hostName(for: found[i].ip) }
        return found.sorted { $0.ip.compare($1.ip, options: .numeric) == .orderedAscending }
    }

    /// The control service answers `/status` with 200 `{"status":…}` or 401 `{"error":…}`.
    private static func probe(ip: String, port: Int, session: URLSession) async -> Bool {
        guard let url = URL(string: "http://\(ip):\(port)/status"),
              let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse,
              [200, 401, 403].contains(http.statusCode),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return obj["status"] != nil || obj["error"] != nil
    }

    /// All host addresses of the Mac's active IPv4 subnets (capped to a /24 around our own IP).
    static func localCandidates() -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.ifa_netmask else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if m < 0xFFFF_FF00 { m = 0xFFFF_FF00 }  // never scan more than 254 hosts per interface
            let net = ip & m
            let bcast = net | ~m
            guard bcast > net + 1 else { continue }
            for h in (net + 1)..<bcast where h != ip {
                let s = "\(h >> 24).\((h >> 16) & 255).\((h >> 8) & 255).\(h & 255)"
                if seen.insert(s).inserted { result.append(s) }
            }
        }
        return result
    }

    /// A stable `.local` name for the IP: reverse DNS/mDNS first, then the NetBIOS name (Windows PCs),
    /// kept only if `<name>.local` resolves back to the same IP.
    static func hostName(for ip: String) -> String? {
        if let n = reverseName(ip) { return n.hasSuffix(".") ? String(n.dropLast()) : n }
        guard let nb = netbiosName(ip) else { return nil }
        let local = nb.lowercased() + ".local"
        return resolves(local, to: ip) ? local : nil
    }

    private static func netbiosName(_ ip: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/smbutil")
        p.arguments = ["status", ip]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") where line.hasPrefix("Server:") {
            let name = line.dropFirst("Server:".count).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return nil
    }

    private static func resolves(_ name: String, to ip: String) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(res) }
        for ai in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let sa = ai.pointee.ai_addr else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                var a = p.pointee.sin_addr
                _ = inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
            }
            if String(cString: buf) == ip { return true }
        }
        return false
    }

    /// Reverse lookup (works through mDNS for most LAN machines, e.g. `name.local`).
    static func reverseName(_ ip: String) -> String? {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &sa.sin_addr) == 1 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        let name = String(cString: buf)
        return name.isEmpty || name == ip ? nil : name
    }
}
