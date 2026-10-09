import SwiftUI
import AVFoundation
import ReplayKit

@main
struct CarScreenApp: App {
    init() {
        // Silent audio session keeps the app alive in the background (UIBackgroundModes: audio).
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        KeepAlive.shared.start()
        WebServer.shared.start()
        AirPlayReceiver.shared.start()
    }
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("CarScreen is running").font(.title).bold()
            Text("1. Turn on Personal Hotspot and connect the car / T2C to it")
            Text("2. On the car browser open http://172.20.10.1:8080")
            Divider()
            Text("Mirror your whole screen:").font(.headline)
            BroadcastPicker()
                .frame(width: 60, height: 60)
            Text("Tap the button above, choose CarScreen, then Start Broadcast.\n(Or: Control Center → long-press Screen Recording → CarScreen)")
                .font(.footnote)
        }.padding().multilineTextAlignment(.center)
    }
}

/// System broadcast picker — tapping it starts the screen broadcast to our
/// BroadcastExtension, which streams the screen to the car browser.
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let p = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        p.preferredExtension = "com.personal.carscreen.BroadcastExtension"
        p.showsMicrophoneButton = false
        return p
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// Plays silence in a loop so iOS doesn't suspend the servers.
final class KeepAlive {
    static let shared = KeepAlive()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    func start() {
        let fmt = engine.mainMixerNode.outputFormat(forBus: 0)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096) else { return }
        buf.frameLength = 4096
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        try? engine.start()
        player.scheduleBuffer(buf, at: nil, options: .loops)
        player.play()
    }
}
