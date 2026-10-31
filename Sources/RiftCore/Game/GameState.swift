// RIFT RIVALS — the complete deterministic match state.
//
// Everything that influences future ticks lives here, so serializing this
// struct is enough for rollback, snapshots, reconnection and host migration.

/// One tick of input for one player. 3 bytes on the wire.
public struct PlayerInput: Equatable, Hashable, Sendable {
    public var moveX: Int8
    public var moveY: Int8
    public var buttons: UInt8

    public static let pulse: UInt8 = 1 << 0
    public static let dash: UInt8 = 1 << 1
    /// Set only by the host: the slot is piloted by the autopilot bot this tick.
    public static let autopilot: UInt8 = 1 << 7
    public static let clientAllowedMask: UInt8 = pulse | dash

    public static let neutral = PlayerInput(moveX: 0, moveY: 0, buttons: 0)

    public init(moveX: Int8, moveY: Int8, buttons: UInt8) {
        self.moveX = moveX
        self.moveY = moveY
        self.buttons = buttons
    }

    /// Build from an analog stick in [-1, 1]. Rendering/UI side only.
    public init(stickX: Double, stickY: Double, pulse: Bool, dash: Bool) {
        var x = stickX, y = stickY
        let m = (x * x + y * y).squareRoot()
        if m > 1 { x /= m; y /= m }
        moveX = Int8(clamping: Int((x * 127).rounded()))
        moveY = Int8(clamping: Int((y * 127).rounded()))
        buttons = (pulse ? PlayerInput.pulse : 0) | (dash ? PlayerInput.dash : 0)
    }

    public var isPulse: Bool { buttons & PlayerInput.pulse != 0 }
    public var isDash: Bool { buttons & PlayerInput.dash != 0 }
    public var isAutopilot: Bool { buttons & PlayerInput.autopilot != 0 }

    /// Host-side validation: strips host-only bits and clamps impossible stick vectors.
    /// Returns the sanitized input and whether the original was suspicious.
    public func validated() -> (PlayerInput, suspicious: Bool) {
        var out = self
        var suspicious = false
        if buttons & ~PlayerInput.clientAllowedMask != 0 {
            out.buttons &= PlayerInput.clientAllowedMask
            suspicious = true
        }
        if moveX == Int8.min { out.moveX = -127; suspicious = true }
        if moveY == Int8.min { out.moveY = -127; suspicious = true }
        let mx = Int(out.moveX), my = Int(out.moveY)
        let m2 = mx * mx + my * my
        if m2 > 127 * 127 + 254 { // allow rounding slack
            let m = Int(isqrt(Int64(m2)))
            out.moveX = Int8(mx * 127 / m)
            out.moveY = Int8(my * 127 / m)
            suspicious = true
        }
        return (out, suspicious)
    }

    /// What we assume a remote player does when their input has not arrived:
    /// keep moving the same way, but never invent button presses.
    public var predictedContinuation: PlayerInput {
        PlayerInput(moveX: moveX, moveY: moveY, buttons: buttons & PlayerInput.autopilot)
    }
}

public enum MatchPhase: UInt8, Sendable {
    case countdown = 0, playing = 1, goalScored = 2, roundOver = 3, matchOver = 4
}

public struct PlayerState: Equatable, Sendable {
    public var pos: FxVec = .zero
    public var vel: FxVec = .zero
    public var facing: FxVec = FxVec(1, 0)
    public var team: UInt8 = 0
    public var isBot: Bool = false
    public var pulseCooldown: Int16 = 0
    public var dashCooldown: Int16 = 0
    public var dashTicks: Int16 = 0
    public var staggerTicks: Int16 = 0
    /// > 0 while shattered (out of play, waiting to respawn).
    public var shatteredTicks: Int16 = 0
    /// Brief invulnerability after respawn.
    public var shieldTicks: Int16 = 0
    public var bufferedPulse: Int8 = 0
    public var bufferedDash: Int8 = 0
    public var prevButtons: UInt8 = 0
    public var portalCooldown: Int16 = 0
    /// Tick of the last pulse (for rendering the pulse ring).
    public var lastPulseTick: Int32 = -1000
    // Bot brain (also used by autopilot).
    public var botTarget: FxVec = .zero
    public var botThinkTimer: Int16 = 0
    public var botWantsPulse: Bool = false
    // Stats.
    public var goals: UInt16 = 0
    public var assists: UInt16 = 0
    public var shatters: UInt16 = 0
    public var timesShattered: UInt16 = 0
    public var pulses: UInt16 = 0
    public var parries: UInt16 = 0

