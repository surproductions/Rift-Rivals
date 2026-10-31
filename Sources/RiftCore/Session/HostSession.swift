// RIFT RIVALS — authoritative host.
//
// The host owns the room and decides the *confirmed input timeline*:
//   * Each remote input for tick T is accepted if it arrives before the host
//     reaches tick T + finalizeWindow; otherwise it is replaced by a filler.
//   * The decision depends only on tick indices, never on wall-clock times
//     of other devices, and the host's own input goes through the exact same
//     path with the same input delay as everyone else.
//   * The host never waits for a slow peer — one bad connection cannot freeze
//     the match for everybody; it only costs that player their late inputs.

public final class HostSession {
    public enum Phase: Equatable { case lobby, match, closed(String) }

    struct Member {
        var id: UInt8
        var name: String
        var team: UInt8
        var ready: Bool
        var connected: Bool
        var token: UInt64
        var link: LinkID?
        var isHost: Bool
        var lastSeen: Double
        var rttMs: UInt16
        var acks: [Int32]
        var lastSnapshotSent: Double = -10
        var lastGoodHashTick: Int32 = -1
        var hasRejoined = true
    }

    public private(set) var phase: Phase = .lobby
    public let roomCode: String
    public let sessionID: UInt32
    public private(set) var epoch: UInt16
    public private(set) var settings: MatchSettings
    public let localMemberID: UInt8
    public var localName: String

    let provider: NetworkProvider
    let transport: HostTransport
    var members: [Member] = []
    var links: [LinkID: PeerLink] = [:]
    var revision: UInt32 = 1
    var rng: DeterministicRNG

    public private(set) var engine: RollbackEngine?
    public private(set) var setup: MatchSetup?
    public private(set) var memberIDs: [UInt8] = []

    // Confirmation state (match only).
    let finalizeWindow: Int32 = 10
    let maxAhead: Int32 = 60
    private var pending: [[PlayerInput]] = []
    private var pendingTag: [[Int32]] = []
    private var lastArrival: [Double] = []
    public private(set) var inputDelay: Int32 = 2
    private var localScheduled: Int32 = -1
    private var clock = FixedStepClock()
    private var now: Double = 0

    public private(set) var paused = false
    public private(set) var pausedByMember: UInt8 = 255
    private var resumeAt: Double?
    public var resumeCountdown: Double? { resumeAt.map { max(0, $0 - now) } }
    private var pausesUsed: [Int] = [0, 0]
    public let pausesPerTeam = 2
    private var migrationPauseUntil: Double?
    /// When set, the host should hand over to a newer host (see SessionController).
    public private(set) var demotionTarget: RoomAdvert?
    private var browser: RoomBrowser?
    private var lastBrowseCheck: Double = 0
    private var lastStatusBroadcast: Double = 0
    private var lastLobbySend: Double = 0

    public private(set) var diagnostics = NetDiagnostics()
    private var lateInputs = 0
    private var suspicious = 0
    private var hashChecks = 0
    private var hashMismatches = 0
    private var desyncLog: [DesyncRecord] = []
    private var events: [TransportEvent] = []
    private var inbox: [NetMessage] = []

    public let linkTimeout: Double = 3.0

    // MARK: - Init

    public init(provider: NetworkProvider, hostName: String, settings: MatchSettings, seed: UInt64, now: Double) throws {
        self.provider = provider
        self.rng = DeterministicRNG(seed: seed)
        self.roomCode = RoomCode.make(rng: &rng)
        self.sessionID = RoomCode.sessionID(for: roomCode)
        self.epoch = 1
        self.settings = settings.sanitized()
        self.localMemberID = 0
        self.localName = NameRules.sanitize(hostName)
        self.now = now
        members.append(Member(id: 0, name: localName, team: 0, ready: true, connected: true, token: 0, link: nil,
                              isHost: true, lastSeen: now, rttMs: 0, acks: []))
        transport = try provider.makeHost(advert: RoomAdvert(roomCode: roomCode, hostName: localName))
        publishAdvert()
    }

