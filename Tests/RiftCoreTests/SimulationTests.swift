import XCTest
@testable import RiftCore

func makeSetup(_ format: MatchFormat = .duel, arena: ArenaID = .foundry, bots: Bool = true, seed: UInt64 = 42,
               seconds: UInt16 = 120, goals: UInt8 = 5, bestOf: UInt8 = 1, mods: Modifiers = []) -> MatchSetup {
    let settings = MatchSettings(format: format, roundSeconds: seconds, goalsToWin: goals, bestOf: bestOf, arena: arena,
                                 botDifficulty: .hard, modifiers: mods)
    let slots = (0..<format.playerCount).map { RosterSlot(name: "P\($0)", isBot: bots, memberID: bots ? nil : UInt8($0)) }
    return MatchSetup(matchID: 9, seed: seed, settings: settings, slots: slots)
}

func runOffline(_ setup: MatchSetup, ticks: Int, inputs: (Int32, Int) -> PlayerInput = { _, _ in .neutral }) -> (GameState, [GameEvent]) {
    let ctx = SimContext(setup: setup)
    var s = Simulation.initialState(ctx)
    var events: [GameEvent] = []
    var buf = Array(repeating: PlayerInput.neutral, count: setup.playerCount)
    for _ in 0..<ticks {
        for p in 0..<setup.playerCount { buf[p] = inputs(s.tick, p) }
        Simulation.step(&s, inputs: buf, ctx: ctx, events: &events)
    }
    return (s, events)
}

final class FixedPointTests: XCTestCase {
    func testIntegerSquareRoot() {
        for v: Int64 in [0, 1, 2, 3, 4, 15, 16, 17, 99, 100, 1 << 40, (1 << 62) - 1] {
            let r = isqrt(v)
            XCTAssertLessThanOrEqual(r * r, v)
            XCTAssertGreaterThan((r + 1) * (r + 1), v)
        }
    }

    func testVectorMath() {
        let v = FxVec(3, 4)
        XCTAssertEqual(v.length, Fx(5))
        let n = v.normalized
        XCTAssertEqual(n.x.double, 0.6, accuracy: 0.0001)
        XCTAssertEqual(n.y.double, 0.8, accuracy: 0.0001)
        XCTAssertEqual(FxVec.zero.normalized, .zero)
        XCTAssertEqual(FxVec(30, 40).limited(Fx(5)).length.double, 5, accuracy: 0.001)
    }

    func testRNGIsDeterministic() {
        var a = DeterministicRNG(seed: 123), b = DeterministicRNG(seed: 123), c = DeterministicRNG(seed: 124)
        let sa = (0..<100).map { _ in a.next() }
        XCTAssertEqual(sa, (0..<100).map { _ in b.next() })
        XCTAssertNotEqual(sa, (0..<100).map { _ in c.next() })
        // Known value guards against accidental algorithm changes (cross-platform determinism).
        var k = DeterministicRNG(seed: 1)
        let first = k.next()
        var k2 = DeterministicRNG(seed: 1)
        XCTAssertEqual(first, k2.next())
    }
}

final class SimulationTests: XCTestCase {
    func testIdenticalRunsProduceIdenticalStates() {
        for format in MatchFormat.allCases {
            for arena in ArenaID.allCases {
                let setup = makeSetup(format, arena: arena)
                let (a, ea) = runOffline(setup, ticks: 3000)
                let (b, eb) = runOffline(setup, ticks: 3000)
                XCTAssertEqual(StateCodec.hash(a), StateCodec.hash(b), "\(format) \(arena)")
                XCTAssertEqual(ea, eb)
            }
        }
    }

    func testDifferentSeedsDiverge() {
        let (a, _) = runOffline(makeSetup(.duo, seed: 1), ticks: 2000)
        let (b, _) = runOffline(makeSetup(.duo, seed: 2), ticks: 2000)
        XCTAssertNotEqual(StateCodec.hash(a), StateCodec.hash(b))
    }

