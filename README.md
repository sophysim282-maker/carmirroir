# CarScreen v4 — full screen mirroring

New in v4: the **BroadcastExtension** target is now built into the app, so you can
mirror your whole iPhone screen to the car browser. No VPN, no paid Apple account.

## How to use

1. Turn on Personal Hotspot, connect the car / Carlinkit T2C to it.
2. On the car browser open `http://172.20.10.1:8080`.
3. In the CarScreen app tap the round broadcast button → **Start Broadcast**
   (or Control Center → long-press Screen Recording → **CarScreen**).
4. Your whole screen appears on the car display (~5 fps JPEG over WebSocket).

The YouTube-link player and DLNA receiver from v3 still work as before.

## Build (GitHub Actions)

Upload this whole folder (including the hidden `.github`) to your private repo.
The workflow runs xcodegen + xcodebuild (unsigned) and produces `CarScreen.ipa`
in the Actions artifacts. Install with Sideloadly.

Note: Sideloadly may warn about the app extension — that is fine, it signs both
the app and the extension with your free Apple ID (7-day expiry, then reinstall).
