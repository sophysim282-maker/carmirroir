import Foundation
import Network
import Darwin

/// DLNA / UPnP MediaRenderer named "CarScreen" (same idea as APTV).
/// - UDP 1900: answers SSDP M-SEARCH and sends NOTIFY alive packets.
/// - TCP 49152: device description XML + AVTransport SOAP control.
/// Video links received via SetAVTransportURI are forwarded to the car browser.
final class DLNAServer {
    static let shared = DLNAServer()
    let port: UInt16 = 49152
    let uuid = "uuid:6c6f7661-626c-6543-6172-53637265656e"
    private var http: NWListener?
    private let q = DispatchQueue(label: "dlna")
    private var sock: Int32 = -1
    private var currentURI = ""
    private var state = "NO_MEDIA_PRESENT"

    func start() {
        startHTTP()
        q.async { self.startSSDP() }
        // Re-announce every 30s so senders keep seeing us.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.q.async { self?.notifyAlive() } }
    }

    // MARK: SSDP (UDP 1900)
    private func startSSDP() {
        sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { print("DLNA: socket failed"); return }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let b = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if b != 0 { print("DLNA: bind 1900 failed", errno) }
        // Join the SSDP group on every IPv4 interface (Wi-Fi, Hotspot bridge, loopback).
        for ip in DLNAServer.localIPv4s() + ["127.0.0.1"] {
            var mreq = ip_mreq()
            mreq.imr_multiaddr.s_addr = inet_addr("239.255.255.250")
            mreq.imr_interface.s_addr = inet_addr(ip)
            let r = setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))
            print("DLNA: join on", ip, r == 0 ? "ok" : "failed \(errno)")
        }
        var loop: UInt8 = 1
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, socklen_t(MemoryLayout<UInt8>.size))
        notifyAlive()

        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(sock, &buf, buf.count, 0, $0, &len) } }
            if n <= 0 { continue }
            let msg = String(decoding: buf[0..<n], as: UTF8.self)
            guard msg.hasPrefix("M-SEARCH") else { continue }
            let st = header(msg, "ST") ?? "ssdp:all"
            let wanted = ["ssdp:all", "upnp:rootdevice", "urn:schemas-upnp-org:device:MediaRenderer:1",
                          "urn:schemas-upnp-org:service:AVTransport:1", uuid]
            guard wanted.contains(st) else { continue }
            let fromIP = String(cString: inet_ntoa(from.sin_addr))
            let myIP = DLNAServer.bestIP(for: fromIP)
            let reply = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nEXT:\r\nLOCATION: http://\(myIP):\(port)/description.xml\r\nSERVER: iOS/17 UPnP/1.0 CarScreen/1.0\r\nST: \(st == "ssdp:all" ? "urn:schemas-upnp-org:device:MediaRenderer:1" : st)\r\nUSN: \(uuid)::urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
            let d = Array(reply.utf8)
            _ = withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sock, d, d.count, 0, $0, len) } }
        }
    }

    private func notifyAlive() {
        guard sock >= 0 else { return }
        var to = sockaddr_in()
        to.sin_family = sa_family_t(AF_INET)
        to.sin_port = in_port_t(1900).bigEndian
        to.sin_addr.s_addr = inet_addr("239.255.255.250")
        for ip in DLNAServer.localIPv4s() {
            var iface = in_addr(); iface.s_addr = inet_addr(ip)
            setsockopt(sock, IPPROTO_IP, IP_MULTICAST_IF, &iface, socklen_t(MemoryLayout<in_addr>.size))
            for nt in ["upnp:rootdevice", "urn:schemas-upnp-org:device:MediaRenderer:1", "urn:schemas-upnp-org:service:AVTransport:1"] {
                let m = "NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://\(ip):\(port)/description.xml\r\nNT: \(nt)\r\nNTS: ssdp:alive\r\nSERVER: iOS/17 UPnP/1.0 CarScreen/1.0\r\nUSN: \(uuid)::\(nt)\r\n\r\n"
                let d = Array(m.utf8)
                _ = withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sock, d, d.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            }
        }
    }

    // MARK: HTTP (description + SOAP)
    private func startHTTP() {
        guard let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!) else { return }
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.q)
            self.read(c, Data())
        }
        l.start(queue: q)
        http = l
    }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            while let r = HTTPRequest.parse(&buf) { self.handle(r, c) }
            if done || err != nil { c.cancel() } else { self.read(c, buf) }
        }
    }

    private func handle(_ r: HTTPRequest, _ c: NWConnection) {
        print("DLNA ←", r.method, r.path, r.headers["soapaction"] ?? "")
        switch r.path {
        case "/description.xml": send(c, descriptionXML)
        case "/AVTransport.xml": send(c, avtSCPD)
        case "/RenderingControl.xml", "/ConnectionManager.xml": send(c, emptySCPD)
        case "/AVTransport/control": avTransport(r, c)
        case "/RenderingControl/control", "/ConnectionManager/control":
            let action = soapAction(r)
            send(c, soap(action, r.path.contains("Rendering") ? "RenderingControl" : "ConnectionManager",
                         action == "GetVolume" ? "<CurrentVolume>50</CurrentVolume>" :
                         action == "GetProtocolInfo" ? "<Source></Source><Sink>http-get:*:*:*</Sink>" : ""))
        default:
            if r.method == "SUBSCRIBE" {
                let h = "HTTP/1.1 200 OK\r\nSID: uuid:carscreen-sub\r\nTIMEOUT: Second-1800\r\nContent-Length: 0\r\n\r\n"
                c.send(content: Data(h.utf8), completion: .idempotent)
            } else { send(c, "", status: "404 Not Found") }
        }
    }

    private func avTransport(_ r: HTTPRequest, _ c: NWConnection) {
        let ws = WebServer.shared
        let body = String(decoding: r.body, as: UTF8.self)
        let action = soapAction(r)
        var out = ""
        switch action {
        case "SetAVTransportURI":
            currentURI = xmlValue(body, "CurrentURI").map(unescape) ?? ""
            state = "STOPPED"
            // Most senders call Play next; start immediately like APTV.
            if !currentURI.isEmpty { ws.send(json: ["type": "play", "url": currentURI, "position": 0]); state = "PLAYING" }
        case "Play": ws.send(json: ["type": "rate", "value": 1]); state = "PLAYING"
        case "Pause": ws.send(json: ["type": "rate", "value": 0]); state = "PAUSED_PLAYBACK"
        case "Stop": ws.send(json: ["type": "stop"]); state = "STOPPED"
        case "Seek":
            if let t = xmlValue(body, "Target") { ws.send(json: ["type": "scrub", "position": seconds(t)]) }
        case "GetTransportInfo":
            out = "<CurrentTransportState>\(state)</CurrentTransportState><CurrentTransportStatus>OK</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>"
        case "GetPositionInfo":
            let s = ws.lastState
            out = "<Track>1</Track><TrackDuration>\(hms(s["duration"] ?? 0))</TrackDuration><TrackMetaData></TrackMetaData><TrackURI>\(escape(currentURI))</TrackURI><RelTime>\(hms(s["position"] ?? 0))</RelTime><AbsTime>\(hms(s["position"] ?? 0))</AbsTime><RelCount>2147483647</RelCount><AbsCount>2147483647</AbsCount>"
        case "GetMediaInfo":
            out = "<NrTracks>1</NrTracks><MediaDuration>\(hms(ws.lastState["duration"] ?? 0))</MediaDuration><CurrentURI>\(escape(currentURI))</CurrentURI><CurrentURIMetaData></CurrentURIMetaData><NextURI></NextURI><NextURIMetaData></NextURIMetaData><PlayMedium>NETWORK</PlayMedium><RecordMedium>NOT_IMPLEMENTED</RecordMedium><WriteStatus>NOT_IMPLEMENTED</WriteStatus>"
        case "GetTransportSettings": out = "<PlayMode>NORMAL</PlayMode><RecQualityMode>NOT_IMPLEMENTED</RecQualityMode>"
        case "GetCurrentTransportActions": out = "<Actions>Play,Pause,Stop,Seek</Actions>"
        default: break
        }
        send(c, soap(action, "AVTransport", out))
    }

    // MARK: helpers
    private func soapAction(_ r: HTTPRequest) -> String {
        let a = r.headers["soapaction"]?.replacingOccurrences(of: "\"", with: "") ?? ""
        return a.split(separator: "#").last.map(String.init) ?? ""
    }
    private func soap(_ action: String, _ svc: String, _ inner: String) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:\(svc):1\">\(inner)</u:\(action)Response></s:Body></s:Envelope>"
    }
    private func send(_ c: NWConnection, _ body: String, status: String = "200 OK") {
        let d = Data(body.utf8)
        let h = "HTTP/1.1 \(status)\r\nContent-Type: text/xml; charset=\"utf-8\"\r\nContent-Length: \(d.count)\r\nServer: iOS/17 UPnP/1.0 CarScreen/1.0\r\n\r\n"
        c.send(content: Data(h.utf8) + d, completion: .idempotent)
    }
    private func header(_ msg: String, _ key: String) -> String? {
        for line in msg.components(separatedBy: "\r\n") {
            let p = line.split(separator: ":", maxSplits: 1)
            if p.count == 2, p[0].trimmingCharacters(in: .whitespaces).uppercased() == key { return p[1].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
    private func xmlValue(_ s: String, _ tag: String) -> String? {
        guard let a = s.range(of: "<\(tag)>") ?? s.range(of: "<\(tag) "),
              let gt = s[a.lowerBound...].firstIndex(of: ">"),
              let b = s.range(of: "</\(tag)>", range: gt..<s.endIndex) else { return nil }
        return String(s[s.index(after: gt)..<b.lowerBound])
    }
    private func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
    }
    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    private func seconds(_ t: String) -> Double {
        let p = t.split(separator: ":").compactMap { Double($0) }
        return p.reduce(0) { $0 * 60 + $1 }
    }
    private func hms(_ s: Double) -> String {
        let t = Int(max(0, s)); return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    static func localIPv4s() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            out.append(String(cString: host))
        }
        return out
    }
    /// Pick our address on the same subnet as the sender (or loopback for apps on this phone).
    static func bestIP(for from: String) -> String {
        if from.hasPrefix("127.") { return "127.0.0.1" }
        let pre = from.split(separator: ".").prefix(3).joined(separator: ".")
        return localIPv4s().first { $0.hasPrefix(pre) } ?? localIPv4s().first ?? "127.0.0.1"
    }

    private var descriptionXML: String { """
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>
    <device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>CarScreen</friendlyName><manufacturer>Personal</manufacturer><modelName>CarScreen</modelName>
    <modelNumber>1</modelNumber><UDN>\(uuid)</UDN>
    <serviceList>
    <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><serviceId>urn:upnp-org:serviceId:AVTransport</serviceId><SCPDURL>/AVTransport.xml</SCPDURL><controlURL>/AVTransport/control</controlURL><eventSubURL>/AVTransport/event</eventSubURL></service>
    <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId><SCPDURL>/RenderingControl.xml</SCPDURL><controlURL>/RenderingControl/control</controlURL><eventSubURL>/RenderingControl/event</eventSubURL></service>
    <service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId><SCPDURL>/ConnectionManager.xml</SCPDURL><controlURL>/ConnectionManager/control</controlURL><eventSubURL>/ConnectionManager/event</eventSubURL></service>
    </serviceList></device></root>
    """ }

    private var avtSCPD: String {
        let actions = ["SetAVTransportURI", "Play", "Pause", "Stop", "Seek", "GetTransportInfo", "GetPositionInfo", "GetMediaInfo"]
        return "<?xml version=\"1.0\"?><scpd xmlns=\"urn:schemas-upnp-org:service-1-0\"><specVersion><major>1</major><minor>0</minor></specVersion><actionList>"
            + actions.map { "<action><name>\($0)</name></action>" }.joined()
            + "</actionList><serviceStateTable></serviceStateTable></scpd>"
    }
    private let emptySCPD = "<?xml version=\"1.0\"?><scpd xmlns=\"urn:schemas-upnp-org:service-1-0\"><specVersion><major>1</major><minor>0</minor></specVersion><actionList></actionList><serviceStateTable></serviceStateTable></scpd>"
}
