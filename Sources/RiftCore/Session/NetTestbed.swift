// RIFT RIVALS — multiplayer test environment.
//
// Runs a host and up to seven clients inside one process over
// `SimulatedNetwork`, each node with its own frame rate (60/90/120 Hz), its
// own drifting, offset monotonic clock, and scripted human-like input. Used by
// the XCTest suite and the `riftsim` network test matrix.

/// Human-like scripted input: chases the shard using the *local predicted*
/// state (so it reacts to what this device sees), taps pulse when close.
public final class ScriptedPlayer: LocalInputSource {
    private var rng: DeterministicRNG
    weak var controller: SessionController?
    public private(set) var sampled: [Int32: PlayerInput] = [:]
    public var enabled = true
    private var holdTicks = 0
    private var held = PlayerInput.neutral
    private var jitter = (0, 0)

    public init(seed: UInt64) { rng = DeterministicRNG(seed: seed, stream: 99) }

    public func sampleInput(forTick tick: Int32) -> PlayerInput {
        guard enabled, let e = controller?.engine, let lp = e.localPlayer else { return .neutral }
        let s = e.state
        var out: PlayerInput
        if holdTicks > 0 {
            holdTicks -= 1
            out = held
        } else if let shard = s.shards.first(where: { $0.active }), lp < s.players.count {
            let me = s.players[lp]
            let d = (shard.pos - me.pos).normalized
            if tick % 6 == 0 { jitter = (rng.range(-25, 25), rng.range(-25, 25)) }
            var mx = (d.x * 100).intValue + jitter.0, my = (d.y * 100).intValue + jitter.1
            let m2 = mx * mx + my * my
            if m2 > 127 * 127 { let m = Int(isqrt(Int64(m2))); mx = mx * 127 / m; my = my * 127 / m }
            out = PlayerInput(moveX: Int8(clamping: mx), moveY: Int8(clamping: my), buttons: 0)
            if FxVec.withinRadius(shard.pos, me.pos, Fx(140)) && rng.next(below: 100) < 35 { out.buttons |= PlayerInput.pulse }
            if rng.next(below: 1000) < 6 { out.buttons |= PlayerInput.dash }
            if rng.next(below: 100) < 8 { holdTicks = rng.range(3, 20); held = PlayerInput(moveX: out.moveX, moveY: out.moveY, buttons: 0) }
        } else {
            out = .neutral
        }
        sampled[tick] = out
        return out
    }
}

public final class TestNode {
    public let name: String
    public let controller: SessionController
    public let provider: NetworkProvider
    public let player: ScriptedPlayer
    public var frameInterval: Double
    public var clockScale: Double
    public var clockOffset: Double
    public var nextFrame: Double = 0
    public var suspended = false

    init(name: String, provider: NetworkProvider, token: UInt64, frameRate: Double, clockScale: Double, clockOffset: Double, seed: UInt64) {
        self.name = name
        self.provider = provider
        self.controller = SessionController(token: token, playerName: name)
        self.player = ScriptedPlayer(seed: seed)
        self.frameInterval = 1 / frameRate
        self.clockScale = clockScale
        self.clockOffset = clockOffset
        player.controller = controller
    }

    /// This device's monotonic clock: arbitrary offset and slight drift.
    public func localTime(_ global: Double) -> Double { clockOffset + global * clockScale }

    public var isHostMode: Bool { if case .host = controller.mode { return true }; return false }
    public var hostEpoch: UInt16? { if case .host(let h) = controller.mode { return h.epoch }; return nil }
}

public struct TestbedConfig {
    public var humans: Int
    public var settings: MatchSettings
    public var conditions: LinkConditions
    public var seed: UInt64
    public var frameRates: [Double]

    public init(humans: Int, settings: MatchSettings, conditions: LinkConditions = .lan, seed: UInt64 = 7,
                frameRates: [Double] = [60, 120, 90, 60, 120, 90, 60, 120]) {
        self.humans = humans
        self.settings = settings
        self.conditions = conditions
        self.seed = seed
        self.frameRates = frameRates
    }
}

public struct TestbedReport: CustomStringConvertible {
    public var checkpointsCompared = 0
    public var checkpointMismatches = 0
    public var lastCommonCheckpoint: Int32 = -1
    public var groundTruthChecked = false
    public var groundTruthMatches = false
    public var rollbacks = 0
    public var maxRollbackDepth = 0
    public var stalls = 0
    public var lateInputs = 0
    public var snapshotsApplied = 0
    public var hostCount = 0
    public var maxSimultaneousHostsPerEpoch = 0
    public var transitions: [String] = []
    public var finalTick: Int32 = 0
    public var confirmedTick: Int32 = 0
    public var score: (Int, Int) = (0, 0)
    public var packetsSent = 0
    public var packetsDropped = 0
    public var avgRTTms = 0
    public var hashMismatchesReported = 0

