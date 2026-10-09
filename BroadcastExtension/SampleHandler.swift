import ReplayKit
import Network
import UIKit

/// ReplayKit broadcast upload extension: captures the whole iPhone screen and
/// streams JPEG frames over WebSocket to the CarScreen app's own server
/// (127.0.0.1:8090), which relays them to the car browser.
///
/// No App Group or special entitlement is needed: the extension talks to the
/// main app over loopback, so it works with a free Apple ID.
final class SampleHandler: RPBroadcastSampleHandler {
    private var conn: NWConnection?
    private let q = DispatchQueue(label: "cast")
    private var lastFrame = CFAbsoluteTimeGetCurrent()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let host = NWEndpoint.Host("127.0.0.1")
        let p = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        p.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let c = NWConnection(host: host, port: 8090, using: p)
        c.start(queue: q)
        conn = c
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let conn else { return }
        // ~5 fps is plenty for a car screen and keeps hotspot bandwidth low.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFrame > 0.2 else { return }
        lastFrame = now
        guard let buf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let img = UIImage(ciImage: CIImage(cvPixelBuffer: buf))
        guard let jpeg = img.jpegData(compressionQuality: 0.4) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "f", metadata: [meta])
        conn.send(content: jpeg, contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    override func broadcastFinished() { conn?.cancel(); conn = nil }
}
