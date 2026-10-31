import XCTest
@testable import RiftCore

/// End-to-end multiplayer tests: real HostSession / ClientSession instances
/// over the deterministic simulated network. Every device runs its own frame
/// rate (60/90/120 Hz) and its own drifting monotonic clock.
final class NetworkTests: XCTestCase {
    func settings(_ f: MatchFormat, arena: ArenaID = .foundry) -> MatchSettings {
        MatchSettings(format: f, roundSeconds: 180, goalsToWin: 0, bestOf: 1, arena: arena)
    }

    @discardableResult
    func runMatch(humans: Int, format: MatchFormat, conditions: LinkConditions, seconds: Double = 15,
                  arena: ArenaID = .pillarDrift, seed: UInt64 = 7, file: StaticString = #filePath, line: UInt = #line) -> (NetTestbed, TestbedReport) {
        let tb = NetTestbed(TestbedConfig(humans: humans, settings: settings(format, arena: arena), conditions: conditions, seed: seed))
        XCTAssertTrue(tb.connectAndStart(), "lobby + start", file: file, line: line)
        tb.run(seconds: seconds)
        let r = tb.verify()
        XCTAssertTrue(r.consistent, "\(format.label) \(conditions.label): \(r)", file: file, line: line)
        XCTAssertGreaterThan(r.checkpointsCompared, Int(seconds * 2) - 6, file: file, line: line)
        XCTAssertTrue(r.groundTruthChecked && r.groundTruthMatches, "replay of confirmed inputs matches", file: file, line: line)
        XCTAssertEqual(r.maxSimultaneousHostsPerEpoch, 1, file: file, line: line)
        XCTAssertGreaterThan(r.confirmedTick, Int32(seconds * 60) - 40, "match keeps progressing", file: file, line: line)
        return (tb, r)
    }

    // MARK: Latency matrix

    func testTwoPlayersSameWiFi() { runMatch(humans: 2, format: .duel, conditions: .lan) }
    func testLatency10ms() { runMatch(humans: 2, format: .duel, conditions: LinkConditions(latency: 0.010, jitter: 0.002)) }
    func testLatency30ms() { runMatch(humans: 2, format: .duel, conditions: LinkConditions(latency: 0.030, jitter: 0.004)) }
    func testLatency50ms() { runMatch(humans: 4, format: .duo, conditions: LinkConditions(latency: 0.050, jitter: 0.006)) }
    func testLatency100ms() { runMatch(humans: 2, format: .duel, conditions: LinkConditions(latency: 0.100, jitter: 0.010)) }
    func testLatency200ms() {
        let (tb, r) = runMatch(humans: 2, format: .duel, conditions: LinkConditions(latency: 0.200, jitter: 0.015))
        XCTAssertGreaterThan(r.avgRTTms, 350)
        // At 400 ms RTT some inputs are necessarily too late; they are replaced, never duplicated.
        let (compared, replaced) = tb.inputMismatches(node: tb.nodes[1])
        XCTAssertGreaterThan(compared, 800)
        XCTAssertLessThan(Double(replaced) / Double(compared), 0.5)
    }

    // MARK: Loss / jitter / reordering

    func testPacketLoss1Percent() { runMatch(humans: 2, format: .duel, conditions: LinkConditions(latency: 0.02, jitter: 0.004, loss: 0.01)) }
    func testPacketLoss3Percent() { runMatch(humans: 4, format: .duo, conditions: LinkConditions(latency: 0.02, jitter: 0.004, loss: 0.03)) }
    func testPacketLoss5Percent() { runMatch(humans: 2, format: .duel, conditions: LinkConditions(latency: 0.03, jitter: 0.004, loss: 0.05)) }
    func testJitterReorderAndDuplication() {
        runMatch(humans: 3, format: .duo, conditions: LinkConditions(latency: 0.03, jitter: 0.02, loss: 0.02, duplicate: 0.2, reorder: 0.15))
    }

    // MARK: Team formats

    func testThreeVersusThree() { runMatch(humans: 6, format: .trio, conditions: LinkConditions(latency: 0.02, jitter: 0.004, loss: 0.01), seconds: 10) }

    func testEightPlayersSameWiFi() {
        let (tb, r) = runMatch(humans: 8, format: .squad, conditions: LinkConditions(latency: 0.008, jitter: 0.003, loss: 0.005), seconds: 12)
        XCTAssertEqual(tb.host.controller.setup?.slots.filter { !$0.isBot }.count, 8)
        XCTAssertEqual(r.lateInputs, 0)
        // Team assignment: 4 humans per team, indices 0-3 Ember, 4-7 Tide.
        let teams = tb.host.controller.engine!.state.players.map { $0.team }
        XCTAssertEqual(teams, [0, 0, 0, 0, 1, 1, 1, 1])
    }