    /// Host migration: a client takes over the match it was part of.
    public init(promoting client: ClientSession, newEpoch: UInt16, now: Double) throws {
        guard let engine = client.engine, let setup = client.setup, let lobby = client.lobby, let me = client.memberID else {
            throw NetworkError.unavailable("Nothing to migrate")
        }
        self.provider = client.provider
        self.rng = DeterministicRNG(seed: setup.seed ^ UInt64(newEpoch))
        self.roomCode = lobby.roomCode
        self.sessionID = RoomCode.sessionID(for: roomCode)
        self.epoch = newEpoch
        self.settings = setup.settings
        self.localMemberID = me
        self.localName = client.localName
        self.now = now
        let oldHost = lobby.hostMember?.id
        for m in lobby.members {
            members.append(Member(id: m.id, name: m.name, team: m.team, ready: true, connected: m.id == me, token: 0,
                                  link: nil, isHost: m.id == me, lastSeen: now, rttMs: 0, acks: [],
                                  hasRejoined: m.id == me || m.id == oldHost))
        }
        self.engine = engine
        self.setup = setup
        self.memberIDs = client.memberIDs
        self.phase = .match
        transport = try provider.makeHost(advert: RoomAdvert(roomCode: roomCode, hostName: localName, matchID: setup.matchID,
                                                              epoch: newEpoch, hostMemberID: me, inMatch: true))
        prepareConfirmationState(engine: engine)

        // Restart from the last state every device agrees on; predictions are dropped.
        let resume = engine.confirmedTick + 1
        var carried: [(Int, Int32, PlayerInput)] = []
        for p in 0..<engine.playerCount where !engine.isBot(p) {
            var t = resume
            while t <= engine.confirmedThrough[p], let i = engine.confirmedInput(player: p, tick: t) {
                carried.append((p, t, i)); t += 1
            }
        }
        engine.rewind(to: resume)
        for p in 0..<engine.playerCount where !engine.isBot(p) { engine.resetConfirmed(player: p, through: resume - 1) }
        for (p, t, i) in carried { storePending(player: p, tick: t, i) }
        drainPending()
        localScheduled = engine.confirmedThrough[engine.localPlayer ?? 0]
        paused = true
        pausedByMember = me
        migrationPauseUntil = now + 8
        revision = 1000 + UInt32(newEpoch)
        publishAdvert()
        browser = provider.makeBrowser()
        browser?.start()
    }

    // MARK: - Lobby API

    public var lobby: LobbyState {
        LobbyState(roomCode: roomCode, epoch: epoch, settings: settings,
                   members: members.map { LobbyMember(id: $0.id, name: $0.name, team: $0.team, ready: $0.ready,
                                                      connected: $0.connected, isHost: $0.isHost, rttMs: $0.rttMs) },
                   inMatch: phase == .match, revision: revision)
    }

    private func lobbyChanged() {
        revision &+= 1
        broadcastReliable(.lobby(lobby))
        publishAdvert()
    }

    private func publishAdvert() {
        let connectedHumans = members.filter { $0.connected }.count
        transport.updateAdvert(RoomAdvert(roomCode: roomCode, hostName: localName, matchID: setup?.matchID ?? 0, epoch: epoch,
                                          hostMemberID: localMemberID, players: UInt8(connectedHumans),
                                          capacity: UInt8(settings.format.playerCount), format: settings.format,
                                          inMatch: phase == .match))
    }

    @discardableResult
    public func updateSettings(_ s: MatchSettings) -> Bool {
        guard phase == .lobby else { return false }
        let new = s.sanitized()
        let size = new.format.teamSize
        // Rebalance teams if the format shrank.
        var t0 = members.filter { $0.team == 0 }.count
        var t1 = members.filter { $0.team == 1 }.count
        guard members.count <= size * 2 else { return false }
        for k in members.indices.reversed() {
            if members[k].team == 0 && t0 > size { members[k].team = 1; t0 -= 1; t1 += 1 }
            else if members[k].team == 1 && t1 > size { members[k].team = 0; t1 -= 1; t0 += 1 }
        }
        settings = new
        for k in members.indices where !members[k].isHost { members[k].ready = false }
        lobbyChanged()
        return true
    }

    @discardableResult
    public func setTeam(member id: UInt8, team: UInt8) -> Bool {
        guard phase == .lobby, team <= 1, let k = members.firstIndex(where: { $0.id == id }) else { return false }
        if members[k].team == team { return true }
        guard members.filter({ $0.team == team }).count < settings.format.teamSize else { return false }
        members[k].team = team
        if !members[k].isHost { members[k].ready = false }
        lobbyChanged()
        return true
    }

