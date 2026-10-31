# RIFT RIVALS — Release Notes

## v1.0.1

* Fix: the connection indicator showed a red dot in offline Practice; it now
  shows a neutral "Local" badge.
* Release assets now include in-game screenshots captured from the iOS
  Simulator by CI.

## v1.0.0 — first release

The first complete build of RIFT RIVALS, an original local-multiplayer arena
game for iPhone.

### Gameplay
* Team shard-sport for **1v1, 2v2, 3v3 and 4v4** (up to 8 players).
* **Pulse** (launch, charge and aim the shard; Perfect pulses at point-blank
  range), **Dash** (intangible burst), **Parry**, **Shatter**, **Body block**,
  ally **slingshot**, same-tick **Clash**.
* Four mirror-symmetric arenas: **The Foundry, Twin Rifts** (portals),
  **Pillar Drift** (moving pylons), **The Narrows** (choke wedges).
* Rules: round length 1–5 min or untimed, goal target 3/5/7 or time-only,
  golden-goal overtime, single round or best of 3/5.
* Modifiers: Twin Shards, Hyper Shard, Mega Pulse, Grounded, Glass Cannon.
* Deterministic bots in three difficulties fill empty slots; an **autopilot**
  pilots disconnected players.
* Results screen with goals, assists, shatters, parries, downs and MVP.
  Rematch keeps teams.

### Multiplayer
* Local Wi-Fi and Apple peer-to-peer play with **no server and no account**.
  Bonjour discovery and 4-character room codes.
* Lobby: names, team selection with auto-balance, ready flags, host crown,
  connection quality and RTT, host controls (settings, move, remove).
* Authoritative-host input timeline, **fixed-point deterministic simulation
  at 60 Hz**, prediction and **rollback**, RTT-based clock sync (device wall
  clocks are never used), adaptive shared input delay (2–4 ticks).
* State checksums every 0.5 s, with desync detection, logging and automatic
  snapshot repair.
* Reconnection with authoritative snapshots, pause and resume with a countdown,
  background/foreground handling, and **host migration** with epoch-based
  election and automatic demotion of a stale host.
* Optional diagnostics overlay: tick, host, RTT, jitter, loss, input delay,
  prediction, rollbacks, hash, simulation cost.

### Presentation
* Original visual identity (rift motif, Ember/Tide palette, team shape
  markers), SpriteKit rendering at up to 120 Hz on ProMotion iPhones,
  particles, screen shake, haptics.
* Procedurally synthesized original sound effects.
* Accessibility: colour-blind palette, reduce motion, larger HUD, left-handed
  controls, fixed or floating joystick, VoiceOver labels on menus and the HUD.
* Tutorial on first launch; Practice vs Bots offline.

### Verification
* 48 automated tests on Linux and macOS (simulation, protocol, rollback,
  full multiplayer sessions with faults).
* Network matrix: 26 of 26 scenarios pass, from 1v1 to 4v4, 10–200 ms latency,
  1–5% loss, jitter, reordering, duplication, reconnects, migration,
  backgrounding and an injected desync. See `docs/NETWORK_TEST_RESULTS.md`.
* CI builds the app, installs and launches it in the iOS Simulator
  (menu and a live bot match, with screenshots attached to the release), and
  produces the IPA.

### Known issues and limitations
* **The IPA is unsigned.** It must be signed (free Apple ID via
  Sideloadly or AltStore, or a developer account) before an iPhone will install
  it. See the README.
* **Not yet tested on physical iPhones.** The build environment had no Apple
  hardware or signing identity. Multiplayer was verified with the real session
  code over a simulated network and the app was launched in the iOS Simulator,
  but real Bonjour/UDP play between phones still needs a device test. The
  Simulator can't exercise the Local Network permission prompt or AWDL
  peer-to-peer.
* Real Wi-Fi power-save and AWDL channel hopping can cause brief latency
  spikes that the simulator doesn't reproduce. Rollback hides most of them;
  long spikes show as short corrections.
* After a host migration the match rewinds to the last state all devices
  agreed on (usually under 0.5 s) and pauses for a short countdown.
* After a migration, reconnect tokens aren't verified (member ids are
  trusted on the local network).
* iPhone only, landscape only. iPad isn't a target in this version.
