// RIFT RIVALS — wire protocol.
//
// Packet := header, reliable messages (ordered, acked, resent), unreliable messages.
//
//   u16 magic 'RR' | u8 version | u8 flags | u32 sessionID | u16 epoch
//   u16 packetSeq  | u16 reliableAck
//   u8 reliableCount { u16 seq, u8 type, u16 len, bytes }
//   u8 unreliableCount { u8 type, u16 len, bytes }
//
// Inputs are sent unreliably but redundantly (every packet repeats all
// unacknowledged ticks), so a lost packet costs nothing and a duplicated or
// reordered one is ignored because inputs are keyed by tick.

public enum NetProtocol {
    public static let magic: UInt16 = 0x5252
    public static let version: UInt8 = 3
    public static let maxPacketBytes = 1200
    public static let bonjourType = "_riftrivals._udp"
}

public enum MessageType: UInt8 {
    case hello = 1, welcome, reject, lobby, lobbyRequest, startMatch, leave, ping, pong
    case input = 20, confirmed, stateHash, snapshot, control, rejoin, memberStatus
}

public enum RejectReason: UInt8 {
    case roomFull = 1, versionMismatch, matchInProgress, kicked, hostClosed, unknownPlayer
    public var text: String {
        switch self {
        case .roomFull: return "The room is full."
        case .versionMismatch: return "That room runs a different version of Rift Rivals."
        case .matchInProgress: return "A match is already in progress."
        case .kicked: return "You were removed by the host."
        case .hostClosed: return "The host closed the room."
        case .unknownPlayer: return "The host no longer recognises this player."
        }
    }
}

// MARK: - Message payloads

public struct HelloMsg: Equatable {
    public var name: String
    public var token: UInt64
    public var protocolVersion: UInt8
    public var buildNumber: UInt16
}

public struct WelcomeMsg: Equatable {
    public var memberID: UInt8
    public var roomCode: String
    public var epoch: UInt16
}

public struct LobbyMember: Equatable, Sendable {
    public var id: UInt8
    public var name: String
    public var team: UInt8
    public var ready: Bool
    public var connected: Bool
    public var isHost: Bool
    public var rttMs: UInt16

    public init(id: UInt8, name: String, team: UInt8, ready: Bool, connected: Bool, isHost: Bool, rttMs: UInt16 = 0) {
        self.id = id; self.name = name; self.team = team; self.ready = ready
        self.connected = connected; self.isHost = isHost; self.rttMs = rttMs
    }
}

public struct LobbyState: Equatable, Sendable {
    public var roomCode: String
    public var epoch: UInt16
    public var settings: MatchSettings
    public var members: [LobbyMember]
    public var inMatch: Bool
    public var revision: UInt32

    public init(roomCode: String, epoch: UInt16, settings: MatchSettings, members: [LobbyMember], inMatch: Bool, revision: UInt32) {
        self.roomCode = roomCode; self.epoch = epoch; self.settings = settings
        self.members = members; self.inMatch = inMatch; self.revision = revision
    }

    public func members(onTeam t: Int) -> [LobbyMember] { members.filter { Int($0.team) == t } }
    public var hostMember: LobbyMember? { members.first { $0.isHost } }
}

public enum LobbyRequest: Equatable {
    case setTeam(UInt8)
    case setReady(Bool)
    case setName(String)
    case requestPause
    case requestResume
}

public struct StartMatchMsg: Equatable {
    public var setup: MatchSetup
    public var memberIDs: [UInt8]      // parallels setup.slots (255 = bot)
    public var hostTickAtSend: Int32
}

public struct PingMsg: Equatable {
    public var seq: UInt16
    public var sendTime: Double
    /// Sender's measured inbound loss (per mille) and RTT, for display on the other side.
    public var lossPermille: UInt16
    public var rttMs: UInt16
}

public struct PongMsg: Equatable {
    public var seq: UInt16
    public var echoTime: Double
    /// Host simulation tick (fractional) at the moment of sending; -1 outside a match.
    public var hostTick: Double
    public var lossPermille: UInt16
}

public struct InputMsg: Equatable {
    public var player: UInt8
    public var firstTick: Int32
    public var inputs: [PlayerInput]
    /// Per-player highest contiguous confirmed tick the client holds (ack for the host).
    public var acks: [Int32]
    public var rttMs: UInt16
}

public struct InputRange: Equatable {
    public var player: UInt8
    public var firstTick: Int32
    public var inputs: [PlayerInput]
}

