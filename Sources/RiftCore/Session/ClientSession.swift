// RIFT RIVALS — client session.
//
// Keeps its simulation clock aligned with the host's tick timeline (never the
// wall clock of either device): RTT-compensated host tick samples drive a
// smoothed offset, and the local fixed-step clock is sped up or slowed down by
// a few percent to track it. Remote inputs are predicted, host confirmations
// trigger rollback when predictions were wrong.

public final class ClientSession {
    public enum Phase: Equatable { case connecting, lobby, match, reconnecting, migrating, closed(String) }

    public private(set) var phase: Phase = .connecting
    public let provider: NetworkProvider
    public let token: UInt64
    public var localName: String
    public private(set) var memberID: UInt8?
    public private(set) var lobby: LobbyState?
    public private(set) var engine: RollbackEngine?
    public private(set) var setup: MatchSetup?
    public private(set) var memberIDs: [UInt8] = []
    public private(set) var advert: RoomAdvert
    public private(set) var epoch: UInt16
    let sessionID: UInt32

    private var transport: NetTransport?
    private var link: PeerLink
    private var welcomed = false
    private var lastHelloSent: Double = -10
    private var now: Double
    private var clock = FixedStepClock()
    private var events: [TransportEvent] = []
    private var inbox: [NetMessage] = []

    // Time sync.
    private var tickOffset: Double = 0      // hostTick ≈ now * 60 + tickOffset
    private var hasOffset = false
    public private(set) var inputDelay: Int32 = 2
    private var localScheduled: Int32 = -1
    private var lastHashSent: Int32 = -1
    private var lastHashResend: Double = 0
    private var sendTick = false
    private var lastPeriodic: Double = 0

    public private(set) var paused = false
    public private(set) var pausedByMember: UInt8 = 255
    private var resumeAt: Double?
    public var resumeCountdown: Double? { resumeAt.map { max(0, $0 - now) } }

    // Host loss / migration.
    public let hostTimeout: Double = 2.5
    public let lobbyTimeout: Double = 5.0
    private var silenceSince: Double?
    private var reconnectStarted: Double?
    private var candidates: [UInt8] = []
    private var migrationIndex = 0
    private var migrationEpoch: UInt16 = 0
    private var migrationAttemptStarted: Double = 0
    private var browser: RoomBrowser?
    /// Set when this client must become the new host (handled by SessionController).
    public private(set) var promotionEpoch: UInt16?
    public private(set) var migrationsSurvived = 0

    public private(set) var diagnostics = NetDiagnostics()
    private var hashChecks = 0
    private var hashMismatches = 0
    private var desyncLog: [DesyncRecord] = []
    public private(set) var lastRejectReason: RejectReason?

    // MARK: - Init

    public init(provider: NetworkProvider, advert: RoomAdvert, name: String, token: UInt64, now: Double) throws {
        self.provider = provider
        self.advert = advert
        self.localName = NameRules.sanitize(name)
        self.token = token
        self.now = now
        self.sessionID = RoomCode.sessionID(for: advert.roomCode)
        self.epoch = advert.epoch
        self.link = PeerLink(link: 0, sessionID: sessionID, epoch: advert.epoch, now: now)
        self.transport = try provider.makeClient(to: advert)
    }

    /// Rejoin an in-progress match as an existing member (reconnect or demoted host).
    public convenience init(provider: NetworkProvider, rejoining advert: RoomAdvert, memberID: UInt8, matchID: UInt32,
                            name: String, token: UInt64, lobby: LobbyState?, now: Double) throws {
        try self.init(provider: provider, advert: advert, name: name, token: token, now: now)
        self.memberID = memberID
        self.rejoinMatchID = matchID
        self.lobby = lobby
        self.phase = .reconnecting
    }

    private var rejoinMatchID: UInt32?

    // MARK: - Requests

    public func setTeam(_ t: UInt8) { link.sendReliable(.lobbyRequest(.setTeam(t))) }
    public func setReady(_ r: Bool) { link.sendReliable(.lobbyRequest(.setReady(r))) }
    public func setName(_ n: String) { localName = NameRules.sanitize(n); link.sendReliable(.lobbyRequest(.setName(localName))) }
    public func requestPause() { link.sendReliable(.lobbyRequest(.requestPause)) }
    public func requestResume() { link.sendReliable(.lobbyRequest(.requestResume)) }