    public func kick(member id: UInt8) {
        guard id != localMemberID, let k = members.firstIndex(where: { $0.id == id }) else { return }
        if let l = members[k].link, let link = links[l] {
            transport.send(link.buildPacket(now: now, unreliable: [.reject(.kicked)]) ?? [], to: l)
            transport.closeLink(l)
            links[l] = nil
        }
        if phase == .lobby { members.remove(at: k) } else { members[k].connected = false; members[k].link = nil }
        lobbyChanged()
    }

    public var startBlockers: [String] {
        var out: [String] = []
        let size = settings.format.teamSize
        for t in 0..<2 {
            let c = members.filter { Int($0.team) == t }.count
            if c > size { out.append("\(TeamInfo.names[t]) has too many players") }
            if c < size && !settings.fillWithBots { out.append("\(TeamInfo.names[t]) needs \(size - c) more") }
        }
        let notReady = members.filter { !$0.ready && $0.connected }.map { $0.name }
        if !notReady.isEmpty { out.append("Waiting for: " + notReady.joined(separator: ", ")) }
        return out
    }

    public var canStart: Bool { phase == .lobby && startBlockers.isEmpty }

    /// Builds the roster (humans first per team, in join order, then bots) and starts.
    @discardableResult
    public func startMatch() -> Bool {
        guard canStart || phase == .match else { return false }
        let size = settings.format.teamSize
        var slots: [RosterSlot] = []
        var ids: [UInt8] = []
        for t in 0..<2 {
            let humans = members.filter { Int($0.team) == t }
            for k in 0..<size {
                if k < humans.count {
                    slots.append(RosterSlot(name: humans[k].name, isBot: false, memberID: humans[k].id))
                    ids.append(humans[k].id)
                } else {
                    slots.append(RosterSlot(name: BotNames.name(team: t, index: k), isBot: true, memberID: nil))
                    ids.append(255)
                }
            }
        }
        let s = MatchSetup(matchID: rng.next() | 1, seed: UInt64(rng.next()) << 32 | UInt64(rng.next()), settings: settings, slots: slots)
        beginMatch(s, ids: ids)
        return true
    }

    /// Same roster and settings, new seed.
    public func rematch() {
        guard phase == .match, let old = setup else { return }
        var s = old
        s.matchID = rng.next() | 1
        s.seed = UInt64(rng.next()) << 32 | UInt64(rng.next())
        // Players that left are replaced by bots.
        for k in s.slots.indices where !s.slots[k].isBot {
            if let id = s.slots[k].memberID, members.first(where: { $0.id == id })?.connected != true {
                s.slots[k] = RosterSlot(name: BotNames.name(team: s.team(of: k), index: k), isBot: true, memberID: nil)
            }
        }
        beginMatch(s, ids: s.slots.map { $0.memberID ?? 255 })
    }

    private func beginMatch(_ s: MatchSetup, ids: [UInt8]) {
        setup = s
        memberIDs = ids
        let e = RollbackEngine(setup: s, maxPrediction: finalizeWindow + 6)
        e.localPlayer = s.playerIndex(forMember: localMemberID)
        engine = e
        prepareConfirmationState(engine: e)
        localScheduled = -1
        paused = false
        resumeAt = nil
        pausesUsed = [0, 0]
        clock.reset(now: now)
        phase = .match
        for k in members.indices { members[k].acks = Array(repeating: -1, count: s.playerCount); members[k].lastGoodHashTick = -1 }
        broadcastReliable(.startMatch(StartMatchMsg(setup: s, memberIDs: ids, hostTickAtSend: 0)))
        lobbyChanged()
    }

    private func prepareConfirmationState(engine e: RollbackEngine) {
        pending = Array(repeating: Array(repeating: .neutral, count: 128), count: e.playerCount)
        pendingTag = Array(repeating: Array(repeating: -1, count: 128), count: e.playerCount)
        lastArrival = Array(repeating: now, count: e.playerCount)
        for k in members.indices where members[k].acks.count != e.playerCount {
            members[k].acks = Array(repeating: -1, count: e.playerCount)
        }
    }

    public func backToLobby() {
        guard phase == .match else { return }
        phase = .lobby
        engine = nil
        setup = nil
        paused = false
        members.removeAll { !$0.connected && !$0.isHost }
        for k in members.indices where !members[k].isHost { members[k].ready = false }
        broadcastReliable(.control(.backToLobby))
        lobbyChanged()
    }