    func testEightPlayersHighLatency() {
        runMatch(humans: 8, format: .squad, conditions: LinkConditions(latency: 0.1, jitter: 0.02, loss: 0.03, duplicate: 0.05, reorder: 0.05), seconds: 10)
    }

    func testBotsFillEmptySlots() {
        let (tb, _) = runMatch(humans: 3, format: .squad, conditions: .lan, seconds: 6)
        let slots = tb.host.controller.setup!.slots
        XCTAssertEqual(slots.filter { $0.isBot }.count, 5)
    }

    // MARK: Failures and recovery

    func testClientTemporaryDisconnectAndReconnect() {
        let tb = NetTestbed(TestbedConfig(humans: 3, settings: settings(.duo)))
        XCTAssertTrue(tb.connectAndStart())
        tb.run(seconds: 4)
        tb.setOffline(tb.nodes[2], true)
        tb.run(seconds: 5)
        if case .host(let h) = tb.host.controller.mode { XCTAssertEqual(h.connectedRemoteCount, 1) }
        tb.setOffline(tb.nodes[2], false)
        tb.run(seconds: 6)
        let r = tb.verify()
        XCTAssertTrue(r.consistent, "\(r)")
        XCTAssertGreaterThanOrEqual(r.snapshotsApplied, 1, "rejoin uses an authoritative snapshot")
        XCTAssertEqual(r.hostCount, 1)
        if case .host(let h) = tb.host.controller.mode { XCTAssertEqual(h.connectedRemoteCount, 2) }
    }

    func testHostDisconnectMigratesToNewHost() {
        let tb = NetTestbed(TestbedConfig(humans: 4, settings: settings(.duo), conditions: LinkConditions(latency: 0.02, jitter: 0.004, loss: 0.01)))
        XCTAssertTrue(tb.connectAndStart())
        tb.run(seconds: 8)
        let tickBefore = tb.nodes[1].controller.engine!.confirmedTick
        tb.setOffline(tb.host, true)                // host vanishes for good
        tb.run(seconds: 20)
        let survivors = Array(tb.nodes.dropFirst())
        let hosts = survivors.filter { $0.isHostMode }
        XCTAssertEqual(hosts.count, 1, "exactly one survivor becomes host")
        XCTAssertEqual(hosts.first?.name, "P1", "deterministic election: lowest member id")
        XCTAssertEqual(hosts.first?.hostEpoch, 2)
        let r = tb.verify(nodes: survivors, groundTruth: false, sinceTick: tickBefore)
        XCTAssertTrue(r.consistent, "\(r)")
        XCTAssertGreaterThan(survivors[0].controller.engine!.confirmedTick, tickBefore + 600, "match resumed")
        XCTAssertEqual(tb.maxHostsSameEpoch, 1)
    }

    func testHostBackgroundedBrieflyKeepsMatch() {
        let tb = NetTestbed(TestbedConfig(humans: 3, settings: settings(.duo)))
        XCTAssertTrue(tb.connectAndStart())
        tb.run(seconds: 4)
        tb.suspend(tb.host, true)
        tb.run(seconds: 1.2)
        tb.suspend(tb.host, false)
        tb.run(seconds: 6)
        let r = tb.verify()
        XCTAssertTrue(r.consistent, "\(r)")
        XCTAssertTrue(tb.host.isHostMode)
        XCTAssertEqual(r.transitions, [])
    }

    func testHostBackgroundedLongDemotesAndRejoins() {
        let tb = NetTestbed(TestbedConfig(humans: 3, settings: settings(.duo)))
        XCTAssertTrue(tb.connectAndStart())
        tb.run(seconds: 4)
        tb.suspend(tb.host, true)
        tb.run(seconds: 9)
        tb.suspend(tb.host, false)
        tb.run(seconds: 10)
        let r = tb.verify(groundTruth: false, sinceTick: 0)
        XCTAssertTrue(r.consistent, "\(r)")
        XCTAssertEqual(r.hostCount, 1, "the returning host does not compete with the new one")
        XCTAssertTrue(tb.nodes[1].isHostMode)
        XCTAssertTrue(r.transitions.contains { $0.contains("Host: demoted") }, "\(r.transitions)")
        XCTAssertEqual(tb.maxHostsSameEpoch, 1)
    }

    func testDesyncIsDetectedAndRepaired() {
        let tb = NetTestbed(TestbedConfig(humans: 2, settings: settings(.duel)))
        XCTAssertTrue(tb.connectAndStart())
        tb.run(seconds: 4)
        if case .client(let c) = tb.nodes[1].controller.mode { c.debugCorrupt() } else { XCTFail() }
        tb.run(seconds: 6)
        XCTAssertFalse(tb.host.controller.diagnostics.desyncLog.isEmpty, "mismatch recorded with tick info")
        let rec = tb.host.controller.diagnostics.desyncLog[0]
        XCTAssertGreaterThan(rec.firstMismatchTick, rec.lastMatchingTick)
        let since = tb.nodes[1].controller.engine!.currentTick - 240
        let r = tb.verify(sinceTick: since)
        XCTAssertTrue(r.consistent, "devices agree again after the corrective snapshot: \(r)")
        XCTAssertGreaterThanOrEqual(r.snapshotsApplied, 1)
    }