    public func leave() {
        if let p = link.buildPacket(now: now, unreliable: [.leave]) {
            transport?.send(p, to: 0); transport?.send(p, to: 0)
        }
        transport?.shutdown()
        transport = nil
        browser?.stop()
        phase = .closed("You left the room")
    }

    public var localPlayer: Int? { engine?.localPlayer }
    public var hostMemberID: UInt8? { lobby?.hostMember?.id }

    // MARK: - Update

    public func update(now: Double, input: LocalInputSource?) {
        self.now = now
        if case .closed = phase { return }
        receive()
        checkConnection()
        if phase == .match { runMatch(input: input) }
        flush()
        refreshDiagnostics()
    }

    /// Call after the app returns from the background: UDP traffic stopped while
    /// suspended, so reconnect proactively instead of waiting for timeouts.
    public func handleReturnFromBackground(awayFor seconds: Double) {
        guard seconds > 1, phase == .match || phase == .lobby else { return }
        beginReconnect()
    }

    private func receive() {
        guard let transport = transport else { return }
        events.removeAll(keepingCapacity: true)
        transport.poll(into: &events)
        for ev in events {
            switch ev {
            case .received(_, let bytes):
                inbox.removeAll(keepingCapacity: true)
                let result = link.parse(bytes, now: now, acceptEpoch: { [epoch] e in e == epoch }, out: &inbox)
                guard result == .ok else { continue }
                silenceSince = nil
                for m in inbox { handle(m) }
            case .disconnected:
                if phase == .match || phase == .lobby { silenceSince = silenceSince ?? now }
            case .connected:
                break
            }
        }
    }

    private func handle(_ m: NetMessage) {
        switch m {
        case .welcome(let w):
            welcomed = true
            memberID = w.memberID
            reconnectStarted = nil
            if phase == .connecting { phase = .lobby }
            if phase == .migrating {
                migrationsSurvived += 1
                phase = .match
            }
            if phase == .reconnecting { phase = engine != nil ? .match : .lobby }
            browser?.stop(); browser = nil
        case .reject(let r):
            lastRejectReason = r
            transport?.shutdown()
            phase = .closed(r.text)
        case .lobby(let l):
            if let old = lobby, old.revision > l.revision && old.epoch == l.epoch { break }
            lobby = l
        case .startMatch(let s):
            startMatch(s)
        case .pong(let p):
            link.handlePong(p, now: now)
            if p.hostTick >= 0 { addTimeSample(hostTick: p.hostTick, rtt: now - p.echoTime, weight: 0.15) }
        case .confirmed(let c):
            handleConfirmed(c)
        case .snapshot(let s):
            handleSnapshot(s)
        case .control(let c):
            handleControl(c)
        case .memberStatus(let s):
            guard var l = lobby else { break }
            for e in s.entries {
                if let k = l.members.firstIndex(where: { $0.id == e.id }) {
                    l.members[k].connected = e.connected
                    l.members[k].rttMs = e.rttMs
                }
            }
            lobby = l
        default:
            break
        }
    }

    private func startMatch(_ s: StartMatchMsg) {
        if let existing = setup, existing.matchID == s.setup.matchID, engine != nil {
            phase = .match
            return
        }
        setup = s.setup
        memberIDs = s.memberIDs
        let e = RollbackEngine(setup: s.setup, maxPrediction: 30)
        if let id = memberID { e.localPlayer = s.setup.playerIndex(forMember: id) }
        engine = e
        localScheduled = -1
        lastHashSent = -1
        paused = false
        resumeAt = nil
        hasOffset = false
        clock.reset(now: now)
        phase = .match
        // Initial estimate: the host started (or was at) hostTickAtSend roughly RTT/2 ago.
        addTimeSample(hostTick: Double(s.hostTickAtSend), rtt: link.stats.hasRTT ? link.stats.srtt : 0.03, weight: 1)
    }