    public func close() {
        for (l, link) in links {
            if let p = link.buildPacket(now: now, unreliable: [.control(.closeRoom), .reject(.hostClosed)]) {
                transport.send(p, to: l); transport.send(p, to: l)
            }
        }
        transport.shutdown()
        browser?.stop()
        phase = .closed("Room closed")
    }

    // MARK: - Pause

    public func pause(by member: UInt8? = nil) {
        guard phase == .match, let e = engine, !paused, e.state.phase != .matchOver else { return }
        let by = member ?? localMemberID
        if by != localMemberID {
            guard let p = setup?.playerIndex(forMember: by), let t = setup?.team(of: p), pausesUsed[t] < pausesPerTeam else { return }
            pausesUsed[t] += 1
        }
        paused = true
        pausedByMember = by
        resumeAt = nil
        broadcastReliable(.control(.pause(tick: e.currentTick, byMember: by)))
    }

    public func resume() {
        guard phase == .match, paused, resumeAt == nil, let e = engine else { return }
        resumeAt = now + 2
        migrationPauseUntil = nil
        broadcastReliable(.control(.resume(tick: e.currentTick, countdownTicks: 120)))
    }

    // MARK: - Update

    public func update(now: Double, input: LocalInputSource?) {
        self.now = now
        guard case .closed = phase else {
            receive()
            checkTimeouts()
            if phase == .match { runMatch(input: input) }
            checkCompetingHosts()
            flush()
            refreshDiagnostics()
            return
        }
    }

    private func receive() {
        events.removeAll(keepingCapacity: true)
        transport.poll(into: &events)
        for ev in events {
            switch ev {
            case .connected:
                break
            case .disconnected(let l):
                if let k = members.firstIndex(where: { $0.link == l }) { memberLost(k) }
                links[l] = nil
            case .received(let l, let bytes):
                guard let hdr = PeerLink.peekHeader(bytes), hdr.sessionID == sessionID else { continue }
                if hdr.epoch > epoch {
                    // Someone believes in a newer host. Handled via discovery.
                    continue
                }
                let link: PeerLink
                if let existing = links[l] { link = existing } else {
                    link = PeerLink(link: l, sessionID: sessionID, epoch: epoch, now: now)
                    links[l] = link
                }
                inbox.removeAll(keepingCapacity: true)
                let result = link.parse(bytes, now: now, acceptEpoch: { [epoch] e in e == epoch || e == 0 }, out: &inbox)
                guard result == .ok else { continue }
                if let k = members.firstIndex(where: { $0.link == l }) { members[k].lastSeen = now }
                for m in inbox { handle(m, from: link) }
            }
        }
    }

    private func memberIndex(link: LinkID) -> Int? { members.firstIndex { $0.link == link } }

    private func handle(_ m: NetMessage, from link: PeerLink) {
        switch m {
        case .hello(let h):
            handleHello(h, link: link)
        case .rejoin(let r):
            handleRejoin(r, link: link)
        case .ping(let p):
            link.stats.remoteRTTms = Int(p.rttMs)
            link.stats.outboundLoss = Double(p.lossPermille) / 1000
            if let k = memberIndex(link: link.link) { members[k].rttMs = p.rttMs }
            let hostTick = phase == .match && !paused ? Double(engine?.currentTick ?? 0) + clock.fraction : Double(engine?.currentTick ?? -1)
            queuePong(link: link, PongMsg(seq: p.seq, echoTime: p.sendTime, hostTick: phase == .match ? hostTick : -1,
                                          lossPermille: UInt16(min(1000, link.stats.inboundLoss * 1000))))
        case .lobbyRequest(let r):
            guard let k = memberIndex(link: link.link) else { return }
            switch r {
            case .setTeam(let t): setTeam(member: members[k].id, team: t)
            case .setReady(let b):
                if phase == .lobby { members[k].ready = b; lobbyChanged() }
            case .setName(let n):
                if phase == .lobby { members[k].name = NameRules.sanitize(n); lobbyChanged() }
            case .requestPause: pause(by: members[k].id)
            case .requestResume:
                if paused && pausedByMember == members[k].id { resume() }
            }
        case .leave:
            if let k = memberIndex(link: link.link) {
                if phase == .lobby {
                    members.remove(at: k)
                    lobbyChanged()
                } else {
                    memberLost(k)
                }
            }
            transport.closeLink(link.link)
            links[link.link] = nil
        case .input(let i):
            handleInput(i, link: link)
        case .stateHash(let h):
            handleHash(h, link: link)
        default:
            break
        }
    }