    public init() {}

    public var isActive: Bool { shatteredTicks == 0 }
    public var isDashing: Bool { dashTicks > 0 }
}

public struct ShardState: Equatable, Sendable {
    public var pos: FxVec = .zero
    public var vel: FxVec = .zero
    /// Team colour of the shard (-1 neutral).
    public var owner: Int8 = -1
    /// Charge level 0…6. Charged shards (>= 2) shatter opponents.
    public var heat: UInt8 = 0
    public var heatTimer: Int16 = 0
    public var lastToucher: Int8 = -1
    public var prevToucher: Int8 = -1
    public var portalCooldown: Int16 = 0
    public var active: Bool = true

    public init() {}
}

public struct GameState: Equatable, Sendable {
    public var tick: Int32 = 0
    public var phase: MatchPhase = .countdown
    public var phaseTimer: Int32 = 0
    public var scores: (UInt8, UInt8) = (0, 0)
    public var roundWins: (UInt8, UInt8) = (0, 0)
    public var round: UInt8 = 1
    public var timeRemaining: Int32 = 0
    public var overtime: Bool = false
    public var lastGoalTeam: Int8 = -1
    public var lastGoalScorer: Int8 = -1
    public var lastRoundWinner: Int8 = -1
    public var matchWinner: Int8 = -1
    public var rng: DeterministicRNG = DeterministicRNG(seed: 0)
    public var players: [PlayerState] = []
    public var shards: [ShardState] = []

    public init() {}

    public static func == (a: GameState, b: GameState) -> Bool {
        a.tick == b.tick && a.phase == b.phase && a.phaseTimer == b.phaseTimer
            && a.scores == b.scores && a.roundWins == b.roundWins && a.round == b.round
            && a.timeRemaining == b.timeRemaining && a.overtime == b.overtime
            && a.lastGoalTeam == b.lastGoalTeam && a.lastGoalScorer == b.lastGoalScorer
            && a.lastRoundWinner == b.lastRoundWinner && a.matchWinner == b.matchWinner
            && a.rng == b.rng && a.players == b.players && a.shards == b.shards
    }

    public func score(team: Int) -> Int { Int(team == 0 ? scores.0 : scores.1) }
    public func rounds(team: Int) -> Int { Int(team == 0 ? roundWins.0 : roundWins.1) }
}

/// Things that happened during a tick — consumed by audio, haptics and effects.
/// Events are not part of the state; after a rollback they are regenerated and
/// de-duplicated by the presentation layer.
public enum GameEventKind: UInt8, Sendable {
    case pulse, perfectPulse, parry, clash, dash, shatter, respawn, wallBounce,
         portal, goal, countdownTick, roundStart, roundOver, matchOver, overtime, bodyBlock
}

public struct GameEvent: Equatable, Hashable, Sendable {
    public var tick: Int32
    public var kind: GameEventKind
    public var player: Int8
    public var team: Int8
    public var x: Int16
    public var y: Int16

    public init(tick: Int32, kind: GameEventKind, player: Int = -1, team: Int = -1, at pos: FxVec = .zero) {
        self.tick = tick
        self.kind = kind
        self.player = Int8(player)
        self.team = Int8(team)
        self.x = Int16(clamping: pos.x.intValue)
        self.y = Int16(clamping: pos.y.intValue)
    }
}