    private func addTimeSample(hostTick: Double, rtt: Double, weight: Double) {
        let estimate = hostTick + (rtt / 2) * Double(Tuning.tickRate)
        let sample = estimate - now * Double(Tuning.tickRate)
        if !hasOffset || abs(sample - tickOffset) > 30 {
            tickOffset = sample
            hasOffset = true
        } else {
            tickOffset += (sample - tickOffset) * weight
        }
    }

    public var hostTickEstimate: Double { now * Double(Tuning.tickRate) + tickOffset }

    private func handleConfirmed(_ c: ConfirmedMsg) {
        guard let e = engine else { return }
        if c.inputDelay >= 1 && c.inputDelay <= 8 { inputDelay = Int32(c.inputDelay) }
        if !paused && link.stats.hasRTT { addTimeSample(hostTick: Double(c.hostTick), rtt: link.stats.srtt, weight: 0.02) }
        for r in c.ranges {
            let p = Int(r.player)
            guard p < e.playerCount else { continue }
            for (k, input) in r.inputs.enumerated() {
                let t = r.firstTick + Int32(k)
                if t <= e.confirmedThrough[p] { continue }
                if t != e.confirmedThrough[p] + 1 { break }
                e.confirm(player: p, tick: t, input)
            }
        }
        if c.hashTick >= 0, let mine = e.verifiedHash(at: c.hashTick) {
            hashChecks += 1
            if mine != c.hash {
                hashMismatches += 1
                if desyncLog.last?.firstMismatchTick != c.hashTick {
                    desyncLog.append(DesyncRecord(memberID: memberID ?? 255, lastMatchingTick: -1, firstMismatchTick: c.hashTick,
                                                  localHash: mine, remoteHash: c.hash))
                    if desyncLog.count > 20 { desyncLog.removeFirst() }
                }
                lastHashSent = -1 // report immediately so the host sends a correction
            }
        }
    }

    private func handleSnapshot(_ s: SnapshotMsg) {
        guard let e = engine, s.matchID == setup?.matchID else { return }
        for p in 0..<e.playerCount where !e.isBot(p) {
            if s.reason != .desync || e.confirmedThrough[p] < s.tick - 1 {
                e.resetConfirmed(player: p, through: s.tick - 1)
            }
        }
        try? e.applyAuthoritativeSnapshot(tick: s.tick, bytes: s.state, rewind: s.reason != .desync)
        if let lp = e.localPlayer { localScheduled = max(e.confirmedThrough[lp], min(localScheduled, e.currentTick + inputDelay)) }
        if s.reason != .desync { hasOffset = false }
    }

    private func handleControl(_ c: ControlMsg) {
        switch c {
        case .pause(_, let by):
            paused = true
            pausedByMember = by
            resumeAt = nil
        case .resume(_, let cd):
            resumeAt = now + Double(cd) / Double(Tuning.tickRate) - (link.stats.hasRTT ? link.stats.srtt / 2 : 0)
        case .backToLobby:
            engine = nil
            setup = nil
            paused = false
            phase = .lobby
        case .closeRoom:
            transport?.shutdown()
            phase = .closed(RejectReason.hostClosed.text)
        }
    }

    // MARK: - Match loop

    private func scheduleLocalInput(engine e: RollbackEngine, source: LocalInputSource?) {
        guard let lp = e.localPlayer else { return }
        let target = e.currentTick + inputDelay
        let input = source?.sampleInput(forTick: target) ?? .neutral
        if localScheduled < e.confirmedThrough[lp] { localScheduled = e.confirmedThrough[lp] }
        if target <= localScheduled { return }
        var t = localScheduled + 1
        while t <= target {
            e.setLocalInput(tick: t, t == target ? input : input.predictedContinuation)
            t += 1
        }
        localScheduled = target
    }

