# RIFT RIVALS — Networking Architecture

Local multiplayer with **no server, no account and no cloud service**. One
player's device hosts the room; up to seven others join over the same Wi-Fi
network, or over Apple peer-to-peer Wi-Fi (AWDL) when not on a shared network.

```
┌───────────── Presentation (App/) ─────────────┐
│ SwiftUI menus · SpriteKit renderer · touch UI │  never writes game state
└───────────────────────┬───────────────────────┘
                        │ reads state / events, provides local input
┌───────────────────────▼───────────────────────┐
│ SessionController   practice | host | client  │  migration / demotion
├────────────────┬───────────────┬──────────────┤
│ HostSession    │ ClientSession │ PracticeSess.│  lobby, confirmation,
│                │               │              │  time sync, recovery
├────────────────┴───────┬───────┴──────────────┤
│ RollbackEngine (input timeline, prediction,   │
│ snapshots, rollback, checksums)               │
├────────────────────────┴──────────────────────┤
│ Simulation.step — pure, fixed-point, 60 Hz    │  identical on every device
├───────────────────────────────────────────────┤
│ PeerLink: framing · reliable ordered channel  │
│ · acks · duplicate suppression · RTT/jitter/  │
│ loss measurement                              │
├───────────────────────────────────────────────┤
│ NetTransport / HostTransport / RoomBrowser    │  abstraction
│  ├─ BonjourNetworkProvider (iOS: NWListener,  │
│  │   NWBrowser, NWConnection UDP)             │
│  └─ SimulatedNetwork (tests: latency, loss…)  │
└───────────────────────────────────────────────┘
```

## 1. Technology choice

| Option | Verdict |
|---|---|
| **Network.framework UDP + Bonjour** | **Chosen.** Real datagrams (no head-of-line blocking), Bonjour discovery with TXT records, `includePeerToPeer` for AWDL, `serviceClass = .interactiveVoice` for the low-latency Wi-Fi queue. Needs only `NSLocalNetworkUsageDescription` + `NSBonjourServices`. |
| Multipeer Connectivity | Simpler, but it hides the transport and has less predictable latency. Its 8-peer limit would also leave no headroom. |
| UDP broadcast/multicast discovery | Requires Apple's restricted `com.apple.developer.networking.multicast` entitlement on iOS 14+. Not used. |
| WebRTC DataChannels | Large dependency, only valuable for internet NAT traversal. Possible future transport. |

## 2. Deterministic simulation

* All gameplay math is **Q16.16 fixed point in `Int64`** (`Fx`, `FxVec`) with an
  integer square root. There are **no floats** in the simulation, so results are
  bit-identical on any CPU and compiler.
* RNG: PCG32, stored *in* the game state, so a rollback restores it.
* **Fixed 60 Hz tick.** `FixedStepClock` converts display frames (60/90/120 Hz,
  or irregular) into whole ticks. Rendering interpolates and extrapolates for
  display only and never writes back.
* Bots and autopilot run *inside* the simulation, reading only state, so every
  device computes identical bot inputs with zero traffic.
* Simultaneous actions are resolved order-independently: pulses are
  accumulated then applied, credit goes to the nearest pulser, and opposing
  same-tick pulses clash.
* State serializes to < 1 KB (`StateCodec`). The serialization is used for
  rollback snapshots, checksums (FNV-1a 64), reconnection and host migration.

## 3. Authoritative host, deterministic peers

The host is authoritative over **which input counts for which tick**, not over
positions:

1. Every device samples its local input once per tick and schedules it for
   `currentTick + inputDelay`. A packet carries `{player, firstTick, inputs[]}`
   and repeats every unacknowledged tick (up to 32), so loss costs nothing and
   duplicates and reordering are harmless (inputs are keyed by tick).
2. The host accepts input for tick *T* if it arrives before the host reaches
   **T + 10** (the finalize window). Otherwise it substitutes a filler: continue
   the last movement for 0.3 s, then neutral, or the **autopilot** when the
   player is disconnected. The decision is keyed by tick index, never by
   another device's clock.
3. The host broadcasts the **confirmed input stream** (`ConfirmedMsg`), resending
   from each client's per-player acknowledgement. Every device simulates the
   same confirmed inputs, so every device computes the same match.
4. **The host never waits** for a slow peer. A bad connection only costs that
   player their late inputs; it can't freeze the match for others.

Validation on the host: clients can't set host-only bits (autopilot), stick
vectors are clamped to the unit circle, inputs for impossible future ticks
(> host tick + 60) are rejected, and all of these are counted as
*suspicious* in diagnostics. A client only sends inputs for its own slot.

### Fairness (no host advantage)

* The host's own input goes through the same confirmation path, with the
  **same input delay** as everyone else.
