import Foundation
import Network

/// Advertises "CarScreen" as an AirPlay VIDEO receiver (no mirroring) on port 7000
/// and forwards /play /rate /scrub /stop to the car browser via WebServer.
final class AirPlayReceiver {
    static let shared = AirPlayReceiver()
    private var listener: NWListener?
    private let q = DispatchQueue(label: "airplay")
    private let deviceID = "58:55:CA:1A:E2:88"
    // Video (0x1) + Photo (0x2) + VideoFairPlay off + Slideshow (0x4)... 0x7 = video only, NO screen mirroring (0x80/0x200 off)
    private let features = "0x7"

    func start(name: String = "CarScreen") {
        let l = try! NWListener(using: .tcp, on: 7000)
        let txt: [String: String] = [
            "deviceid": deviceID, "features": features, "model": "AppleTV2,1",
            "srcvers": "220.68", "vv": "2", "flags": "0x4",
        ]
        l.service = NWListener.Service(name: name, type: "_airplay._tcp",
                                       txtRecord: NWTXTRecord(txt).data)
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.q)
            self.read(c, buffer: Data())
        }
        l.stateUpdateHandler = { print("AirPlay listener:", $0) }
        l.start(queue: q)
        listener = l
    }

    // MARK: HTTP parsing (keep-alive, multiple requests per connection)
    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            while let req = HTTPRequest.parse(&buf) { self.handle(req, c) }
            if done || err != nil { c.cancel() } else { self.read(c, buffer: buf) }
        }
    }

    private func handle(_ r: HTTPRequest, _ c: NWConnection) {
        print("AirPlay ←", r.method, r.path)
        let ws = WebServer.shared
        switch (r.method, r.path.split(separator: "?").first.map(String.init) ?? r.path) {
        case ("GET", "/server-info"):
            reply(c, plist: ["deviceid": deviceID, "features": 0x7, "model": "AppleTV2,1",
                             "protovers": "1.0", "srcvers": "220.68"])
        case ("POST", "/reverse"):
            c.send(content: Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: PTTH/1.0\r\nConnection: Upgrade\r\n\r\n".utf8),
                   completion: .idempotent)
        case ("POST", "/play"):
            let (url, pos) = parsePlay(r)
            if let url { ws.send(json: ["type": "play", "url": url, "position": pos]) }
            reply(c)
        case ("POST", "/rate"):
            let v = Double(query(r.path, "value") ?? "1") ?? 1
            ws.send(json: ["type": "rate", "value": v]); reply(c)
        case ("POST", "/scrub"):
            let p = Double(query(r.path, "position") ?? "0") ?? 0
            ws.send(json: ["type": "scrub", "position": p]); reply(c)
        case ("GET", "/scrub"):
            let s = ws.lastState
            reply(c, text: "duration: \(s["duration"] ?? 0)\nposition: \(s["position"] ?? 0)", type: "text/parameters")
        case ("POST", "/volume"):
            ws.send(json: ["type": "volume", "value": Double(query(r.path, "volume") ?? "1") ?? 1]); reply(c)
        case ("POST", "/stop"):
            ws.send(json: ["type": "stop"]); reply(c)
        case ("GET", "/playback-info"):
            let s = ws.lastState
            reply(c, plist: ["duration": s["duration"] ?? 0, "position": s["position"] ?? 0,
                             "rate": s["rate"] ?? 0, "readyToPlay": true, "playbackBufferEmpty": false,
                             "playbackBufferFull": true, "playbackLikelyToKeepUp": true,
                             "loadedTimeRanges": [["start": 0.0, "duration": s["duration"] ?? 0]],
                             "seekableTimeRanges": [["start": 0.0, "duration": s["duration"] ?? 0]]])
        default:
            reply(c) // /photo, /slideshow-features, /action etc: accept silently
        }
    }

    /// /play body is either text/parameters ("Content-Location: …\nStart-Position: 0.0") or a binary plist.
    private func parsePlay(_ r: HTTPRequest) -> (String?, Double) {
        if let pl = try? PropertyListSerialization.propertyList(from: r.body, format: nil) as? [String: Any] {
            let url = pl["Content-Location"] as? String
            let start = pl["Start-Position-Seconds"] as? Double ?? 0
            return (url, start)
        }
        var url: String?; var pos = 0.0
        for line in String(decoding: r.body, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "Content-Location" { url = parts[1] }
            if parts[0] == "Start-Position" { pos = Double(parts[1]) ?? 0 }
        }
        return (url, pos) // Start-Position is a 0..1 fraction; the page treats small values fine.
    }

    private func query(_ path: String, _ key: String) -> String? {
        URLComponents(string: "http://x" + path)?.queryItems?.first { $0.name == key }?.value
    }

    private func reply(_ c: NWConnection, text: String = "", type: String = "text/plain") {
        send(c, Data(text.utf8), type: type)
    }
    private func reply(_ c: NWConnection, plist: [String: Any]) {
        let d = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
        send(c, d, type: "text/x-apple-plist+xml")
    }
    private func send(_ c: NWConnection, _ body: Data, type: String) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .idempotent)
    }
}

struct HTTPRequest {
    let method: String, path: String, headers: [String: String], body: Data

    static func parse(_ buf: inout Data) -> HTTPRequest? {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { buf.removeAll(); return nil }
        var h: [String: String] = [:]
        for l in lines { let p = l.split(separator: ":", maxSplits: 1); if p.count == 2 { h[p[0].lowercased()] = p[1].trimmingCharacters(in: .whitespaces) } }
        let len = Int(h["content-length"] ?? "0") ?? 0
        guard buf.count - (end.upperBound - buf.startIndex) >= len else { return nil }
        let body = buf[end.upperBound..<(end.upperBound + len)]
        buf = Data(buf[(end.upperBound + len)...])
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: h, body: Data(body))
    }
}