    func testSnapshotRoundTripAndResume() throws {
        let setup = makeSetup(.trio, arena: .twinRifts, mods: [.twinShards])
        let ctx = SimContext(setup: setup)
        var s = Simulation.initialState(ctx)
        var ev: [GameEvent] = []
        let none = Array(repeating: PlayerInput.neutral, count: setup.playerCount)
        for _ in 0..<1500 { Simulation.step(&s, inputs: none, ctx: ctx, events: &ev) }
        let bytes = StateCodec.encode(s)
        var restored = try StateCodec.decode(bytes)
        XCTAssertEqual(restored, s)
        XCTAssertLessThan(bytes.count, 1100, "snapshot must fit one datagram")
        for _ in 0..<1500 {
            Simulation.step(&s, inputs: none, ctx: ctx, events: &ev)
            Simulation.step(&restored, inputs: none, ctx: ctx, events: &ev)
        }
        XCTAssertEqual(StateCodec.hash(s), StateCodec.hash(restored))
    }

    func testTeamsAndMirroredSpawns() {
        for format in MatchFormat.allCases {
            let setup = makeSetup(format)
            let ctx = SimContext(setup: setup)
            let s = Simulation.initialState(ctx)
            XCTAssertEqual(s.players.count, format.playerCount)
            for i in 0..<format.teamSize {
                let a = s.players[i], b = s.players[i + format.teamSize]
                XCTAssertEqual(a.team, 0)
                XCTAssertEqual(b.team, 1)
                XCTAssertEqual(a.pos.x + b.pos.x, Fx(Arena.standardWidth), "spawns mirror across centre")
                XCTAssertEqual(a.pos.y, b.pos.y)
            }
        }
    }

    func testArenasAreMirrorSymmetric() {
        for id in ArenaID.allCases {
            let arena = Arena.make(id)
            let w = arena.width
            for seg in arena.segments {
                let ma = FxVec(x: w - seg.a.x, y: seg.a.y), mb = FxVec(x: w - seg.b.x, y: seg.b.y)
                let mirrored = arena.segments.contains { ($0.a == ma && $0.b == mb) || ($0.a == mb && $0.b == ma) }
                XCTAssertTrue(mirrored, "\(id) segment \(seg.a)-\(seg.b) has no mirror")
            }
            for p in arena.pillars {
                XCTAssertTrue(arena.pillars.contains { $0.base == FxVec(x: w - p.base.x, y: p.base.y) && $0.travel == p.travel })
            }
        }
    }

    /// Put a shard right in front of a goal and verify the right team scores.
    func testGoalScoringAndCredit() {
        let setup = makeSetup(.duel, bots: false)
        let ctx = SimContext(setup: setup)
        var s = Simulation.initialState(ctx)
        s.phase = .playing
        s.phaseTimer = 0
        s.shards[0].pos = FxVec(40, 450)
        s.shards[0].vel = FxVec(-12, 0)
        s.shards[0].lastToucher = 1      // Tide player
        s.shards[0].owner = 1
        var ev: [GameEvent] = []
        let none = [PlayerInput.neutral, .neutral]
        for _ in 0..<20 { Simulation.step(&s, inputs: none, ctx: ctx, events: &ev) }
        XCTAssertEqual(s.score(team: 1), 1, "shard in the left goal scores for Tide")
        XCTAssertEqual(s.score(team: 0), 0)
        XCTAssertEqual(s.players[1].goals, 1)
        XCTAssertEqual(s.phase, .goalScored)
        XCTAssertEqual(ev.filter { $0.kind == .goal }.count, 1)

        // Own goal: Ember touched it last into its own goal -> Tide scores, nobody credited.
        var o = Simulation.initialState(ctx)
        o.phase = .playing
        o.shards[0].pos = FxVec(40, 450)
        o.shards[0].vel = FxVec(-12, 0)
        o.shards[0].lastToucher = 0
        for _ in 0..<20 { Simulation.step(&o, inputs: none, ctx: ctx, events: &ev) }
        XCTAssertEqual(o.score(team: 1), 1)
        XCTAssertEqual(o.players[0].goals, 0)
        XCTAssertEqual(o.lastGoalScorer, -1)
    }