    private func runMatch(input: LocalInputSource?) {
        guard let e = engine else { return }
        if paused {
            if let r = resumeAt, now >= r {
                paused = false
                resumeAt = nil
                hasOffset = false
            }
            clock.reset(now: now)
            if paused { return }
        }
        if e.state.phase == .matchOver { clock.reset(now: now); return }
        let local = Double(e.currentTick) + clock.fraction
        let err = hasOffset ? hostTickEstimate - local : 0
        var rate = 1 + max(-0.06, min(0.06, err * 0.02))
        var extra = 0
        if err > 6 { extra = min(8, Int(err) - 2) }       // far behind: catch up now
        if err < -6 { rate = 0 }                            // far ahead: hold
        var due = clock.ticksDue(now: now, rate: rate)
        due += extra
        for _ in 0..<due {
            scheduleLocalInput(engine: e, source: input)
            if !e.advance() { clock.refund(1); break }
            sendTick = true
        }
        e.resolveRollback()
    }

    // MARK: - Connection health, reconnection, migration

    private func checkConnection() {
        let silence = now - link.stats.lastReceive
        switch phase {
        case .connecting:
            if silence > lobbyTimeout { phase = .closed("Could not reach the room") }
        case .lobby:
            if silence > lobbyTimeout { phase = .closed("Lost connection to the host") }
        case .match:
            if silence > hostTimeout { beginReconnect() }
        case .reconnecting:
            let started = reconnectStarted ?? now
            if setup == nil && rejoinMatchID == nil {
                if now - started > lobbyTimeout { phase = .closed("Lost connection to the host") }
            } else if now - started > 1.0 {
                // The host is still advertising? Then it is our link — keep trying for a while.
                let hostVisible = (browser?.rooms ?? []).contains {
                    $0.roomCode == advert.roomCode && $0.epoch == epoch && $0.hostMemberID == advert.hostMemberID
                }
                if (!hostVisible && now - started > 1.5) || now - started > 6 {
                    if engine != nil { startMigration() } else if now - started > 8 { phase = .closed("Lost connection to the host") }
                }
            }
        case .migrating:
            if now - migrationAttemptStarted > 5 {
                migrationIndex += 1
                migrationEpoch &+= 1
                tryCandidate()
            } else {
                lookForNewHost()
            }
        case .closed:
            break
        }
    }

    private func beginReconnect() {
        guard phase == .match || phase == .lobby else { return }
        phase = .reconnecting
        reconnectStarted = now
        welcomed = false
        reopenTransport(to: advert, epoch: epoch)
        if browser == nil { browser = provider.makeBrowser(); browser?.start() }
    }

    private func reopenTransport(to ad: RoomAdvert, epoch newEpoch: UInt16) {
        transport?.shutdown()
        transport = try? provider.makeClient(to: ad)
        let oldStats = link.stats
        link = PeerLink(link: 0, sessionID: sessionID, epoch: newEpoch, now: now)
        link.stats.srtt = oldStats.srtt
        link.stats.rttVar = oldStats.rttVar
        link.stats.hasRTT = oldStats.hasRTT
        advert = ad
        epoch = newEpoch
        lastHelloSent = -10
    }

    private func startMigration() {
        guard let l = lobby, let me = memberID else { phase = .closed("Lost connection to the host"); return }
        let oldHost = l.hostMember?.id ?? advert.hostMemberID
        candidates = l.members.filter { $0.id != oldHost }.map { $0.id }.sorted()
        if !candidates.contains(me) { candidates.append(me); candidates.sort() }
        migrationIndex = 0
        migrationEpoch = epoch &+ 1
        if browser == nil { browser = provider.makeBrowser(); browser?.start() }
        tryCandidate()
    }

    private func tryCandidate() {
        guard migrationIndex < candidates.count, let me = memberID else {
            phase = .closed("The host left and no one could take over the match")
            return
        }
        migrationAttemptStarted = now
        phase = .migrating
        if candidates[migrationIndex] == me {
            promotionEpoch = migrationEpoch
        } else {
            lookForNewHost()
        }
    }

    private func lookForNewHost() {
        guard let s = setup else { return }
        let rooms = (browser?.rooms ?? []).filter {
            $0.roomCode == advert.roomCode && $0.matchID == s.matchID && $0.epoch >= migrationEpoch
        }
        guard let best = rooms.max(by: { $0.epoch < $1.epoch }) else { return }
        if best.epoch == epoch && transport != nil { return }
        reopenTransport(to: best, epoch: best.epoch)
        migrationEpoch = best.epoch
        // Its candidate index may be further down the list.
        if let idx = candidates.firstIndex(of: best.hostMemberID) { migrationIndex = max(migrationIndex, idx) }
        migrationAttemptStarted = now
    }