    func testPauseAndResume() {
        let tb = NetTestbed(TestbedConfig(humans: 2, settings: settings(.duel)))
        XCTAssertTrue(tb.connectAndStart())
        tb.run(seconds: 3)
        guard case .host(let h) = tb.host.controller.mode, case .client(let c) = tb.nodes[1].controller.mode else { return XCTFail() }
        c.requestPause()
        tb.run(seconds: 0.5)
        XCTAssertTrue(h.paused)
        XCTAssertTrue(c.paused)
        let frozen = h.engine!.currentTick
        tb.run(seconds: 2)
        XCTAssertEqual(h.engine!.currentTick, frozen)
        c.requestResume()
        tb.run(seconds: 5)
        XCTAssertFalse(h.paused)
        XCTAssertFalse(c.paused)
        XCTAssertGreaterThan(h.engine!.currentTick, frozen + 120)
        XCTAssertTrue(tb.verify().consistent)
    }

    // MARK: Lobby

    func testLobbyTeamsReadinessAndBlockers() throws {
        let net = SimulatedNetwork()
        let host = try HostSession(provider: net.provider(node: "h"), hostName: "Host",
                                   settings: MatchSettings(format: .duel, fillWithBots: false), seed: 1, now: 0)
        let browser = net.provider(node: "c").makeBrowser()
        browser.start()
        let ad = try XCTUnwrap(browser.rooms.first)
        XCTAssertEqual(ad.roomCode, host.roomCode)
        let client = try ClientSession(provider: net.provider(node: "c"), advert: ad, name: "Guest", token: 5, now: 0)
        var t = 0.0
        func pump(_ s: Double) {
            let end = t + s
            while t < end { t += 0.005; net.advance(to: t); host.update(now: t, input: nil); client.update(now: t, input: nil) }
        }
        pump(0.5)
        XCTAssertEqual(client.phase, .lobby)
        XCTAssertEqual(client.lobby?.members.count, 2)
        XCTAssertEqual(host.lobby.members(onTeam: 0).count, 1)
        XCTAssertEqual(host.lobby.members(onTeam: 1).count, 1, "new players balance onto the smaller team")
        XCTAssertFalse(host.canStart, "guest not ready")
        client.setTeam(0)
        pump(0.3)
        XCTAssertEqual(host.lobby.members(onTeam: 0).count, 1, "full team refuses the switch in 1v1")
        client.setReady(true)
        pump(0.3)
        XCTAssertTrue(host.canStart, "\(host.startBlockers)")
        XCTAssertTrue(host.startMatch())
        pump(0.5)
        XCTAssertEqual(client.phase, .match)
        XCTAssertEqual(client.setup, host.setup)
        XCTAssertEqual(client.localPlayer, 1)

        // Late joiner is refused while the match runs.
        let late = try ClientSession(provider: net.provider(node: "late"), advert: ad, name: "Late", token: 9, now: t)
        for _ in 0..<100 { t += 0.005; net.advance(to: t); host.update(now: t, input: nil); late.update(now: t, input: nil) }
        XCTAssertEqual(late.lastRejectReason, .matchInProgress)
    }

    func testSuspiciousInputsAreCountedAndSanitized() throws {
        let net = SimulatedNetwork()
        let host = try HostSession(provider: net.provider(node: "h"), hostName: "Host", settings: MatchSettings(format: .duel), seed: 1, now: 0)
        let ad = net.provider(node: "c").makeBrowser().roomsAfterStart().first!
        let client = try ClientSession(provider: net.provider(node: "c"), advert: ad, name: "Cheater", token: 5, now: 0)
        var t = 0.0
        let cheat = ConstantInputSource(PlayerInput(moveX: 127, moveY: 127, buttons: PlayerInput.autopilot | PlayerInput.pulse))
        func pump(_ s: Double) {
            let end = t + s
            while t < end { t += 0.005; net.advance(to: t); host.update(now: t, input: nil); client.update(now: t, input: cheat) }
        }
        pump(0.5)
        client.setReady(true)
        pump(0.3)
        XCTAssertTrue(host.startMatch())
        pump(3)
        XCTAssertGreaterThan(host.diagnostics.suspiciousInputs, 0)
        let e = try XCTUnwrap(host.engine)
        for tick in max(0, e.confirmedThrough[1] - 50)...e.confirmedThrough[1] {
            let i = try XCTUnwrap(e.confirmedInput(player: 1, tick: tick))
            XCTAssertFalse(i.isAutopilot, "clients cannot grant themselves the autopilot")
        }
    }
}

extension RoomBrowser {
    func roomsAfterStart() -> [RoomAdvert] { start(); return rooms }
}