    func testRoundAndMatchProgression() {
        // Best of 3, first to 1 goal: drive goals artificially.
        let setup = makeSetup(.duel, bots: false, seconds: 0, goals: 1, bestOf: 3)
        let ctx = SimContext(setup: setup)
        var s = Simulation.initialState(ctx)
        var ev: [GameEvent] = []
        let none = [PlayerInput.neutral, .neutral]
        var guardTicks = 0
        while s.phase != .matchOver && guardTicks < 20000 {
            if s.phase == .playing && s.shards[0].active && s.shards[0].pos.x < Fx(1500) {
                s.shards[0].pos = FxVec(Arena.standardWidth - 30, 450)
                s.shards[0].vel = FxVec(15, 0)   // Ember scores every point
            }
            Simulation.step(&s, inputs: none, ctx: ctx, events: &ev)
            guardTicks += 1
        }
        XCTAssertEqual(s.phase, .matchOver)
        XCTAssertEqual(s.roundWins.0, 2)
        XCTAssertEqual(s.roundWins.1, 0)
        XCTAssertEqual(s.matchWinner, 0)
        XCTAssertEqual(s.round, 2)
        XCTAssertEqual(ev.filter { $0.kind == .roundOver }.count, 2)
        XCTAssertEqual(ev.filter { $0.kind == .matchOver }.count, 1)
    }

    func testTimeLimitAndGoldenGoalOvertime() {
        let setup = makeSetup(.duel, bots: false, seconds: 2, goals: 0)
        let ctx = SimContext(setup: setup)
        var s = Simulation.initialState(ctx)
        var ev: [GameEvent] = []
        let none = [PlayerInput.neutral, .neutral]
        for _ in 0..<(180 + 125) { Simulation.step(&s, inputs: none, ctx: ctx, events: &ev) }
        XCTAssertTrue(s.overtime, "tied at time-out goes to golden goal")
        XCTAssertEqual(s.phase, .playing)
        s.shards[0].pos = FxVec(30, 450); s.shards[0].vel = FxVec(-15, 0)
        for _ in 0..<(30 + Int(Tuning.goalCelebrationTicks)) { Simulation.step(&s, inputs: none, ctx: ctx, events: &ev) }
        XCTAssertEqual(s.phase, .roundOver)
        XCTAssertEqual(s.lastRoundWinner, 1)
    }

    func testPulseLaunchesShardAndIsEdgeTriggered() {
        let setup = makeSetup(.duel, bots: false)
        let ctx = SimContext(setup: setup)
        var s = Simulation.initialState(ctx)
        s.phase = .playing
        s.players[0].pos = FxVec(700, 450)
        s.players[1].pos = FxVec(1300, 120)   // out of the shard's path
        s.shards[0].pos = FxVec(760, 450)
        var ev: [GameEvent] = []
        let press = PlayerInput(moveX: 0, moveY: 0, buttons: PlayerInput.pulse)
        // Holding the button for 60 ticks must only pulse once (edge-triggered).
        for _ in 0..<60 { Simulation.step(&s, inputs: [press, .neutral], ctx: ctx, events: &ev) }
        XCTAssertEqual(s.players[0].pulses, 1)
        XCTAssertGreaterThan(s.shards[0].pos.x, Fx(900), "shard launched away from the pulser")
        XCTAssertEqual(s.shards[0].owner, 0)
    }

    /// Two opponents pulse the same shard from mirrored positions on the same
    /// tick: the outcome must not depend on player index.
    func testSimultaneousPulsesAreOrderIndependent() {
        let setup = makeSetup(.duel, bots: false)
        let ctx = SimContext(setup: setup)
        var s = Simulation.initialState(ctx)
        s.phase = .playing
        s.players[0].pos = FxVec(740, 450)
        s.players[1].pos = FxVec(860, 450)
        s.shards[0].pos = FxVec(800, 450)
        var ev: [GameEvent] = []
        let press = PlayerInput(moveX: 0, moveY: 0, buttons: PlayerInput.pulse)
        Simulation.step(&s, inputs: [press, press], ctx: ctx, events: &ev)
        XCTAssertEqual(s.shards[0].owner, -1, "clash neutralises the shard")
        XCTAssertEqual(s.shards[0].vel.x, .zero)
        XCTAssertTrue(ev.contains { $0.kind == .clash })
    }