    // MARK: - Sending

    private func flush() {
        guard let transport = transport else { return }
        if case .closed = phase { return }
        var unreliable: [NetMessage] = []
        let periodic = now - lastPeriodic > 0.1
        if periodic { lastPeriodic = now }

        if !welcomed && now - lastHelloSent > 0.25 {
            lastHelloSent = now
            if let id = memberID, let mid = setup?.matchID ?? rejoinMatchID, phase != .connecting {
                unreliable.append(.rejoin(RejoinMsg(token: token, memberID: id, matchID: mid,
                                                    confirmedTick: engine?.confirmedTick ?? -1, name: localName)))
            } else {
                unreliable.append(.hello(HelloMsg(name: localName, token: token, protocolVersion: NetProtocol.version, buildNumber: 1)))
            }
        }
        let pingInterval = phase == .match ? 0.2 : 0.5
        if welcomed && now - link.lastPingSent > pingInterval {
            unreliable.append(link.makePing(now: now))
        }
        if welcomed, phase == .match, let e = engine, let lp = e.localPlayer, sendTick || periodic {
            let first = max(e.confirmedThrough[lp] + 1, localScheduled - 31)
            var inputs: [PlayerInput] = []
            if first <= localScheduled {
                var t = first
                while t <= localScheduled {
                    inputs.append(e.localInput(tick: t) ?? .neutral)
                    t += 1
                }
            }
            unreliable.append(.input(InputMsg(player: UInt8(lp), firstTick: first, inputs: inputs,
                                              acks: e.confirmedThrough, rttMs: UInt16(clamping: link.stats.rttMs))))
            if let v = e.latestVerified, v.tick != lastHashSent || now - lastHashResend > 0.5 {
                lastHashSent = v.tick
                lastHashResend = now
                unreliable.append(.stateHash(StateHashMsg(tick: v.tick, hash: v.hash)))
            }
        }
        let needs = !unreliable.isEmpty || (link.hasPendingReliable && periodic) || (periodic && now - link.lastSend > 0.25)
        if needs, let packet = link.buildPacket(now: now, unreliable: unreliable) {
            transport.send(packet, to: 0)
        }
        sendTick = false
    }

    private func refreshDiagnostics() {
        var d = NetDiagnostics()
        d.isHost = false
        d.hostName = lobby?.hostMember?.name ?? advert.hostName
        d.epoch = epoch
        d.rttMs = link.stats.rttMs
        d.jitterMs = link.stats.jitterMs
        d.lossPercent = link.stats.lossPercent
        d.duplicatePackets = link.stats.duplicatesDropped
        d.inputDelay = Int(inputDelay)
        d.quality = phase == .reconnecting || phase == .migrating ? .reconnecting : link.stats.quality(now: now)
        d.hostTickEstimate = hostTickEstimate
        d.hashChecks = hashChecks
        d.hashMismatches = hashMismatches
        d.desyncLog = desyncLog
        if let e = engine {
            d.tick = e.currentTick
            d.confirmedTick = e.confirmedTick
            d.predictionDepth = Int(e.predictionDepth)
            d.rollbacks = e.stats.rollbacks
            d.rolledBackTicks = e.stats.rolledBackTicks
            d.maxRollbackDepth = e.stats.maxRollbackDepth
            d.stalls = e.stats.stalls
            d.snapshotsApplied = e.stats.snapshotsApplied
            d.stepMicros = e.stats.lastStepMicros
            if let v = e.latestVerified { d.lastHashTick = v.tick; d.lastHash = v.hash }
        }
        diagnostics = d
    }

    func stopTransport() {
        transport?.shutdown()
        transport = nil
        browser?.stop()
        browser = nil
    }

    /// Exposed for tests: corrupt the local simulation to exercise desync recovery.
    public func debugCorrupt() { engine?.debugCorruptState() }
}