    private var pongQueue: [LinkID: [PongMsg]] = [:]
    private func queuePong(link: PeerLink, _ p: PongMsg) { pongQueue[link.link, default: []].append(p) }

    private func handleHello(_ h: HelloMsg, link: PeerLink) {
        if memberIndex(link: link.link) != nil { return } // welcome is already in flight (reliable)
        guard h.protocolVersion == NetProtocol.version else { sendReject(.versionMismatch, link); return }
        // Same device reconnecting (token match): reattach.
        if h.token != 0, let k = members.firstIndex(where: { $0.token == h.token && !$0.isHost }) {
            attach(k, link: link)
            if phase == .match { sendMatchCatchUp(k, link: link) }
            return
        }
        guard phase == .lobby else { sendReject(.matchInProgress, link); return }
        guard members.count < 8 else { sendReject(.roomFull, link); return }
        if members.count >= settings.format.playerCount {
            // Grow the format automatically so friends can always join (up to 4v4).
            let next = MatchFormat(rawValue: UInt8(min(4, (members.count + 2) / 2))) ?? .squad
            var s = settings; s.format = next; settings = s
        }
        var id: UInt8 = 1
        while members.contains(where: { $0.id == id }) { id += 1 }
        let t0 = members.filter { $0.team == 0 }.count, t1 = members.filter { $0.team == 1 }.count
        let team: UInt8 = t1 < t0 ? 1 : (t0 < t1 ? 0 : 1)
        members.append(Member(id: id, name: NameRules.sanitize(h.name), team: team, ready: false, connected: true,
                              token: h.token, link: link.link, isHost: false, lastSeen: now, rttMs: 0, acks: []))
        link.sendReliable(.welcome(WelcomeMsg(memberID: id, roomCode: roomCode, epoch: epoch)))
        lobbyChanged()
    }

    private func handleRejoin(_ r: RejoinMsg, link: PeerLink) {
        if memberIndex(link: link.link) != nil { return }
        guard phase == .match, let s = setup, r.matchID == s.matchID,
              let k = members.firstIndex(where: { $0.id == r.memberID && !$0.isHost }) else {
            sendReject(.unknownPlayer, link); return
        }
        // Tokens are checked when known (normal reconnect); after a migration the
        // new host has never seen them and trusts the member id on the local network.
        if members[k].token != 0 && members[k].token != r.token { sendReject(.unknownPlayer, link); return }
        if members[k].connected, let old = members[k].link, old != link.link { links[old] = nil }
        members[k].token = r.token
        attach(k, link: link)
        sendMatchCatchUp(k, link: link)
    }

    private func attach(_ k: Int, link: PeerLink) {
        members[k].link = link.link
        members[k].connected = true
        members[k].lastSeen = now
        members[k].hasRejoined = true
        link.sendReliable(.welcome(WelcomeMsg(memberID: members[k].id, roomCode: roomCode, epoch: epoch)))
        lobbyChanged()
        broadcastStatus()
        if let s = setup, let p = s.playerIndex(forMember: members[k].id) { lastArrival[p] = now }
    }

    /// Bring a (re)joining player into the running match with a verified snapshot.
    private func sendMatchCatchUp(_ k: Int, link: PeerLink) {
        guard let s = setup, let e = engine else { return }
        link.sendReliable(.startMatch(StartMatchMsg(setup: s, memberIDs: memberIDs, hostTickAtSend: e.currentTick)))
        sendSnapshot(k, link: link, reason: .rejoin)
        if paused {
            link.sendReliable(.control(.pause(tick: e.currentTick, byMember: pausedByMember)))
        }
    }

    private func sendSnapshot(_ k: Int, link: PeerLink, reason: SnapshotMsg.Reason) {
        guard let s = setup, let e = engine else { return }
        // Latest state every device must agree on: all inputs before it are confirmed.
        let tick = min(e.confirmedTick + 1, e.currentTick)
        guard let bytes = tick == e.currentTick ? StateCodec.encode(e.state) : e.snapshotBytes(at: tick) else { return }
        link.sendReliable(.snapshot(SnapshotMsg(matchID: s.matchID, tick: tick, reason: reason, state: bytes)))
        members[k].acks = Array(repeating: tick - 1, count: s.playerCount)
        members[k].lastSnapshotSent = now
    }