* One shared input delay (2–4 ticks), sized from measured RTTs but **capped**
  so the slowest link can't make the game sluggish for all. Beyond the cap,
  rollback absorbs latency.
* Arenas and spawns are mirror-symmetric; same-tick conflicts are resolved by
  geometry, not by player index or packet arrival order.
* Inherent limitation: in a star topology the host sees other players' inputs
  one network hop earlier than clients do. Since outcomes are decided by tick
  numbers, this only affects how much the host's screen has to predict, not
  the result.

## 4. Prediction and rollback

`RollbackEngine` keeps, in rings of 256 ticks:

* confirmed inputs per player, the input actually *used* per tick, and the local
  player's own pending inputs;
* a serialized snapshot of the state at the start of every tick.

Missing remote inputs are **predicted**: keep moving the same way, but never
invent a button press. When a confirmed input differs from what was used, the
engine restores the snapshot for that tick and re-simulates to the present.
Prediction is bounded (30 ticks on clients, 16 on the host); past that the
client stalls for a frame rather than drift. Remote visual movement is smoothed
by exponential follow plus velocity extrapolation, purely in the renderer.
Corrections larger than 70–90 units snap instead of sliding.

Edge-triggered actions mean an input is executed exactly once per simulation of
its tick. Duplicate, late or reordered packets can't repeat a pulse (verified by
the *Duplication storm* and ground-truth tests).

## 5. Clock synchronisation

Wall clocks are never used. Each device has only its own monotonic clock
(`CACurrentMediaTime`). The shared timeline is the **host's tick counter**:

* Pings every 200 ms (500 ms in the lobby) echo the client's send time; pongs
  carry the host's fractional tick. RTT and jitter are estimated with
  TCP-style smoothing.
* The client keeps `hostTick ≈ now × 60 + offset`, smoothed with an EWMA. Confirmed
  packets add low-weight samples.
* The client's fixed-step clock runs **±6% faster or slower** to converge on
  the estimate. More than 6 ticks behind, it catches up (up to 8 extra ticks per
  frame); more than 6 ahead, it holds.
* Tested with ±300 ppm clock drift, arbitrary clock offsets and 60/90/120 Hz
  frame rates per device.

## 6. State verification and desync repair

* Every 30 ticks, once all inputs before tick *T* are confirmed, each device
  hashes its snapshot of *T* (FNV-1a over the serialized state).
* Clients send their hashes; the host compares them with its own and also
  publishes its latest hash in every confirmed packet.
* On mismatch the host records `{member, lastMatchingTick, firstMismatchTick,
  hashes}` (shown in the diagnostics log), then sends a **corrective snapshot**
  of its latest final state reliably. The client restores it, re-simulates to
  the present and resumes. Devices are never allowed to keep playing different
  versions of the match.

## 7. Packets and reliability

```
u16 magic 'RR' | u8 version | u8 flags | u32 sessionID | u16 epoch
u16 packetSeq | u16 reliableAck
u8 n × { u16 seq, u8 type, u16 len, payload }   reliable, ordered
u8 m × { u8 type, u16 len, payload }            unreliable
```

* Reliable channel: resend after ~1.5 RTT, cumulative ack, in-order delivery,
  dedup. Used for lobby state, match start, snapshots, pause/resume and member
  status. Reliable messages are packed first so they can't starve.
* Unreliable: inputs, confirmed inputs, pings/pongs, hashes. Anything that
  doesn't fit the 1200-byte MTU is dropped and resent redundantly next tick.
* A 64-bit sliding window on `packetSeq` drops duplicate and stale packets
  and estimates inbound loss.
* `sessionID` (derived from the room code) and `epoch` reject stray packets
  from other rooms or from a previous host.
* Typical traffic during a 4v4 match: a client sends ~60 × 40 bytes/s; the
  host sends one ~60–150-byte packet per client per tick.

Connection labels shown to players are honest and derived from measurements:
**Excellent** (RTT ≤ 45 ms, loss < 1%, jitter ≤ 12 ms), **Good** (≤ 110 ms,
< 4%, ≤ 30 ms), **Unstable**, or **Reconnecting** (no packet for 0.75 s).

## 8. Rooms and lobby

Create room → 4-character room code (no ambiguous characters) advertised over
Bonjour as `RR-<code>-<epoch>` with a TXT record (`code, host, matchID, epoch,
hostMember, players, capacity, format, inMatch, protocol`). Joining shows nearby
rooms automatically; typing the code filters to one. There are player names,
team selection (balanced automatically on join), ready flags, connection status
with RTT, a host crown, kick and move actions for the host, and start blockers
explained in plain language. The room grows its format automatically when more
friends join (up to 4v4).

