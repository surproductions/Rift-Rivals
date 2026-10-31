import XCTest
@testable import RiftCore

final class ProtocolTests: XCTestCase {
    func roundTrip(_ m: NetMessage, file: StaticString = #filePath, line: UInt = #line) {
        let payload = MessageCodec.payload(m)
        XCTAssertEqual(try MessageCodec.decode(type: m.type.rawValue, payload), m, file: file, line: line)
    }

    func testAllMessagesRoundTrip() {
        let setup = makeSetup(.squad, bots: false)
        roundTrip(.hello(HelloMsg(name: "Zoë ⚡️", token: 0xDEAD_BEEF_1234, protocolVersion: NetProtocol.version, buildNumber: 7)))
        roundTrip(.welcome(WelcomeMsg(memberID: 3, roomCode: "K7QX", epoch: 2)))
        roundTrip(.reject(.roomFull))
        roundTrip(.lobby(LobbyState(roomCode: "ABCD", epoch: 1, settings: setup.settings,
                                    members: [LobbyMember(id: 0, name: "Host", team: 0, ready: true, connected: true, isHost: true, rttMs: 0),
                                              LobbyMember(id: 4, name: "Guest", team: 1, ready: false, connected: false, isHost: false, rttMs: 33)],
                                    inMatch: false, revision: 77)))
        roundTrip(.lobbyRequest(.setTeam(1)))
        roundTrip(.lobbyRequest(.setReady(true)))
        roundTrip(.lobbyRequest(.setName("Nova")))
        roundTrip(.lobbyRequest(.requestPause))
        roundTrip(.startMatch(StartMatchMsg(setup: setup, memberIDs: setup.slots.map { $0.memberID ?? 255 }, hostTickAtSend: 12)))
        roundTrip(.leave)
        roundTrip(.ping(PingMsg(seq: 9, sendTime: 1234.5678, lossPermille: 12, rttMs: 40)))
        roundTrip(.pong(PongMsg(seq: 9, echoTime: 1234.5678, hostTick: 99.25, lossPermille: 3)))
        roundTrip(.input(InputMsg(player: 2, firstTick: 400, inputs: [PlayerInput(moveX: -127, moveY: 64, buttons: 3), .neutral],
                                  acks: [399, 398, 400, 12, 0, -1, 5, 6], rttMs: 21)))
        roundTrip(.confirmed(ConfirmedMsg(hostTick: 500, inputDelay: 3,
                                          ranges: [InputRange(player: 1, firstTick: 497, inputs: [PlayerInput(moveX: 1, moveY: 2, buttons: 1)])],
                                          hashTick: 480, hash: 0xABCDEF)))
        roundTrip(.stateHash(StateHashMsg(tick: 480, hash: .max)))
        roundTrip(.snapshot(SnapshotMsg(matchID: 5, tick: 600, reason: .migration, state: [1, 2, 3])))
        roundTrip(.control(.pause(tick: 10, byMember: 2)))
        roundTrip(.control(.resume(tick: 10, countdownTicks: 120)))
        roundTrip(.control(.backToLobby))
        roundTrip(.rejoin(RejoinMsg(token: 77, memberID: 3, matchID: 5, confirmedTick: 300, name: "X")))
        roundTrip(.memberStatus(MemberStatusMsg(entries: [.init(id: 1, connected: false, rttMs: 9)])))
    }

    func testMalformedInputIsRejectedSafely() {
        XCTAssertThrowsError(try MessageCodec.decode(type: MessageType.confirmed.rawValue, [1, 2, 3]))
        XCTAssertThrowsError(try MessageCodec.decode(type: 250, []))
        let link = PeerLink(link: 0, sessionID: 1, epoch: 1, now: 0)
        var out: [NetMessage] = []
        XCTAssertEqual(link.parse([0x52, 0x52, 9, 9], now: 0, acceptEpoch: { _ in true }, out: &out), .malformed)
        var garbage = DeterministicRNG(seed: 3)
        for _ in 0..<500 {
            let bytes = (0..<Int(garbage.next(below: 64))).map { _ in UInt8(truncatingIfNeeded: garbage.next()) }
            _ = link.parse(bytes, now: 0, acceptEpoch: { _ in true }, out: &out)
        }
    }

    /// Reliable messages arrive exactly once and in order despite loss,
    /// duplication and reordering on the wire.
    func testReliableChannelOrderingUnderAdverseNetwork() {
        let a = PeerLink(link: 0, sessionID: 42, epoch: 1, now: 0)
        let b = PeerLink(link: 0, sessionID: 42, epoch: 1, now: 0)
        var rng = DeterministicRNG(seed: 11)
        for k in 0..<200 { a.sendReliable(.lobbyRequest(.setName("m\(k)"))) }
        var received: [String] = []
        var wire: [(Double, [UInt8], Bool)] = []   // (deliverAt, bytes, toB)
        var now = 0.0
        while now < 30 && received.count < 200 {
            now += 0.01
            if let p = a.buildPacket(now: now, unreliable: []) { wire.append((now + Double(rng.next(below: 80)) / 1000, p, true)) }
            if let p = b.buildPacket(now: now, unreliable: []) { wire.append((now + Double(rng.next(below: 80)) / 1000, p, false)) }
            var keep: [(Double, [UInt8], Bool)] = []
            for w in wire {
                guard w.0 <= now else { keep.append(w); continue }
                if rng.next(below: 100) < 20 { continue }                 // 20% loss
                let copies = rng.next(below: 100) < 15 ? 2 : 1            // 15% duplication
                for _ in 0..<copies {
                    var out: [NetMessage] = []
                    if w.2 {
                        _ = b.parse(w.1, now: now, acceptEpoch: { $0 == 1 }, out: &out)
                        for m in out { if case .lobbyRequest(.setName(let n)) = m { received.append(n) } }
                    } else {
                        _ = a.parse(w.1, now: now, acceptEpoch: { $0 == 1 }, out: &out)
                    }
                }
            }
            wire = keep
        }
        XCTAssertEqual(received, (0..<200).map { "m\($0)" })
        XCTAssertGreaterThan(b.stats.duplicatesDropped, 0)
    }

