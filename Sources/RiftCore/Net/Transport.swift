// RIFT RIVALS — transport abstraction.
//
// Gameplay and session code never talk to sockets directly. A transport only
// moves opaque datagrams; reliability, ordering, acknowledgement and duplicate
// suppression live in `PeerLink` above it. This keeps the door open for
// internet P2P, relays or dedicated servers later: they only need to provide
// another `NetTransport` + `NetworkProvider`.

public typealias LinkID = Int

public enum TransportEvent: Sendable {
    case connected(LinkID)
    case received(LinkID, [UInt8])
    case disconnected(LinkID)
}

public protocol NetTransport: AnyObject {
    /// Move pending events into `events`. Called from the game loop thread.
    func poll(into events: inout [TransportEvent])
    /// Fire-and-forget datagram. Must never block.
    func send(_ bytes: [UInt8], to link: LinkID)
    func closeLink(_ link: LinkID)
    func shutdown()
}

/// A host transport additionally publishes its room for discovery.
public protocol HostTransport: NetTransport {
    func updateAdvert(_ advert: RoomAdvert)
}

/// Discovery record published by a host (Bonjour TXT record on iOS).
public struct RoomAdvert: Equatable, Sendable {
    public var roomCode: String
    public var hostName: String
    public var matchID: UInt32
    public var epoch: UInt16
    public var hostMemberID: UInt8
    public var players: UInt8
    public var capacity: UInt8
    public var format: MatchFormat
    public var inMatch: Bool
    public var protocolVersion: UInt8
    /// Opaque, provider-specific address (service name, "host:port", node id…).
    public var endpoint: String

    public init(roomCode: String, hostName: String, matchID: UInt32 = 0, epoch: UInt16 = 0, hostMemberID: UInt8 = 0,
                players: UInt8 = 1, capacity: UInt8 = 2, format: MatchFormat = .duel, inMatch: Bool = false,
                protocolVersion: UInt8 = NetProtocol.version, endpoint: String = "") {
        self.roomCode = roomCode
        self.hostName = hostName
        self.matchID = matchID
        self.epoch = epoch
        self.hostMemberID = hostMemberID
        self.players = players
        self.capacity = capacity
        self.format = format
        self.inMatch = inMatch
        self.protocolVersion = protocolVersion
        self.endpoint = endpoint
    }

    /// TXT-record style key/value encoding (shared by Bonjour and tests).
    public var txtRecord: [String: String] {
        ["rc": roomCode, "hn": hostName, "mid": String(matchID), "ep": String(epoch), "hm": String(hostMemberID),
         "pl": String(players), "cap": String(capacity), "fmt": String(format.rawValue),
         "im": inMatch ? "1" : "0", "pv": String(protocolVersion)]
    }

    public init?(txt: [String: String], endpoint: String) {
        guard let rc = txt["rc"], let pv = txt["pv"].flatMap(UInt8.init) else { return nil }
        self.init(roomCode: rc, hostName: txt["hn"] ?? "Host",
                  matchID: txt["mid"].flatMap(UInt32.init) ?? 0,
                  epoch: txt["ep"].flatMap(UInt16.init) ?? 0,
                  hostMemberID: txt["hm"].flatMap(UInt8.init) ?? 0,
                  players: txt["pl"].flatMap(UInt8.init) ?? 1,
                  capacity: txt["cap"].flatMap(UInt8.init) ?? 2,
                  format: txt["fmt"].flatMap(UInt8.init).flatMap(MatchFormat.init(rawValue:)) ?? .duel,
                  inMatch: txt["im"] == "1", protocolVersion: pv, endpoint: endpoint)
    }
}

public protocol RoomBrowser: AnyObject {
    /// Currently visible rooms (polled from the game/UI thread).
    var rooms: [RoomAdvert] { get }
    func start()
    func stop()
}

/// Factory for a concrete network technology (Bonjour+UDP, simulation, …).
public protocol NetworkProvider: AnyObject {
    func makeHost(advert: RoomAdvert) throws -> HostTransport
    /// Link 0 of the returned transport is the host.
    func makeClient(to advert: RoomAdvert) throws -> NetTransport
    func makeBrowser() -> RoomBrowser
}

public enum NetworkError: Error {
    case unavailable(String)
}