public struct ConfirmedMsg: Equatable {
    public var hostTick: Int32
    public var inputDelay: UInt8
    public var ranges: [InputRange]
    /// Latest verified host checksum (tick -1 if none yet).
    public var hashTick: Int32
    public var hash: UInt64
}

public struct StateHashMsg: Equatable {
    public var tick: Int32
    public var hash: UInt64
}

public struct SnapshotMsg: Equatable {
    public enum Reason: UInt8 { case desync = 1, rejoin, migration }
    public var matchID: UInt32
    public var tick: Int32
    public var reason: Reason
    public var state: [UInt8]
}

public enum ControlMsg: Equatable {
    case pause(tick: Int32, byMember: UInt8)
    case resume(tick: Int32, countdownTicks: Int16)
    case backToLobby
    case closeRoom
}

public struct RejoinMsg: Equatable {
    public var token: UInt64
    public var memberID: UInt8
    public var matchID: UInt32
    public var confirmedTick: Int32
    public var name: String
}

public struct MemberStatusMsg: Equatable {
    public struct Entry: Equatable { public var id: UInt8; public var connected: Bool; public var rttMs: UInt16 }
    public var entries: [Entry]
}

public enum NetMessage: Equatable {
    case hello(HelloMsg)
    case welcome(WelcomeMsg)
    case reject(RejectReason)
    case lobby(LobbyState)
    case lobbyRequest(LobbyRequest)
    case startMatch(StartMatchMsg)
    case leave
    case ping(PingMsg)
    case pong(PongMsg)
    case input(InputMsg)
    case confirmed(ConfirmedMsg)
    case stateHash(StateHashMsg)
    case snapshot(SnapshotMsg)
    case control(ControlMsg)
    case rejoin(RejoinMsg)
    case memberStatus(MemberStatusMsg)

    public var type: MessageType {
        switch self {
        case .hello: return .hello
        case .welcome: return .welcome
        case .reject: return .reject
        case .lobby: return .lobby
        case .lobbyRequest: return .lobbyRequest
        case .startMatch: return .startMatch
        case .leave: return .leave
        case .ping: return .ping
        case .pong: return .pong
        case .input: return .input
        case .confirmed: return .confirmed
        case .stateHash: return .stateHash
        case .snapshot: return .snapshot
        case .control: return .control
        case .rejoin: return .rejoin
        case .memberStatus: return .memberStatus
        }
    }
}

// MARK: - Codec

enum MessageCodec {
    static func writeSettings(_ s: MatchSettings, _ w: inout ByteWriter) {
        w.u8(s.format.rawValue); w.u16(s.roundSeconds); w.u8(s.goalsToWin); w.u8(s.bestOf)
        w.u8(s.arena.rawValue); w.u8(s.botDifficulty.rawValue); w.u8(s.modifiers.rawValue)
        w.bool(s.fillWithBots); w.bool(s.autopilotOnDisconnect)
    }

    static func readSettings(_ r: inout ByteReader) throws -> MatchSettings {
        guard let f = MatchFormat(rawValue: try r.u8()) else { throw ByteReaderError.invalid }
        let secs = try r.u16(), goals = try r.u8(), bestOf = try r.u8()
        guard let arena = ArenaID(rawValue: try r.u8()), let diff = BotDifficulty(rawValue: try r.u8()) else { throw ByteReaderError.invalid }
        let mods = Modifiers(rawValue: try r.u8())
        let fill = try r.bool(), auto = try r.bool()
        return MatchSettings(format: f, roundSeconds: secs, goalsToWin: goals, bestOf: bestOf, arena: arena,
                             botDifficulty: diff, modifiers: mods, fillWithBots: fill, autopilotOnDisconnect: auto).sanitized()
    }

    static func writeInput(_ i: PlayerInput, _ w: inout ByteWriter) { w.i8(i.moveX); w.i8(i.moveY); w.u8(i.buttons) }
    static func readInput(_ r: inout ByteReader) throws -> PlayerInput {
        PlayerInput(moveX: try r.i8(), moveY: try r.i8(), buttons: try r.u8())
    }