    private func sendReject(_ r: RejectReason, _ link: PeerLink) {
        if let p = link.buildPacket(now: now, unreliable: [.reject(r)]) { transport.send(p, to: link.link) }
    }

    private func memberLost(_ k: Int) {
        guard !members[k].isHost else { return }
        if phase == .lobby {
            members.remove(at: k)
        } else {
            members[k].connected = false
            if let l = members[k].link { links[l] = nil }
            members[k].link = nil
            broadcastStatus()
        }
        lobbyChanged()
    }

    private func checkTimeouts() {
        for k in members.indices.reversed() where !members[k].isHost && members[k].connected {
            if now - members[k].lastSeen > linkTimeout { memberLost(k) }
        }
    }

    // MARK: - Inputs

    private func storePending(player p: Int, tick: Int32, _ input: PlayerInput) {
        let s = Int(tick) & 127
        pending[p][s] = input
        pendingTag[p][s] = tick
    }

    private func drainPending() {
        guard let e = engine else { return }
        for p in 0..<e.playerCount where !e.isBot(p) && p != e.localPlayer {
            while true {
                let t = e.confirmedThrough[p] + 1
                let s = Int(t) & 127
                guard pendingTag[p][s] == t else { break }
                e.confirm(player: p, tick: t, pending[p][s])
            }
        }
    }

    private func handleInput(_ msg: InputMsg, link: PeerLink) {
        guard phase == .match, let e = engine, let s = setup, let k = memberIndex(link: link.link) else { return }
        guard let p = s.playerIndex(forMember: members[k].id), Int(msg.player) == p else { suspicious += 1; return }
        members[k].rttMs = msg.rttMs
        if msg.acks.count == s.playerCount {
            for q in 0..<s.playerCount { members[k].acks[q] = max(members[k].acks[q], msg.acks[q]) }
        }
        var arrived = false
        for (offset, raw) in msg.inputs.enumerated() {
            let t = msg.firstTick + Int32(offset)
            if t <= e.confirmedThrough[p] { continue }         // duplicate or already finalized (late)
            if t > e.currentTick + maxAhead { suspicious += 1; continue } // impossible future tick
            let (input, sus) = raw.validated()
            if sus { suspicious += 1 }
            storePending(player: p, tick: t, input)
            arrived = true
        }
        if arrived { lastArrival[p] = now }
        drainPending()
    }

    private func filler(player p: Int, engine e: RollbackEngine) -> PlayerInput {
        let since = now - lastArrival[p]
        let memberConnected = setup?.slots[p].memberID.flatMap { id in members.first { $0.id == id }?.connected } ?? false
        if (!memberConnected || since > 1.0) && settings.autopilotOnDisconnect {
            return PlayerInput(moveX: 0, moveY: 0, buttons: PlayerInput.autopilot)
        }
        if since < 0.3, let last = e.confirmedInput(player: p, tick: e.confirmedThrough[p]) {
            return last.predictedContinuation
        }
        return .neutral
    }

    private func finalizeLateInputs(engine e: RollbackEngine) {
        let deadline = e.currentTick - finalizeWindow
        for p in 0..<e.playerCount where !e.isBot(p) && p != e.localPlayer {
            while e.confirmedThrough[p] < deadline {
                let t = e.confirmedThrough[p] + 1
                let s = Int(t) & 127
                if pendingTag[p][s] == t {
                    e.confirm(player: p, tick: t, pending[p][s])
                } else {
                    e.confirm(player: p, tick: t, filler(player: p, engine: e))
                    if setup.flatMap({ $0.slots[p].memberID }).flatMap({ id in members.first { $0.id == id }?.connected }) == true {
                        lateInputs += 1
                    }
                }
            }
        }
    }

    private func scheduleLocalInput(engine e: RollbackEngine, source: LocalInputSource?) {
        guard let lp = e.localPlayer else { return }
        let target = e.currentTick + inputDelay
        let input = source?.sampleInput(forTick: target) ?? .neutral
        if localScheduled < e.confirmedThrough[lp] { localScheduled = e.confirmedThrough[lp] }
        if target <= localScheduled { return }
        var t = max(localScheduled + 1, e.confirmedThrough[lp] + 1)
        while t <= target {
            // Gap ticks (delay increased) repeat movement without re-pressing buttons.
            let i = t == target ? input : input.predictedContinuation
            e.confirm(player: lp, tick: t, i)
            t += 1
        }
        localScheduled = target
    }