    func testWrongSessionOrEpochIsIgnored() {
        let a = PeerLink(link: 0, sessionID: 1, epoch: 3, now: 0)
        let b = PeerLink(link: 0, sessionID: 2, epoch: 3, now: 0)
        let p = a.buildPacket(now: 0, unreliable: [.leave])!
        var out: [NetMessage] = []
        XCTAssertEqual(b.parse(p, now: 0, acceptEpoch: { _ in true }, out: &out), .wrongSession)
        let c = PeerLink(link: 0, sessionID: 1, epoch: 4, now: 0)
        XCTAssertEqual(c.parse(p, now: 0, acceptEpoch: { $0 == 4 }, out: &out), .wrongSession, "stale epoch rejected")
    }

    func testAdvertTXTRoundTrip() {
        let ad = RoomAdvert(roomCode: "QW3E", hostName: "Mika", matchID: 99, epoch: 2, hostMemberID: 3, players: 5, capacity: 8,
                            format: .squad, inMatch: true, endpoint: "x")
        XCTAssertEqual(RoomAdvert(txt: ad.txtRecord, endpoint: "x"), ad)
    }
}

final class RollbackEngineTests: XCTestCase {
    /// Inputs that arrive late (and out of order) must yield exactly the
    /// state of a simulation that had all inputs on time.
    func testLateInputsConvergeToReference() {
        let setup = makeSetup(.duo, bots: false)
        var rng = DeterministicRNG(seed: 5)
        let total: Int32 = 1200
        var script: [[PlayerInput]] = Array(repeating: [], count: 4)
        for p in 0..<4 {
            for _ in 0..<total {
                script[p].append(PlayerInput(moveX: Int8(rng.range(-127, 127)), moveY: Int8(rng.range(-90, 90)),
                                             buttons: rng.next(below: 10) == 0 ? PlayerInput.pulse : 0))
            }
        }
        let (reference, _) = runOffline(setup, ticks: Int(total)) { t, p in script[p][Int(t)] }

        let engine = RollbackEngine(setup: setup, maxPrediction: 40)
        engine.localPlayer = 0
        var delivered = Array(repeating: Int32(-1), count: 4)
        for iteration in 0..<(total + 60) {
            let now = Int32(iteration)
            // Player 0 is local (immediate); others arrive 3, 9 and 17 ticks late.
            let lags: [Int32] = [0, 3, 9, 17]
            for p in 0..<4 {
                while delivered[p] + 1 < total && delivered[p] + 1 <= now - lags[p] {
                    let t = delivered[p] + 1
                    XCTAssertTrue(engine.confirm(player: p, tick: t, script[p][Int(t)]))
                    XCTAssertFalse(engine.confirm(player: p, tick: t, script[p][Int(t)]), "duplicates are refused")
                    delivered[p] = t
                }
            }
            if engine.currentTick < total { engine.advance() } else { engine.resolveRollback() }
        }
        XCTAssertEqual(engine.currentTick, total)
        XCTAssertEqual(StateCodec.hash(engine.state), StateCodec.hash(reference))
        XCTAssertGreaterThan(engine.stats.rollbacks, 0)
        XCTAssertEqual(engine.verifiedHash(at: 900), {
            let (s, _) = runOffline(setup, ticks: 900) { t, p in script[p][Int(t)] }
            return StateCodec.hash(s)
        }())
    }

    func testPredictionLimitStallsInsteadOfRunningAway() {
        let setup = makeSetup(.duel, bots: false)
        let engine = RollbackEngine(setup: setup, maxPrediction: 10)
        engine.localPlayer = 0
        var advanced = 0
        for t in 0..<100 {
            engine.confirm(player: 0, tick: Int32(t), .neutral)
            if engine.advance() { advanced += 1 }
        }
        XCTAssertEqual(advanced, 10, "never predicts more than maxPrediction ticks past confirmed input")
        XCTAssertGreaterThan(engine.stats.stalls, 0)
    }

    func testAuthoritativeSnapshotRepairsCorruption() throws {
        let setup = makeSetup(.duel, bots: false)
        let a = RollbackEngine(setup: setup), b = RollbackEngine(setup: setup)
        for t in Int32(0)..<300 {
            for e in [a, b] { e.confirm(player: 0, tick: t, PlayerInput(moveX: 90, moveY: 10, buttons: 0)); e.confirm(player: 1, tick: t, .neutral); e.advance() }
            if t == 100 { b.debugCorruptState() }
        }
        XCTAssertNotEqual(a.verifiedHash(at: 270), b.verifiedHash(at: 270))
        let snapTick: Int32 = 240
        try b.applyAuthoritativeSnapshot(tick: snapTick, bytes: a.snapshotBytes(at: snapTick)!)
        for t in Int32(300)..<400 {
            for e in [a, b] { e.confirm(player: 0, tick: t, .neutral); e.confirm(player: 1, tick: t, .neutral); e.advance() }
        }
        XCTAssertEqual(StateCodec.hash(a.state), StateCodec.hash(b.state))
        XCTAssertEqual(a.verifiedHash(at: 390), b.verifiedHash(at: 390))
    }
}