    static func encode(_ m: NetMessage, _ w: inout ByteWriter) {
        switch m {
        case .hello(let h):
            w.string(h.name); w.u64(h.token); w.u8(h.protocolVersion); w.u16(h.buildNumber)
        case .welcome(let x):
            w.u8(x.memberID); w.string(x.roomCode); w.u16(x.epoch)
        case .reject(let r):
            w.u8(r.rawValue)
        case .lobby(let l):
            w.string(l.roomCode); w.u16(l.epoch); writeSettings(l.settings, &w); w.bool(l.inMatch); w.u32(l.revision)
            w.u8(UInt8(l.members.count))
            for m in l.members {
                w.u8(m.id); w.string(m.name); w.u8(m.team); w.bool(m.ready); w.bool(m.connected); w.bool(m.isHost); w.u16(m.rttMs)
            }
        case .lobbyRequest(let r):
            switch r {
            case .setTeam(let t): w.u8(1); w.u8(t)
            case .setReady(let b): w.u8(2); w.bool(b)
            case .setName(let n): w.u8(3); w.string(n)
            case .requestPause: w.u8(4)
            case .requestResume: w.u8(5)
            }
        case .startMatch(let s):
            w.u32(s.setup.matchID); w.u64(s.setup.seed); writeSettings(s.setup.settings, &w)
            w.u8(UInt8(s.setup.slots.count))
            for (k, slot) in s.setup.slots.enumerated() {
                w.string(slot.name); w.bool(slot.isBot); w.u8(k < s.memberIDs.count ? s.memberIDs[k] : 255)
            }
            w.i32(s.hostTickAtSend)
        case .leave:
            break
        case .ping(let p):
            w.u16(p.seq); w.u64(p.sendTime.bitPattern); w.u16(p.lossPermille); w.u16(p.rttMs)
        case .pong(let p):
            w.u16(p.seq); w.u64(p.echoTime.bitPattern); w.u64(p.hostTick.bitPattern); w.u16(p.lossPermille)
        case .input(let i):
            w.u8(i.player); w.i32(i.firstTick); w.u8(UInt8(i.inputs.count))
            for x in i.inputs { writeInput(x, &w) }
            w.u8(UInt8(i.acks.count))
            for a in i.acks { w.i32(a) }
            w.u16(i.rttMs)
        case .confirmed(let c):
            w.i32(c.hostTick); w.u8(c.inputDelay); w.i32(c.hashTick); w.u64(c.hash)
            w.u8(UInt8(c.ranges.count))
            for r in c.ranges {
                w.u8(r.player); w.i32(r.firstTick); w.u8(UInt8(r.inputs.count))
                for x in r.inputs { writeInput(x, &w) }
            }
        case .stateHash(let h):
            w.i32(h.tick); w.u64(h.hash)
        case .snapshot(let s):
            w.u32(s.matchID); w.i32(s.tick); w.u8(s.reason.rawValue); w.blob(s.state)
        case .control(let c):
            switch c {
            case .pause(let t, let by): w.u8(1); w.i32(t); w.u8(by)
            case .resume(let t, let cd): w.u8(2); w.i32(t); w.i16(cd)
            case .backToLobby: w.u8(3)
            case .closeRoom: w.u8(4)
            }
        case .rejoin(let r):
            w.u64(r.token); w.u8(r.memberID); w.u32(r.matchID); w.i32(r.confirmedTick); w.string(r.name)
        case .memberStatus(let s):
            w.u8(UInt8(s.entries.count))
            for e in s.entries { w.u8(e.id); w.bool(e.connected); w.u16(e.rttMs) }
        }
    }