## 9. Disconnection, reconnection, pause

* **Detection:** 3 s of silence on the host or 2.5 s on a client. The UI
  shows *Reconnecting* after 0.75 s.
* **Client reconnect:** the client reopens its transport and sends
  `Rejoin(token, member, matchID)`. The host re-attaches the slot and replies
  with the setup and a **verified snapshot**, then streams confirmed inputs from
  there. In the meantime the slot was played by the autopilot (configurable).
* **Backgrounding:** iOS suspends networking. On return the client reconnects
  proactively. A host that was away less than the timeout simply continues;
  clients stall briefly and catch up.
* **Pause:** any player can request a pause (2 per team per match); the host
  can always pause. Resume shows a synchronised 2-second countdown.
* **Abandonment:** leaving a lobby removes the member. Leaving a match keeps the
  slot (autopilot); a rematch replaces departed players with bots.

## 10. Host migration

Implemented, with a strict *one authority per epoch* rule:

1. When a client loses the host (and the host is no longer advertised, or
   after 6 s), it computes the **same candidate list on every device**: all
   members except the old host, ordered by member id.
2. Candidate *k* hosts **epoch + 1 + k**. If you are the candidate you promote
   yourself (`HostSession(promoting:)`). You rewind to the last state every
   device agrees on (all inputs confirmed), re-queue the confirmed inputs you
   still hold, advertise the new epoch and pause the match.
3. Other clients find the advert (same room code and match id, higher epoch)
   and send `Rejoin`. The new host sends a *migration snapshot* and the match
   resumes with a countdown once everyone is back (or after 8 s). If a
   candidate never appears within 5 s, everyone moves on to the next one.
4. Packets carry the epoch and clients accept only their current host's
   epoch, so two hosts can never both steer the same device. A host with
   **no connected players** that discovers another live host of the same
   match (with players, or a higher epoch) **demotes itself** and rejoins as
   a client. This covers a host returning from a long background and a client
   that wrongly promoted itself during its own Wi-Fi outage.
5. If no candidate is left, the match ends with a clear message.

Security note: after migration the new host has never seen the other
devices' reconnect tokens, so it trusts member ids on the local network.
This is fine for friends on a LAN but would need signed tokens for internet
play.

## 11. Diagnostics overlay

Settings → *Show network diagnostics overlay* displays: current and confirmed
tick, epoch, host, RTT, jitter, loss, input delay, prediction depth, stalls,
rollback count and total ticks rolled back (and the deepest rollback), the
latest verified state hash with checks and mismatches, snapshots applied,
late, suspicious and duplicate inputs, simulation cost per tick (µs), and the
connection label.

## 12. Testing

* `swift test` runs 48 tests: fixed-point math, determinism across all
  formats and arenas, snapshot round-trips, scoring, own goals, rounds,
  best-of, golden goal, edge-triggered actions, order-independent clashes,
  frame-rate independence, input validation, protocol fuzzing, the reliable
  channel under 20% loss and 15% duplication, rollback convergence, and full
  multiplayer sessions with latency, loss, jitter, reordering, 8 players,
  reconnects, host migration, backgrounding, injected desyncs, pause and lobby
  rules.
* `swift run -c release riftsim` runs the network matrix and writes
  [`NETWORK_TEST_RESULTS.md`](NETWORK_TEST_RESULTS.md). Each run compares
  checkpoints across **all** devices and replays the host's confirmed input log
  on a fresh simulation (*ground truth*).

## 13. Future online play

Gameplay depends only on `NetTransport`, `HostTransport`, `RoomBrowser` and
`NetworkProvider`. Internet play can be added without touching the simulation
or the session logic:

* **P2P over the internet:** a WebRTC/ICE or QUIC transport plus a small
  signalling and matchmaking service that hands out `RoomAdvert`s.
* **Relay:** a TURN-like relay implementing `NetTransport` for strict NATs.
* **Dedicated server:** run `HostSession` headless on a server (`localPlayer =
  nil`). RiftCore already builds and runs on Linux, as CI proves.
* **Ranked:** would need signed reconnect tokens, server-side result
  verification (replay the confirmed input log, which is exactly what the
  ground-truth test does) and accounts. None of that is needed for local play.

## 14. Honest limitations

* Latency is never zero: even on a perfect LAN, prediction plus the 2-tick
  input delay means a remote action is confirmed ~50–80 ms after it happens.
  Local actions are applied immediately on your own screen through prediction.
* Real Wi-Fi has power-save latency spikes and AWDL channel hopping
  (occasional 50–150 ms stalls) that the simulator doesn't model.
* Migration loses up to the last few predicted ticks (rewind to the last state
  everyone agreed on) and pauses for a few seconds.
