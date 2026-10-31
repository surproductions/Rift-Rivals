# RIFT RIVALS

**Two teams. One charged shard. Break their rift.**

RIFT RIVALS is an original, native iOS competitive arena game for **1v1, 2v2,
3v3 and 4v4 (up to 8 players)**, played over local Wi-Fi with **no servers, no
accounts and no cloud services**. Strike the shard with pulses to charge it,
shatter rivals with it, parry or dash through incoming shots, and drive it
into the enemy rift to score.

Under the hood: a deterministic fixed-point simulation at 60 Hz with
**rollback netcode**, an authoritative host that decides only the input
timeline, state checksums with automatic repair, reconnection, pause, and
**host migration**.

| Doc | What's inside |
|---|---|
| [docs/GAME_DESIGN.md](docs/GAME_DESIGN.md) | Concept, mechanics, arenas, why it works in local multiplayer |
| [docs/NETWORKING.md](docs/NETWORKING.md) | Architecture, sync, rollback, fairness, migration, future online play |
| [docs/NETWORK_TEST_RESULTS.md](docs/NETWORK_TEST_RESULTS.md) | Simulated latency/loss/jitter/failure matrix |
| [RELEASE_NOTES.md](RELEASE_NOTES.md) | Version history, known issues |

---

## Install on an iPhone

