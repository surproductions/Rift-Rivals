// RIFT RIVALS — match configuration shared by every peer.

/// Team size. 1v1 … 4v4.
public enum MatchFormat: UInt8, CaseIterable, Codable, Sendable {
    case duel = 1, duo = 2, trio = 3, squad = 4

    public var teamSize: Int { Int(rawValue) }
    public var playerCount: Int { teamSize * 2 }
    public var label: String { "\(teamSize)v\(teamSize)" }
}

public enum BotDifficulty: UInt8, CaseIterable, Codable, Sendable {
    case easy = 0, normal = 1, hard = 2
    public var label: String {
        switch self { case .easy: return "Rookie"; case .normal: return "Veteran"; case .hard: return "Riftmaster" }
    }
}

/// Optional gameplay modifiers. Stored as a bitmask so it serializes compactly.
public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Two shards in play at once.
    public static let twinShards = Modifiers(rawValue: 1 << 0)
    /// Shards travel 35% faster.
    public static let hyperShard = Modifiers(rawValue: 1 << 1)
    /// Larger pulse radius, longer cooldown.
    public static let megaPulse = Modifiers(rawValue: 1 << 2)
    /// Dash disabled — pure positioning.
    public static let noDash = Modifiers(rawValue: 1 << 3)
    /// Any charged shard shatters an opponent on contact.
    public static let glassCannon = Modifiers(rawValue: 1 << 4)

    public static let all: [(Modifiers, String, String)] = [
        (.twinShards, "Twin Shards", "Two shards in the arena at once."),
        (.hyperShard, "Hyper Shard", "Shards fly 35% faster."),
        (.megaPulse, "Mega Pulse", "Bigger pulse, longer cooldown."),
        (.noDash, "Grounded", "Dashing is disabled."),
        (.glassCannon, "Glass Cannon", "Any charged shard shatters on contact."),
    ]
}

public struct MatchSettings: Equatable, Codable, Sendable {
    public var format: MatchFormat
    /// Round length in seconds. 0 = untimed (first to goal target).
    public var roundSeconds: UInt16
    /// Goals needed to win a round. 0 = no goal limit (timer decides).
    public var goalsToWin: UInt8
    /// Best-of rounds: 1, 3 or 5.
    public var bestOf: UInt8
    public var arena: ArenaID
    public var botDifficulty: BotDifficulty
    public var modifiers: Modifiers
    /// Empty slots are filled with bots when the match starts.
    public var fillWithBots: Bool
    /// Disconnected players are piloted by a bot until they return.
    public var autopilotOnDisconnect: Bool

    public init(format: MatchFormat = .duel,
                roundSeconds: UInt16 = 120,
                goalsToWin: UInt8 = 5,
                bestOf: UInt8 = 1,
                arena: ArenaID = .foundry,
                botDifficulty: BotDifficulty = .normal,
                modifiers: Modifiers = [],
                fillWithBots: Bool = true,
                autopilotOnDisconnect: Bool = true) {
        self.format = format
        self.roundSeconds = roundSeconds
        self.goalsToWin = goalsToWin
        self.bestOf = bestOf
        self.arena = arena
        self.botDifficulty = botDifficulty
        self.modifiers = modifiers
        self.fillWithBots = fillWithBots
        self.autopilotOnDisconnect = autopilotOnDisconnect
    }

    /// Rounds a team must win to take the match.
    public var roundsToWin: Int { Int(bestOf) / 2 + 1 }

    /// Sanitize values received from the network.
    public func sanitized() -> MatchSettings {
        var s = self
        if ![1, 3, 5].contains(s.bestOf) { s.bestOf = 1 }
        s.roundSeconds = min(s.roundSeconds, 600)
        s.goalsToWin = min(s.goalsToWin, 15)
        if s.roundSeconds == 0 && s.goalsToWin == 0 { s.goalsToWin = 5 }
        return s
    }
}

/// One entry of the match roster. Player index == position in the roster.
/// Indices 0..<teamSize are team 0 (Ember), teamSize..<2*teamSize are team 1 (Tide).
public struct RosterSlot: Equatable, Codable, Sendable {
    public var name: String
    public var isBot: Bool
    /// Lobby member id controlling the slot (nil for bots).
    public var memberID: UInt8?

    public init(name: String, isBot: Bool, memberID: UInt8?) {
        self.name = name
        self.isBot = isBot
        self.memberID = memberID
    }
}

/// Everything required to start an identical simulation on every device.
public struct MatchSetup: Equatable, Codable, Sendable {
    public var matchID: UInt32
    public var seed: UInt64
    public var settings: MatchSettings
    public var slots: [RosterSlot]

    public init(matchID: UInt32, seed: UInt64, settings: MatchSettings, slots: [RosterSlot]) {
        self.matchID = matchID
        self.seed = seed
        self.settings = settings
        self.slots = slots
    }

    public var playerCount: Int { slots.count }
    public var teamSize: Int { settings.format.teamSize }
    public func team(of player: Int) -> Int { player < teamSize ? 0 : 1 }
    public func playerIndex(forMember id: UInt8) -> Int? { slots.firstIndex { $0.memberID == id } }
}

public enum TeamInfo {
    public static let names = ["EMBER", "TIDE"]
}
