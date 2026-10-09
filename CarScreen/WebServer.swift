import Foundation
import Network

/// Port 8080 serves car-player.html; port 8090 is the WebSocket.
final class WebServer {
    static let shared = WebServer()
    private var listener: NWListener?
    private var sockets: [NWConnection] = []
    private let q = DispatchQueue(label: "web")
    var lastState: [String: Double] = ["position": 0, "duration": 0, "rate": 0]

    func start() {
        // HTTP page on 8080, WebSocket on 8090 (NWProtocolWebSocket needs its own listener).
        startHTTP()
        startWS()
    }

    private func startHTTP() {
        let l = try! NWListener(using: .tcp, on: 8080)
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: self!.q)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let url = Bundle.main.url(forResource: "car-player", withExtension: "html")!
                var html = (try? String(contentsOf: url)) ?? "missing page"
                html = html.replacingOccurrences(of: "'ws://'+location.host+'/ws'",
                                                 with: "'ws://'+location.hostname+':8090/'")
                let body = Data(html.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
            }
        }
        l.start(queue: q)
        listener = l
    }

    private var wsListener: NWListener?
    private func startWS() {
        let p = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        p.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let l = try! NWListener(using: p, on: 8090)
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.q)
            self.sockets.append(c)
            self.receive(c)
        }
        l.start(queue: q)
        wsListener = l
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            if let data {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   obj["type"] as? String == "state" {
                    for k in ["position", "duration", "rate"] { self.lastState[k] = obj[k] as? Double ?? 0 }
                } else {
                    // Binary screen frame from the BroadcastExtension — relay to
                    // every other socket (the car browsers).
                    self.broadcast(data, opcode: .binary, except: c)
                }
            }
            if err == nil { self.receive(c) } else { self.sockets.removeAll { $0 === c } }
        }
    }

    func send(json: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: json) else { return }
        broadcast(d, opcode: .text)
    }

    func send(jpeg: Data) { broadcast(jpeg, opcode: .binary) }

    private func broadcast(_ d: Data, opcode: NWProtocolWebSocket.Opcode, except: NWConnection? = nil) {
        q.async {
            let meta = NWProtocolWebSocket.Metadata(opcode: opcode)
            let ctx = NWConnection.ContentContext(identifier: "m", metadata: [meta])
            for s in self.sockets where s !== except {
                s.send(content: d, contentContext: ctx, isComplete: true, completion: .idempotent)
            }
        }
    }
}