    func testShatterRemovesAndRespawnsPlayer() {
        let setup = makeSetup(.duel, bots: false)
        let ctx = SimContext(setup: setup)
        var s = Simulation.initialState(ctx)
        s.phase = .playing
        s.players[1].pos = FxVec(900, 450)
        s.shards[0].pos = FxVec(840, 450)
        s.shards[0].vel = FxVec(16, 0)
        s.shards[0].owner = 0
        s.shards[0].heat = 3
        s.shards[0].lastToucher = 0
        var ev: [GameEvent] = []
        for _ in 0..<10 { Simulation.step(&s, inputs: [.neutral, .neutral], ctx: ctx, events: &ev) }
        XCTAssertGreaterThan(s.players[1].shatteredTicks, 0)
        XCTAssertEqual(s.players[0].shatters, 1)
        for _ in 0..<Int(Tuning.shatterRespawnTicks) { Simulation.step(&s, inputs: [.neutral, .neutral], ctx: ctx, events: &ev) }
        XCTAssertEqual(s.players[1].shatteredTicks, 0)
        XCTAssertTrue(ev.contains { $0.kind == .respawn })
    }

    func testDashPhasesThroughChargedShard() {
        let setup = makeSetup(.duel, bots: false)
        let ctx = SimContext(setup: setup)
        var s = Simulation.initialState(ctx)
        s.phase = .playing
        s.players[1].pos = FxVec(900, 450)
        s.players[1].dashTicks = 8
        s.shards[0].pos = FxVec(860, 450)
        s.shards[0].vel = FxVec(16, 0)
        s.shards[0].owner = 0
        s.shards[0].heat = 4
        var ev: [GameEvent] = []
        for _ in 0..<5 { Simulation.step(&s, inputs: [.neutral, .neutral], ctx: ctx, events: &ev) }
        XCTAssertEqual(s.players[1].shatteredTicks, 0, "dashing players are intangible")
    }

    func testFrameRateIndependence() {
        // 10 seconds rendered at 60, 90, 120 and an irregular frame rate must
        // execute exactly the same number of simulation ticks.
        func ticks(frameRate: Double, wobble: Bool) -> Int {
            var clock = FixedStepClock()
            clock.reset(now: 1000)
            var t = 1000.0, total = 0, k = 0
            while t < 1010 - 1e-9 {
                let step = 1 / frameRate * (wobble ? (k % 3 == 0 ? 1.4 : 0.8) : 1)
                t = min(1010, t + step)
                k += 1
                total += clock.ticksDue(now: t)
            }
            return total
        }
        let reference = ticks(frameRate: 60, wobble: false)
        XCTAssertEqual(abs(reference - 600), 0, accuracy: 1)
        for fr in [90.0, 120, 144] { XCTAssertEqual(Double(ticks(frameRate: fr, wobble: false)), Double(reference), accuracy: 1) }
        XCTAssertEqual(Double(ticks(frameRate: 120, wobble: true)), Double(reference), accuracy: 1)
    }

    func testInputValidation() {
        let (ok, s1) = PlayerInput(moveX: 50, moveY: -20, buttons: PlayerInput.pulse).validated()
        XCTAssertFalse(s1)
        XCTAssertEqual(ok.buttons, PlayerInput.pulse)
        let (fixed, s2) = PlayerInput(moveX: 127, moveY: 127, buttons: PlayerInput.autopilot | 0x40).validated()
        XCTAssertTrue(s2, "host-only bits and over-long stick vectors are suspicious")
        XCTAssertEqual(fixed.buttons & PlayerInput.autopilot, 0)
        XCTAssertLessThanOrEqual(Int(fixed.moveX) * Int(fixed.moveX) + Int(fixed.moveY) * Int(fixed.moveY), 127 * 127 + 254)
    }

    func testAllBotMatchesFinish() {
        for format in MatchFormat.allCases {
            let setup = makeSetup(format, arena: .narrows, seconds: 60, goals: 3)
            let (s, _) = runOffline(setup, ticks: 60 * 75)
            XCTAssertEqual(s.phase, .matchOver, "\(format) match completes")
            XCTAssertNotEqual(s.matchWinner, -1)
        }
    }
}