    private func runMatch(input: LocalInputSource?) {
        guard let e = engine else { return }
        if paused {
            if let until = migrationPauseUntil, resumeAt == nil {
                if members.allSatisfy({ $0.hasRejoined }) || now > until { resume() }
            }
            if let r = resumeAt, now >= r {
                paused = false
                resumeAt = nil
                clock.reset(now: now)
            } else {
                clock.reset(now: now)
                return
            }
        }
        if e.state.phase == .matchOver { clock.reset(now: now); return }
        adaptInputDelay()
        let due = clock.ticksDue(now: now)
        for _ in 0..<due {
            scheduleLocalInput(engine: e, source: input)
            finalizeLateInputs(engine: e)
            if !e.advance() { clock.refund(1); break }
            sendTickPackets = true
        }
        e.resolveRollback()
    }

    /// One shared input delay for everybody (fairness), sized from the measured
    /// round-trip times but capped so the slowest link cannot make the game
    /// sluggish for all — beyond the cap, rollback absorbs the latency.
    private func adaptInputDelay() {
        let rtts = members.filter { $0.connected && !$0.isHost }.map { Int($0.rttMs) }
        let worst = rtts.max() ?? 0
        let ticks = Int32((Double(worst) / 1000 * 60 / 2).rounded(.up))
        let target = min(4, max(2, ticks))
        // Hysteresis so the delay doesn't flap.
        if target > inputDelay || target < inputDelay - 1 { inputDelay = target }
    }

    private func handleHash(_ h: StateHashMsg, link: PeerLink) {
        guard let e = engine, let k = memberIndex(link: link.link) else { return }
        guard let mine = e.verifiedHash(at: h.tick) else { return }
        hashChecks += 1
        if mine == h.hash {
            members[k].lastGoodHashTick = max(members[k].lastGoodHashTick, h.tick)
            return
        }
        hashMismatches += 1
        let rec = DesyncRecord(memberID: members[k].id, lastMatchingTick: members[k].lastGoodHashTick,
                               firstMismatchTick: h.tick, localHash: mine, remoteHash: h.hash)
        if desyncLog.last.map({ $0.memberID != rec.memberID || $0.firstMismatchTick != rec.firstMismatchTick }) ?? true {
            desyncLog.append(rec)
            if desyncLog.count > 20 { desyncLog.removeFirst() }
        }
        if now - members[k].lastSnapshotSent > 0.5 { sendSnapshot(k, link: link, reason: .desync) }
    }

    // MARK: - Host competition (migration safety)

    /// A host with no connected players that sees another live host for the
    /// same match steps down, so two authorities never coexist for long.
    private func checkCompetingHosts() {
        guard phase == .match, let s = setup else { return }
        if browser == nil { browser = provider.makeBrowser(); browser?.start() }
        guard now - lastBrowseCheck > 0.5 else { return }
        lastBrowseCheck = now
        let connectedRemotes = members.filter { $0.connected && !$0.isHost }.count
        guard connectedRemotes == 0, members.count > 1 else { return }
        for ad in browser?.rooms ?? [] where ad.matchID == s.matchID && ad.roomCode == roomCode {
            if ad.epoch == epoch && ad.hostMemberID == localMemberID { continue }
            let theyHavePlayers = ad.players > 1
            if theyHavePlayers || ad.epoch > epoch {
                demotionTarget = ad
                return
            }
        }
    }

    // MARK: - Sending

    private var sendTickPackets = false

    private func broadcastReliable(_ m: NetMessage) {
        for (l, link) in links where members.contains(where: { $0.link == l }) { link.sendReliable(m) }
    }

    private func broadcastStatus() {
        guard phase == .match else { return }
        let entries = members.map { MemberStatusMsg.Entry(id: $0.id, connected: $0.connected, rttMs: $0.rttMs) }
        broadcastReliable(.memberStatus(MemberStatusMsg(entries: entries)))
    }