    public init() {}

    public var consistent: Bool { checkpointsCompared > 0 && checkpointMismatches == 0 && (!groundTruthChecked || groundTruthMatches) }

    public var description: String {
        "checkpoints=\(checkpointsCompared) mismatches=\(checkpointMismatches) truth=\(groundTruthChecked ? (groundTruthMatches ? "ok" : "FAIL") : "-") " +
        "rollbacks=\(rollbacks) maxDepth=\(maxRollbackDepth) stalls=\(stalls) late=\(lateInputs) snaps=\(snapshotsApplied) " +
        "hosts=\(hostCount) tick=\(finalTick) conf=\(confirmedTick) score=\(score.0)-\(score.1) rtt=\(avgRTTms)ms"
    }
}

public final class NetTestbed {
    public let net: SimulatedNetwork
    public private(set) var nodes: [TestNode] = []
    public let config: TestbedConfig
    public private(set) var time: Double = 0
    public private(set) var hostLog: [[Int32: PlayerInput]] = []
    private var hookedEngine: ObjectIdentifier?
    public private(set) var maxHostsSameEpoch = 0

    public init(_ config: TestbedConfig) {
        self.config = config
        net = SimulatedNetwork(conditions: config.conditions, seed: config.seed)
        var rng = DeterministicRNG(seed: config.seed, stream: 5)
        for k in 0..<config.humans {
            let name = k == 0 ? "Host" : "P\(k)"
            let rate = config.frameRates[k % config.frameRates.count]
            let scale = 1 + Double(rng.range(-300, 300)) / 1_000_000   // ±300 ppm drift
            let offset = Double(rng.range(1000, 900_000))              // unrelated uptime clocks
            nodes.append(TestNode(name: name, provider: net.provider(node: name), token: UInt64(k + 1) * 0x9E37_79B9,
                                  frameRate: rate, clockScale: scale, clockOffset: offset, seed: config.seed &+ UInt64(k)))
        }
    }

    public var host: TestNode { nodes[0] }

    /// Host creates the room, everybody discovers and joins it, readies up, match starts.
    @discardableResult
    public func connectAndStart(timeout: Double = 10) -> Bool {
        do {
            try host.controller.host(provider: host.provider, settings: config.settings, seed: config.seed, now: host.localTime(time))
        } catch { return false }
        let browsers = nodes.dropFirst().map { $0.provider.makeBrowser() }
        browsers.forEach { $0.start() }
        var joined = Set<Int>()
        let deadline = time + timeout
        while time < deadline {
            for (k, b) in browsers.enumerated() where !joined.contains(k + 1) {
                if let ad = b.rooms.first {
                    let n = nodes[k + 1]
                    if (try? n.controller.join(provider: n.provider, advert: ad, now: n.localTime(time))) != nil { joined.insert(k + 1) }
                }
            }
            step(0.005)
            let ready = nodes.dropFirst().allSatisfy { n in
                if case .client(let c) = n.controller.mode { return c.phase == .lobby && c.lobby != nil } else { return false }
            }
            if ready && joined.count == nodes.count - 1 { break }
        }
        browsers.forEach { $0.stop() }
        guard case .host(let h) = host.controller.mode, h.lobby.members.count == nodes.count else { return false }
        for n in nodes.dropFirst() { if case .client(let c) = n.controller.mode { c.setReady(true) } }
        let readyDeadline = time + timeout
        while time < readyDeadline && !h.canStart { step(0.005) }
        guard h.startMatch() else { return false }
        run(seconds: 0.5)
        return nodes.allSatisfy { $0.controller.engine != nil }
    }

    public func step(_ dt: Double) {
        time += dt
        net.advance(to: time)
        for n in nodes where !n.suspended {
            if time >= n.nextFrame {
                n.nextFrame = time + n.frameInterval
                n.controller.update(now: n.localTime(time), input: n.player)
            }
        }
        hookHostLog()
        // Safety invariant: never two hosts for the same epoch.
        var perEpoch: [UInt16: Int] = [:]
        for n in nodes where !n.suspended && !net.offlineNodes.contains(n.name) { if let e = n.hostEpoch { perEpoch[e, default: 0] += 1 } }
        maxHostsSameEpoch = max(maxHostsSameEpoch, perEpoch.values.max() ?? 0)
    }

    public func run(seconds: Double, step dt: Double = 0.001) {
        let end = time + seconds
        while time < end { step(dt) }
    }

    private func hookHostLog() {
        guard case .host(let h) = host.controller.mode, let e = h.engine else { return }
        let id = ObjectIdentifier(e)
        guard hookedEngine != id else { return }
        hookedEngine = id
        hostLog = Array(repeating: [:], count: e.playerCount)
        e.confirmObserver = { [weak self] p, t, i in self?.hostLog[p][t] = i }
    }