    static func decode(type: UInt8, _ payload: [UInt8]) throws -> NetMessage {
        guard let t = MessageType(rawValue: type) else { throw ByteReaderError.invalid }
        var r = ByteReader(payload)
        switch t {
        case .hello:
            return .hello(HelloMsg(name: try r.string(), token: try r.u64(), protocolVersion: try r.u8(), buildNumber: try r.u16()))
        case .welcome:
            return .welcome(WelcomeMsg(memberID: try r.u8(), roomCode: try r.string(), epoch: try r.u16()))
        case .reject:
            guard let reason = RejectReason(rawValue: try r.u8()) else { throw ByteReaderError.invalid }
            return .reject(reason)
        case .lobby:
            let code = try r.string(), epoch = try r.u16(), settings = try readSettings(&r)
            let inMatch = try r.bool(), rev = try r.u32()
            let n = Int(try r.u8())
            guard n <= 8 else { throw ByteReaderError.invalid }
            var members: [LobbyMember] = []
            for _ in 0..<n {
                members.append(LobbyMember(id: try r.u8(), name: try r.string(), team: try r.u8(), ready: try r.bool(),
                                           connected: try r.bool(), isHost: try r.bool(), rttMs: try r.u16()))
            }
            return .lobby(LobbyState(roomCode: code, epoch: epoch, settings: settings, members: members, inMatch: inMatch, revision: rev))
        case .lobbyRequest:
            switch try r.u8() {
            case 1: return .lobbyRequest(.setTeam(try r.u8()))
            case 2: return .lobbyRequest(.setReady(try r.bool()))
            case 3: return .lobbyRequest(.setName(try r.string()))
            case 4: return .lobbyRequest(.requestPause)
            case 5: return .lobbyRequest(.requestResume)
            default: throw ByteReaderError.invalid
            }
        case .startMatch:
            let mid = try r.u32(), seed = try r.u64(), settings = try readSettings(&r)
            let n = Int(try r.u8())
            guard n == settings.format.playerCount else { throw ByteReaderError.invalid }
            var slots: [RosterSlot] = []
            var ids: [UInt8] = []
            for _ in 0..<n {
                let name = try r.string(), bot = try r.bool(), id = try r.u8()
                slots.append(RosterSlot(name: name, isBot: bot, memberID: id == 255 ? nil : id))
                ids.append(id)
            }
            return .startMatch(StartMatchMsg(setup: MatchSetup(matchID: mid, seed: seed, settings: settings, slots: slots),
                                             memberIDs: ids, hostTickAtSend: try r.i32()))
        case .leave:
            return .leave
        case .ping:
            return .ping(PingMsg(seq: try r.u16(), sendTime: Double(bitPattern: try r.u64()), lossPermille: try r.u16(), rttMs: try r.u16()))
        case .pong:
            return .pong(PongMsg(seq: try r.u16(), echoTime: Double(bitPattern: try r.u64()), hostTick: Double(bitPattern: try r.u64()), lossPermille: try r.u16()))
        case .input:
            let player = try r.u8(), first = try r.i32(), n = Int(try r.u8())
            var inputs: [PlayerInput] = []
            inputs.reserveCapacity(n)
            for _ in 0..<n { inputs.append(try readInput(&r)) }
            let an = Int(try r.u8())
            guard an <= 8 else { throw ByteReaderError.invalid }
            var acks: [Int32] = []
            for _ in 0..<an { acks.append(try r.i32()) }
            return .input(InputMsg(player: player, firstTick: first, inputs: inputs, acks: acks, rttMs: try r.u16()))
        case .confirmed:
            let ht = try r.i32(), delay = try r.u8(), hashTick = try r.i32(), hash = try r.u64()
            let n = Int(try r.u8())
            guard n <= 8 else { throw ByteReaderError.invalid }
            var ranges: [InputRange] = []
            for _ in 0..<n {
                let p = try r.u8(), first = try r.i32(), c = Int(try r.u8())
                var inputs: [PlayerInput] = []
                inputs.reserveCapacity(c)
                for _ in 0..<c { inputs.append(try readInput(&r)) }
                ranges.append(InputRange(player: p, firstTick: first, inputs: inputs))
            }
            return .confirmed(ConfirmedMsg(hostTick: ht, inputDelay: delay, ranges: ranges, hashTick: hashTick, hash: hash))
        case .stateHash:
            return .stateHash(StateHashMsg(tick: try r.i32(), hash: try r.u64()))
        case .snapshot:
            let mid = try r.u32(), tick = try r.i32()
            guard let reason = SnapshotMsg.Reason(rawValue: try r.u8()) else { throw ByteReaderError.invalid }
            return .snapshot(SnapshotMsg(matchID: mid, tick: tick, reason: reason, state: try r.blob()))
        case .control:
            switch try r.u8() {
            case 1: return .control(.pause(tick: try r.i32(), byMember: try r.u8()))
            case 2: return .control(.resume(tick: try r.i32(), countdownTicks: try r.i16()))
            case 3: return .control(.backToLobby)
            case 4: return .control(.closeRoom)
            default: throw ByteReaderError.invalid
            }
        case .rejoin:
            return .rejoin(RejoinMsg(token: try r.u64(), memberID: try r.u8(), matchID: try r.u32(), confirmedTick: try r.i32(), name: try r.string()))
        case .memberStatus:
            let n = Int(try r.u8())
            guard n <= 8 else { throw ByteReaderError.invalid }
            var e: [MemberStatusMsg.Entry] = []
            for _ in 0..<n { e.append(MemberStatusMsg.Entry(id: try r.u8(), connected: try r.bool(), rttMs: try r.u16())) }
            return .memberStatus(MemberStatusMsg(entries: e))
        }
    }

    static func payload(_ m: NetMessage) -> [UInt8] {
        var w = ByteWriter(capacity: 64)
        encode(m, &w)
        return w.bytes
    }
}