Each [GitHub Release](https://github.com/surproductions/Rift-Rivals/releases)
contains **`RiftRivals-vX.Y.Z-unsigned.ipa`**, built by GitHub Actions on
macOS.

> **Why "unsigned"?** iOS only runs apps signed with an Apple certificate
> and a provisioning profile that names the device. This project's CI has no
> Apple Developer account, so the IPA is a complete Release build that hasn't
> been signed yet. You sign it once with your own Apple ID or developer account
> using one of the options below. Nothing in the game needs special
> entitlements: no multicast entitlement, no iCloud, no push notifications.

### Option A — Sideloadly or AltStore (free Apple ID, no Mac needed for AltStore)
1. Download the `.ipa` from the latest release.
2. **Sideloadly** (Windows or macOS): connect the iPhone by USB, drag the IPA
   in, enter your Apple ID, and press *Start*. **AltStore**: install AltServer,
   then open the IPA from the AltStore app on the phone.
3. On the iPhone, open *Settings → General → VPN & Device Management* and
   trust your Apple ID's developer certificate.
4. On iOS 16+, enable *Settings → Privacy & Security → Developer Mode* (it
   asks to restart).

Free Apple IDs produce apps that expire after **7 days** (re-sign to refresh)
and allow 3 sideloaded apps at a time. A paid Apple Developer Program
membership ($99/yr) gives one-year profiles, Ad Hoc and TestFlight
distribution.

### Option B — Build from source with Xcode (recommended for developers)
1. Requirements: a Mac with **Xcode 15 or newer** (CI uses Xcode 16 on
   macOS 15), and an iPhone on **iOS 16+**.
2. `git clone https://github.com/surproductions/Rift-Rivals.git` and open
   **`RiftRivals.xcodeproj`**.
3. Select the *RiftRivals* target → *Signing & Capabilities* → pick your
   **Team** (a free personal team works) and, if needed, change the bundle
   identifier (default `com.surproductions.riftrivals`) to something unique.
4. Plug in the iPhone, select it as the run destination, and press **Run**.

### Option C — Re-sign the IPA with your developer certificate
```bash
unzip RiftRivals-v1.0.0-unsigned.ipa
cp ~/Downloads/YourProfile.mobileprovision Payload/RiftRivals.app/embedded.mobileprovision
codesign -f -s "Apple Development: Your Name (TEAMID)" --entitlements entitlements.plist Payload/RiftRivals.app
zip -qr RiftRivals-signed.ipa Payload
```
Then install with Apple Configurator, Xcode's *Devices* window, or
`xcrun devicectl device install app`. `entitlements.plist` only needs
`application-identifier` and `com.apple.developer.team-identifier` matching
your profile.

### First launch
iOS asks to **allow Rift Rivals to find devices on your local network**.
Tap *Allow* on every phone; otherwise rooms can't be discovered or joined. You
can change this later in *Settings → Privacy & Security → Local Network*.

---

## Playing a local match

1. All phones on the **same Wi-Fi** (or Wi-Fi and Bluetooth on, for Apple
   peer-to-peer), with Local Network access allowed.
2. One player taps **HOST LOCAL MATCH**. A room code such as `K7QX` appears.
3. Everyone else taps **JOIN NEARBY**. The room appears automatically; type
   the code to filter if several rooms are nearby.
4. Pick teams, tap **READY UP**. The host chooses the format, arena, round
   length, goal target, series length, bot difficulty and modifiers, then
   taps **START MATCH**. Empty slots are filled with bots (optional).

**Controls (landscape):** the left thumb moves (floating stick). The right
thumb uses **PULSE** (big button; tapping anywhere on the right half also
pulses) and **DASH** (small button). A left-handed layout and a fixed stick
are in Settings.

**Practice vs Bots** needs no network. **Settings** includes a colour-blind
palette, reduced motion, a larger HUD, haptics, screen shake, sound volume and
the **network diagnostics overlay**.

---

## Repository layout

```
Package.swift              SwiftPM package: RiftCore library, riftsim CLI, tests
Sources/RiftCore/
  Game/                    Fixed-point math, arenas, state, simulation, bots, codec
  Net/                     Transport abstraction, protocol, PeerLink, simulated network
  Session/                 Rollback engine, host/client/practice sessions, migration, testbed
Sources/riftsim/           Network test matrix CLI
Tests/RiftCoreTests/       48 XCTest cases (simulation, protocol, rollback, multiplayer)
App/RiftRivals/            iOS app (SwiftUI menus, SpriteKit renderer, touch controls,
                           Bonjour/UDP transport, synthesized audio, Info.plist, assets)
RiftRivals.xcodeproj       Xcode project (generated by tools/gen_xcodeproj.py)
tools/                     Project and artwork generators
.github/workflows/ios.yml  CI: tests (Linux + macOS), simulator launch test, IPA, release
docs/                      Design, networking, test results
```

## Building and testing

```bash
swift test                                   # engine + multiplayer tests (macOS or Linux)
swift run -c release riftsim --out docs/NETWORK_TEST_RESULTS.md   # network matrix
python3 tools/gen_xcodeproj.py               # regenerate the Xcode project after adding files
python3 tools/make_assets.py                 # regenerate the icon / launch artwork (Pillow)

# Unsigned device build + IPA, as CI does:
xcodebuild -project RiftRivals.xcodeproj -scheme RiftRivals -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -archivePath build/RiftRivals.xcarchive \
  archive CODE_SIGNING_ALLOWED=NO
mkdir Payload && cp -R build/RiftRivals.xcarchive/Products/Applications/RiftRivals.app Payload/
ditto -c -k --keepParent Payload RiftRivals-unsigned.ipa
```

CI (`.github/workflows/ios.yml`) runs on every push. It runs the engine tests
on Linux and macOS and the network matrix, builds for the iOS Simulator,
**installs and launches the app in the Simulator** (menu and a live bot match,
with screenshots), archives a Release build for devices, packages and
verifies the IPA (architecture, Info.plist keys, asset catalog), and on
`v*` tags publishes a GitHub Release with the IPA, its SHA-256, screenshots and
the network report.

## Requirements and permissions

* iOS 16.0+, iPhone (landscape), arm64.
* `NSLocalNetworkUsageDescription` and `NSBonjourServices = [_riftrivals._udp]`.
  No other permissions or entitlements are needed.

## License

All code, artwork and procedurally generated audio in this repository were
created for RIFT RIVALS.