    // MARK: - Fault injection

    public func setOffline(_ node: TestNode, _ offline: Bool) {
        if offline { net.offlineNodes.insert(node.name) } else { net.offlineNodes.remove(node.name) }
    }

    /// App backgrounded: no updates and no networking.
    public func suspend(_ node: TestNode, _ s: Bool) {
        node.suspended = s
        setOffline(node, s)
        if !s, case .client(let c) = node.controller.mode { c.handleReturnFromBackground(awayFor: 2) }
    }

    // MARK: - Verification

    /// Compare verified checksums between all live nodes and against an offline
    /// re-simulation of the host's confirmed input timeline.
    public func verify(nodes subset: [TestNode]? = nil, groundTruth: Bool = true, sinceTick: Int32 = 0) -> TestbedReport {
        let live = (subset ?? nodes).filter { $0.controller.engine != nil }
        var r = TestbedReport()
        r.transitions = nodes.flatMap { n in n.controller.transitions.map { "\(n.name): \($0)" } }
        r.hostCount = nodes.filter { $0.isHostMode && !net.offlineNodes.contains($0.name) }.count
        r.maxSimultaneousHostsPerEpoch = maxHostsSameEpoch
        r.packetsSent = net.sent
        r.packetsDropped = net.dropped
        var rtts: [Int] = []
        for n in live {
            guard let e = n.controller.engine else { continue }
            r.rollbacks += e.stats.rollbacks
            r.maxRollbackDepth = max(r.maxRollbackDepth, e.stats.maxRollbackDepth)
            r.stalls += e.stats.stalls
            r.snapshotsApplied += e.stats.snapshotsApplied
            let d = n.controller.diagnostics
            r.hashMismatchesReported += d.hashMismatches
            if !n.isHostMode { rtts.append(d.rttMs) } else { r.lateInputs += d.lateInputs }
        }
        r.avgRTTms = rtts.isEmpty ? 0 : rtts.reduce(0, +) / rtts.count
        guard let first = live.first?.controller.engine else { return r }
        r.finalTick = first.currentTick
        r.confirmedTick = live.compactMap { $0.controller.engine?.confirmedTick }.min() ?? 0
        r.score = (first.state.score(team: 0), first.state.score(team: 1))

        // Cross-device checkpoint comparison.
        let maps = live.compactMap { n -> [Int32: UInt64]? in
            guard let e = n.controller.engine else { return nil }
            var m: [Int32: UInt64] = [:]
            for v in e.verifiedHashes where v.tick >= sinceTick { m[v.tick] = v.hash }
            return m
        }
        var common = Set(maps.first?.keys.map { $0 } ?? [])
        for m in maps.dropFirst() { common.formIntersection(m.keys) }
        for t in common.sorted() {
            r.checkpointsCompared += 1
            let hs = Set(maps.compactMap { $0[t] })
            if hs.count != 1 { r.checkpointMismatches += 1 }
            r.lastCommonCheckpoint = max(r.lastCommonCheckpoint, t)
        }

        // Ground truth: replay the host's confirmed inputs on a fresh simulation.
        if groundTruth, case .host(let h) = host.controller.mode, let he = h.engine, let setup = h.setup,
           let target = he.latestVerified, !hostLog.isEmpty {
            r.groundTruthChecked = true
            let ctx = SimContext(setup: setup)
            var s = Simulation.initialState(ctx)
            var ev: [GameEvent] = []
            var inputs = Array(repeating: PlayerInput.neutral, count: setup.playerCount)
            var complete = true
            while s.tick < target.tick {
                for p in 0..<setup.playerCount {
                    if setup.slots[p].isBot { inputs[p] = .neutral; continue }
                    guard let i = hostLog[p][s.tick] else { complete = false; break }
                    inputs[p] = i
                }
                if !complete { break }
                Simulation.step(&s, inputs: inputs, ctx: ctx, events: &ev)
                ev.removeAll(keepingCapacity: true)
            }
            r.groundTruthMatches = complete && StateCodec.hash(s) == target.hash
        }
        return r
    }

    /// For each human: ticks where what the device sent differs from what the
    /// host confirmed (inputs that arrived too late and were replaced).
    public func inputMismatches(node: TestNode) -> (compared: Int, replaced: Int) {
        guard let e = node.controller.engine, let lp = e.localPlayer, lp < hostLog.count else { return (0, 0) }
        var compared = 0, replaced = 0
        for (t, sent) in node.player.sampled where t <= e.confirmedTick {
            guard let confirmed = hostLog[lp][t] else { continue }
            compared += 1
            if confirmed != sent { replaced += 1 }
        }
        return (compared, replaced)
    }
}