    private func flush() {
        let inMatch = phase == .match && engine != nil
        let periodic = now - lastLobbySend > 0.1
        if periodic { lastLobbySend = now }
        if inMatch && now - lastStatusBroadcast > 2 {
            lastStatusBroadcast = now
            broadcastStatus()
        }
        for (l, link) in links {
            var unreliable: [NetMessage] = []
            if let pongs = pongQueue[l] { unreliable.append(contentsOf: pongs.map { .pong($0) }) }
            let k = memberIndex(link: l)
            if inMatch, let k = k, let e = engine, sendTickPackets || periodic {
                unreliable.append(.confirmed(confirmedMessage(for: k, engine: e)))
            }
            let needs = !unreliable.isEmpty || (link.hasPendingReliable && (periodic || sendTickPackets)) || (periodic && now - link.lastSend > 0.2)
            guard needs, let packet = link.buildPacket(now: now, unreliable: unreliable) else { continue }
            transport.send(packet, to: l)
        }
        pongQueue.removeAll(keepingCapacity: true)
        sendTickPackets = false
    }

    private func confirmedMessage(for k: Int, engine e: RollbackEngine) -> ConfirmedMsg {
        var ranges: [InputRange] = []
        let humans = max(1, (0..<e.playerCount).filter { !e.isBot($0) }.count)
        let cap = Int32(min(48, 280 / humans))
        for p in 0..<e.playerCount where !e.isBot(p) {
            let ack = k < members.count && members[k].acks.count == e.playerCount ? members[k].acks[p] : -1
            let from = max(ack + 1, e.confirmedThrough[p] - cap + 1, 0)
            guard from <= e.confirmedThrough[p] else { continue }
            var inputs: [PlayerInput] = []
            var t = from
            while t <= e.confirmedThrough[p], let i = e.confirmedInput(player: p, tick: t) {
                inputs.append(i); t += 1
            }
            if !inputs.isEmpty { ranges.append(InputRange(player: UInt8(p), firstTick: from, inputs: inputs)) }
        }
        let v = e.latestVerified
        return ConfirmedMsg(hostTick: e.currentTick, inputDelay: UInt8(inputDelay), ranges: ranges,
                            hashTick: v?.tick ?? -1, hash: v?.hash ?? 0)
    }

    private func refreshDiagnostics() {
        var d = NetDiagnostics()
        d.isHost = true
        d.hostName = localName
        d.epoch = epoch
        if let e = engine {
            d.tick = e.currentTick
            d.confirmedTick = e.confirmedTick
            d.hostTickEstimate = Double(e.currentTick)
            d.predictionDepth = Int(e.predictionDepth)
            d.rollbacks = e.stats.rollbacks
            d.rolledBackTicks = e.stats.rolledBackTicks
            d.maxRollbackDepth = e.stats.maxRollbackDepth
            d.stalls = e.stats.stalls
            d.snapshotsApplied = e.stats.snapshotsApplied
            d.stepMicros = e.stats.lastStepMicros
            if let v = e.latestVerified { d.lastHashTick = v.tick; d.lastHash = v.hash }
        }
        let remote = links.values.filter { l in members.contains { $0.link == l.link } }
        d.rttMs = remote.map { max($0.stats.remoteRTTms, $0.stats.rttMs) }.max() ?? 0
        d.jitterMs = remote.map { $0.stats.jitterMs }.max() ?? 0
        d.lossPercent = remote.map { $0.stats.lossPercent }.max() ?? 0
        d.duplicatePackets = remote.reduce(0) { $0 + $1.stats.duplicatesDropped }
        d.inputDelay = Int(inputDelay)
        d.lateInputs = lateInputs
        d.suspiciousInputs = suspicious
        d.hashChecks = hashChecks
        d.hashMismatches = hashMismatches
        d.desyncLog = desyncLog
        let qualities = remote.map { $0.stats.quality(now: now).rawValue }
        d.quality = ConnectionQuality(rawValue: qualities.max() ?? 0) ?? .excellent
        diagnostics = d
    }

    /// Per-member connection quality for the scoreboard / lobby.
    public func quality(ofMember id: UInt8) -> ConnectionQuality {
        guard let m = members.first(where: { $0.id == id }) else { return .reconnecting }
        if m.isHost { return .excellent }
        guard m.connected, let l = m.link, let link = links[l] else { return .reconnecting }
        return link.stats.quality(now: now)
    }

    public var connectedRemoteCount: Int { members.filter { $0.connected && !$0.isHost }.count }
}

public enum BotNames {
    static let ember = ["Cinder", "Flint", "Blaze", "Ash"]
    static let tide = ["Ripple", "Brine", "Surge", "Mist"]
    public static func name(team: Int, index: Int) -> String {
        let list = team == 0 ? ember : tide
        return "\(list[index % list.count]) [BOT]"
    }
}
