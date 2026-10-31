// RIFT RIVALS — the deterministic simulation step.
//
// `Simulation.step` is a pure function of (state, inputs). It runs at a fixed
// 60 ticks per second regardless of the display refresh rate and uses only
// integer / fixed-point arithmetic. Simultaneous actions (two players pulsing
// the same shard on the same tick) are resolved order-independently so player
// index never decides an outcome.

public enum Tuning {
    public static let tickRate = 60

    public static let playerRadius = Fx(28)
    public static let shardRadius = Fx(20)
    public static let playerMaxSpeed = Fx.ratio(15, 2)          // 7.5 u/tick = 450 u/s
    public static let playerAccel = Fx.ratio(18, 100)           // velocity lerp factor
    public static let staggerAccel = Fx.ratio(4, 100)

    public static let dashSpeed = Fx(19)
    public static let dashTicks: Int16 = 8
    public static let dashCooldown: Int16 = 80

    public static let pulseRadius = Fx(118)
    public static let pulseCooldown: Int16 = 32
    public static let perfectPulseDistance = Fx(72)
    public static let pulseBaseSpeed = Fx(10)
    public static let pulseHeatSpeed = Fx.ratio(23, 10)
    public static let perfectBonusSpeed = Fx(4)
    public static let enemyKnockback = Fx(11)
    public static let allySlingshot = Fx(8)
    public static let staggerTicks: Int16 = 18
    public static let inputBufferTicks: Int8 = 8

    public static let shardDrag = Fx.ratio(993, 1000)
    public static let shardBaseMaxSpeed = Fx(14)
    public static let shardHeatMaxSpeed = Fx.ratio(5, 2)
    public static let shardWallRestitution = Fx.ratio(92, 100)
    public static let shardBodyRestitution = Fx.ratio(70, 100)
    public static let maxHeat: UInt8 = 6
    public static let shatterHeat: UInt8 = 2
    public static let shatterMinSpeed = Fx(9)
    public static let heatDecayTicks: Int16 = 75

    public static let shatterRespawnTicks: Int16 = 96
    public static let respawnShieldTicks: Int16 = 45

    public static let roundCountdownTicks: Int32 = 180
    public static let kickoffCountdownTicks: Int32 = 90
    public static let goalCelebrationTicks: Int32 = 120
    public static let roundOverTicks: Int32 = 210
}

public struct SimContext: Sendable {
    public let setup: MatchSetup
    public let arena: Arena
    public let teamSize: Int
    public let pulseRadius: Fx
    public let pulseCooldown: Int16
    public let shardSpeedScale: Fx
    public let shatterHeat: UInt8

    public init(setup: MatchSetup) {
        self.setup = setup
        self.arena = Arena.all[setup.settings.arena] ?? Arena.make(setup.settings.arena)
        self.teamSize = setup.teamSize
        let mods = setup.settings.modifiers
        pulseRadius = mods.contains(.megaPulse) ? Tuning.pulseRadius * Fx.ratio(14, 10) : Tuning.pulseRadius
        pulseCooldown = mods.contains(.megaPulse) ? 48 : Tuning.pulseCooldown
        shardSpeedScale = mods.contains(.hyperShard) ? Fx.ratio(135, 100) : Fx.one
        shatterHeat = mods.contains(.glassCannon) ? 1 : Tuning.shatterHeat
    }

    public func team(of player: Int) -> Int { player < teamSize ? 0 : 1 }
}

public enum Simulation {

    // MARK: - Setup

    public static func initialState(_ ctx: SimContext) -> GameState {
        var s = GameState()
        s.rng = DeterministicRNG(seed: ctx.setup.seed)
        s.players = (0..<ctx.setup.playerCount).map { i in
            var p = PlayerState()
            p.team = UInt8(ctx.team(of: i))
            p.isBot = ctx.setup.slots[i].isBot
            return p
        }
        let shardCount = ctx.setup.settings.modifiers.contains(.twinShards) ? 2 : 1
        s.shards = Array(repeating: ShardState(), count: shardCount)
        startRound(&s, ctx)
        return s
    }

    static func startRound(_ s: inout GameState, _ ctx: SimContext) {
        s.scores = (0, 0)
        s.overtime = false
        s.timeRemaining = Int32(ctx.setup.settings.roundSeconds) * Int32(Tuning.tickRate)
        resetPositions(&s, ctx)
        s.phase = .countdown
        s.phaseTimer = Tuning.roundCountdownTicks
    }

    static func resetPositions(_ s: inout GameState, _ ctx: SimContext) {
        for i in s.players.indices {
            let team = ctx.team(of: i)
            s.players[i].pos = ctx.arena.spawnPoint(team: team, indexInTeam: i % ctx.teamSize, teamSize: ctx.teamSize)
            s.players[i].vel = .zero
            s.players[i].facing = FxVec(team == 0 ? 1 : -1, 0)
            s.players[i].dashTicks = 0
            s.players[i].staggerTicks = 0
            s.players[i].shatteredTicks = 0
            s.players[i].shieldTicks = 0
            s.players[i].pulseCooldown = 0
            s.players[i].dashCooldown = 0
            s.players[i].bufferedDash = 0
            s.players[i].bufferedPulse = 0
            s.players[i].botThinkTimer = 0
        }
        let kick = ctx.arena.kickoffPoints(shardCount: s.shards.count)
        for i in s.shards.indices {
            s.shards[i] = ShardState()
            s.shards[i].pos = kick[i]
        }
    }

    // MARK: - Step

    /// Advance the state by exactly one tick.
    /// - Parameters:
    ///   - inputs: one input per player (index == player index).
    ///   - events: appended with presentation events for this tick.
    public static func step(_ s: inout GameState, inputs: [PlayerInput], ctx: SimContext, events: inout [GameEvent]) {
        let tick = s.tick
        let n = s.players.count

        // Resolve bot / autopilot inputs from the state at the start of the tick.
        var resolved = inputs
        if resolved.count < n { resolved.append(contentsOf: repeatElement(.neutral, count: n - resolved.count)) }
        for i in 0..<n where s.players[i].isBot || resolved[i].isAutopilot {
            resolved[i] = BotBrain.decide(&s, player: i, ctx: ctx,
                                          difficulty: s.players[i].isBot ? ctx.setup.settings.botDifficulty : .normal)
        }

        switch s.phase {
        case .countdown:
            if s.phaseTimer % 60 == 0 && s.phaseTimer > 0 {
                events.append(GameEvent(tick: tick, kind: .countdownTick, player: Int(s.phaseTimer / 60)))
            }
            s.phaseTimer -= 1
            for i in 0..<n { s.players[i].prevButtons = resolved[i].buttons }
            if s.phaseTimer <= 0 {
                s.phase = .playing
                events.append(GameEvent(tick: tick, kind: .roundStart))
            }
        case .playing:
            simulatePlay(&s, resolved, ctx, &events)
            if s.phase == .playing && ctx.setup.settings.roundSeconds > 0 && !s.overtime {
                s.timeRemaining -= 1
                if s.timeRemaining <= 0 {
                    s.timeRemaining = 0
                    if s.scores.0 == s.scores.1 {
                        s.overtime = true
                        events.append(GameEvent(tick: tick, kind: .overtime))
                    } else {
                        endRound(&s, ctx, winner: s.scores.0 > s.scores.1 ? 0 : 1, &events)
                    }
                }
            }
        case .goalScored:
            // Players keep moving during the celebration; the shard is gone.
            simulatePlay(&s, resolved, ctx, &events, allowActions: false)
            s.phaseTimer -= 1
            if s.phaseTimer <= 0 {
                let goalCap = Int(ctx.setup.settings.goalsToWin)
                let t0 = Int(s.scores.0), t1 = Int(s.scores.1)
                if s.overtime {
                    endRound(&s, ctx, winner: t0 > t1 ? 0 : 1, &events)
                } else if goalCap > 0 && (t0 >= goalCap || t1 >= goalCap) {
                    endRound(&s, ctx, winner: t0 >= goalCap ? 0 : 1, &events)
                } else {
                    resetPositions(&s, ctx)
                    s.phase = .countdown
                    s.phaseTimer = Tuning.kickoffCountdownTicks
                }
            }
        case .roundOver:
            s.phaseTimer -= 1
            for i in 0..<n { s.players[i].prevButtons = resolved[i].buttons }
            if s.phaseTimer <= 0 {
                let need = ctx.setup.settings.roundsToWin
                if Int(s.roundWins.0) >= need || Int(s.roundWins.1) >= need {
                    s.phase = .matchOver
                    s.matchWinner = Int8(s.roundWins.0 >= s.roundWins.1 ? 0 : 1)
                    events.append(GameEvent(tick: tick, kind: .matchOver, team: Int(s.matchWinner)))
                } else {
                    s.round += 1
                    startRound(&s, ctx)
                }
            }
        case .matchOver:
            break
        }
        s.tick += 1
    }

    static func endRound(_ s: inout GameState, _ ctx: SimContext, winner: Int, _ events: inout [GameEvent]) {
        if winner == 0 { s.roundWins.0 += 1 } else { s.roundWins.1 += 1 }
        s.lastRoundWinner = Int8(winner)
        s.phase = .roundOver
        s.phaseTimer = Tuning.roundOverTicks
        for i in s.shards.indices { s.shards[i].active = false }
        events.append(GameEvent(tick: s.tick, kind: .roundOver, team: winner))
    }

    // MARK: - Play

    struct PulseHit {
        var dirSum: FxVec = .zero
        var speed: Fx = .zero
        var teams: UInt8 = 0      // bit 0 = team 0, bit 1 = team 1
        var perfect = false
        var heatGain: UInt8 = 0
        var toucher: Int = -1
    }

    static func simulatePlay(_ s: inout GameState, _ inputs: [PlayerInput], _ ctx: SimContext,
                             _ events: inout [GameEvent], allowActions: Bool = true) {
        let tick = s.tick
        let n = s.players.count
        let mods = ctx.setup.settings.modifiers
        var pulsers: [Int] = []

        // 1. Player control and movement.
        for i in 0..<n {
            var p = s.players[i]
            let input = inputs[i]
            let pressed = input.buttons & ~p.prevButtons
            p.prevButtons = input.buttons

            if p.shatteredTicks > 0 {
                p.shatteredTicks -= 1
                if p.shatteredTicks == 0 {
                    p.pos = ctx.arena.spawnPoint(team: Int(p.team), indexInTeam: i % ctx.teamSize, teamSize: ctx.teamSize)
                    p.vel = .zero
                    p.shieldTicks = Tuning.respawnShieldTicks
                    events.append(GameEvent(tick: tick, kind: .respawn, player: i, team: Int(p.team), at: p.pos))
                }
                s.players[i] = p
                continue
            }

            if p.pulseCooldown > 0 { p.pulseCooldown -= 1 }
            if p.dashCooldown > 0 { p.dashCooldown -= 1 }
            if p.staggerTicks > 0 { p.staggerTicks -= 1 }
            if p.shieldTicks > 0 { p.shieldTicks -= 1 }
            if p.portalCooldown > 0 { p.portalCooldown -= 1 }
            if p.bufferedPulse > 0 { p.bufferedPulse -= 1 }
            if p.bufferedDash > 0 { p.bufferedDash -= 1 }

            let stick = FxVec(x: Fx(raw: Int64(input.moveX) << 16 / 127), y: Fx(raw: Int64(input.moveY) << 16 / 127))
            let stickDir = stick.normalized
            let hasStick = stick.lengthSquaredRaw > (Fx.ratio(15, 100).raw * Fx.ratio(15, 100).raw)
            if hasStick { p.facing = stickDir }

            if allowActions {
                if pressed & PlayerInput.dash != 0 { p.bufferedDash = Tuning.inputBufferTicks }
                if pressed & PlayerInput.pulse != 0 { p.bufferedPulse = Tuning.inputBufferTicks }

                if p.bufferedDash > 0 && p.dashCooldown == 0 && p.dashTicks == 0 && !mods.contains(.noDash) {
                    p.bufferedDash = 0
                    p.dashTicks = Tuning.dashTicks
                    p.dashCooldown = Tuning.dashCooldown
                    p.vel = (hasStick ? stickDir : p.facing) * Tuning.dashSpeed
                    events.append(GameEvent(tick: tick, kind: .dash, player: i, team: Int(p.team), at: p.pos))
                }
                if p.bufferedPulse > 0 && p.pulseCooldown == 0 {
                    p.bufferedPulse = 0
                    p.pulseCooldown = ctx.pulseCooldown
                    p.lastPulseTick = tick
                    p.pulses &+= 1
                    pulsers.append(i)
                }
            }

            if p.dashTicks > 0 {
                p.dashTicks -= 1
            } else {
                let desired = stick.limited(.one) * Tuning.playerMaxSpeed
                p.vel = p.vel.lerp(to: desired, t: p.staggerTicks > 0 ? Tuning.staggerAccel : Tuning.playerAccel)
            }
            p.pos += p.vel
            s.players[i] = p
        }

        // 2. Pulses — accumulated, then applied, so resolution is order-independent.
        if !pulsers.isEmpty {
            var shardHits = Array(repeating: PulseHit(), count: s.shards.count)
            var playerPush = Array(repeating: FxVec.zero, count: n)
            var playerStagger = Array(repeating: false, count: n)
            for pi in pulsers {
                let p = s.players[pi]
                for si in s.shards.indices where s.shards[si].active {
                    let sh = s.shards[si]
                    let delta = sh.pos - p.pos
                    let reach = ctx.pulseRadius + Tuning.shardRadius
                    guard FxVec.withinRadius(sh.pos, p.pos, reach) else { continue }
                    let dist = delta.length
                    var dir = dist.raw == 0 ? p.facing : delta.normalized
                    // Aim assist from the stick lets skilled players angle shots.
                    let aim = FxVec(x: Fx(raw: Int64(inputs[pi].moveX) << 16 / 127), y: Fx(raw: Int64(inputs[pi].moveY) << 16 / 127))
                    if aim.lengthSquaredRaw > (Fx.ratio(3, 10).raw * Fx.ratio(3, 10).raw) {
                        let a = aim.normalized
                        if a.dot(dir) > Fx.ratio(-2, 10) { dir = (dir + a).normalized }
                    }
                    let perfect = dist < Tuning.perfectPulseDistance
                    let heatAfter = Int(min(Tuning.maxHeat, sh.heat + (perfect ? 2 : 1)))
                    var speed = Tuning.pulseBaseSpeed + Tuning.pulseHeatSpeed * heatAfter
                    if perfect { speed += Tuning.perfectBonusSpeed }
                    // Deflecting an incoming enemy shard is a parry.
                    if sh.owner >= 0 && Int(sh.owner) != Int(p.team) && sh.heat >= ctx.shatterHeat {
                        s.players[pi].parries &+= 1
                        events.append(GameEvent(tick: tick, kind: .parry, player: pi, team: Int(p.team), at: sh.pos))
                    }
                    shardHits[si].dirSum += dir
                    shardHits[si].speed = Fx.max(shardHits[si].speed, speed)
                    shardHits[si].teams |= (1 << p.team)
                    shardHits[si].perfect = shardHits[si].perfect || perfect
                    shardHits[si].heatGain = max(shardHits[si].heatGain, perfect ? 2 : 1)
                    // Goal credit goes to the closest pulser (geometry, not player index).
                    if shardHits[si].toucher < 0 { shardHits[si].toucher = pi }
                    else {
                        let other = s.players[shardHits[si].toucher]
                        let od = (sh.pos - other.pos).lengthSquaredRaw
                        let md = delta.lengthSquaredRaw
                        if md < od { shardHits[si].toucher = pi }
                    }
                }
                for j in 0..<n where j != pi {
                    let o = s.players[j]
                    guard o.isActive, !o.isDashing else { continue }
                    guard FxVec.withinRadius(o.pos, p.pos, ctx.pulseRadius + Tuning.playerRadius) else { continue }
                    let delta = o.pos - p.pos
                    let dir = delta.lengthSquaredRaw == 0 ? p.facing : delta.normalized
                    if o.team == p.team {
                        playerPush[j] += dir * Tuning.allySlingshot
                    } else if o.shieldTicks == 0 {
                        playerPush[j] += dir * Tuning.enemyKnockback
                        playerStagger[j] = true
                    }
                }
                events.append(GameEvent(tick: tick, kind: .pulse, player: pi, team: Int(p.team), at: p.pos))
            }
            for si in s.shards.indices where shardHits[si].teams != 0 {
                let hit = shardHits[si]
                var sh = s.shards[si]
                if hit.teams == 0b11 {
                    // Clash: opposing pulses on the same tick cancel out.
                    let d = hit.dirSum
                    sh.vel = d.lengthSquaredRaw == 0 ? .zero : d.normalized * Fx(6)
                    sh.owner = -1
                    sh.heat = 0
                    events.append(GameEvent(tick: tick, kind: .clash, at: sh.pos))
                } else {
                    let team = hit.teams == 0b01 ? 0 : 1
                    let dir = hit.dirSum.normalized
                    sh.vel = (dir.lengthSquaredRaw == 0 ? FxVec(team == 0 ? 1 : -1, 0) : dir) * (hit.speed * ctx.shardSpeedScale)
                    sh.heat = min(Tuning.maxHeat, sh.heat + hit.heatGain)
                    sh.owner = Int8(team)
                    if Int(sh.lastToucher) != hit.toucher { sh.prevToucher = sh.lastToucher }
                    sh.lastToucher = Int8(hit.toucher)
                    if hit.perfect {
                        events.append(GameEvent(tick: tick, kind: .perfectPulse, player: hit.toucher, team: team, at: sh.pos))
                    }
                }
                sh.heatTimer = 0
                s.shards[si] = sh
            }
            for j in 0..<n {
                if playerPush[j] != .zero { s.players[j].vel += playerPush[j] }
                if playerStagger[j] { s.players[j].staggerTicks = Tuning.staggerTicks }
            }
        }

        // 3. Player collisions: world, then each other.
        for i in 0..<n where s.players[i].isActive {
            collidePlayerWithWorld(&s.players[i], ctx, tick: tick)
            if !ctx.arena.portals.isEmpty { portalPlayer(&s.players[i], ctx, events: &events, index: i, tick: tick) }
        }
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                separatePlayers(&s, i, j)
            }
        }

        // 4. Shards.
        for si in s.shards.indices where s.shards[si].active {
            simulateShard(&s, si, ctx, &events)
            if s.phase != .playing && s.phase != .goalScored { break }
        }
    }

    static func separatePlayers(_ s: inout GameState, _ i: Int, _ j: Int) {
        let a = s.players[i], b = s.players[j]
        guard a.isActive, b.isActive, !a.isDashing, !b.isDashing else { return }
        let minDist = Tuning.playerRadius * 2
        let delta = b.pos - a.pos
        guard delta.lengthSquaredRaw < minDist.raw * minDist.raw else { return }
        let dist = delta.length
        // Symmetric fallback direction when exactly overlapping.
        let normal = dist.raw == 0 ? FxVec(a.team == 0 ? 1 : -1, 0) : delta.normalized
        let push = (minDist - dist) / 2
        s.players[i].pos -= normal * push
        s.players[j].pos += normal * push
        // Exchange the normal component of velocity (equal masses, soft).
        let relVel = (b.vel - a.vel).dot(normal)
        if relVel < .zero {
            let impulse = normal * (relVel * Fx.ratio(6, 10))
            s.players[i].vel += impulse
            s.players[j].vel -= impulse
        }
    }

    // MARK: - World collision

    /// Pushes a circle out of a segment. Returns the contact normal if colliding.
    @inline(__always)
    static func resolveSegment(_ pos: inout FxVec, radius: Fx, _ seg: WallSegment) -> FxVec? {
        let ab = seg.b - seg.a
        let ap = pos - seg.a
        let abLen2 = ab.lengthSquaredRaw
        var closest = seg.a
        if abLen2 > 0 {
            // t = dot(ap, ab) / |ab|^2 in Q16, computed in raw space to keep precision.
            let dotRaw = ap.x.raw * ab.x.raw + ap.y.raw * ab.y.raw
            var tRaw = (dotRaw / (abLen2 >> 16 == 0 ? 1 : (abLen2 >> 16)))
            if tRaw < 0 { tRaw = 0 }
            if tRaw > Fx.one.raw { tRaw = Fx.one.raw }
            closest = seg.a + ab * Fx(raw: tRaw)
        }
        let d = pos - closest
        let r2 = radius.raw * radius.raw
        let d2 = d.lengthSquaredRaw
        guard d2 < r2 else { return nil }
        let dist = d.length
        let normal: FxVec
        if dist.raw == 0 {
            normal = ab.perp.normalized
        } else {
            normal = d.normalized
        }
        pos += normal * (radius - dist)
        return normal
    }

    static func collidePlayerWithWorld(_ p: inout PlayerState, _ ctx: SimContext, tick: Int32) {
        for seg in ctx.arena.segments where seg.blocksPlayers {
            if let n = resolveSegment(&p.pos, radius: Tuning.playerRadius, seg) {
                let vn = p.vel.dot(n)
                if vn < .zero { p.vel -= n * (vn * Fx.ratio(13, 10)) }
            }
        }
        for pillar in ctx.arena.pillars {
            let c = pillar.position(atTick: tick)
            let minD = pillar.radius + Tuning.playerRadius
            let d = p.pos - c
            if d.lengthSquaredRaw < minD.raw * minD.raw {
                let dist = d.length
                let n = dist.raw == 0 ? FxVec(0, 1) : d.normalized
                p.pos = c + n * minD
                let vn = p.vel.dot(n)
                if vn < .zero { p.vel -= n * vn }
            }
        }
        // Hard clamp as a last line of defence against numerical tunnelling.
        let r = Tuning.playerRadius
        p.pos.x = p.pos.x.clamped(r, ctx.arena.width - r)
        p.pos.y = p.pos.y.clamped(r, ctx.arena.height - r)
    }

    static func portalPlayer(_ p: inout PlayerState, _ ctx: SimContext, events: inout [GameEvent], index: Int, tick: Int32) {
        guard p.portalCooldown == 0 else { return }
        for portal in ctx.arena.portals {
            for (from, to) in [(portal.a, portal.b), (portal.b, portal.a)] {
                if FxVec.withinRadius(p.pos, from, portal.radius - Fx(8)) {
                    let offset = p.pos - from
                    p.pos = to + offset
                    p.portalCooldown = 40
                    events.append(GameEvent(tick: tick, kind: .portal, player: index, team: Int(p.team), at: to))
                    return
                }
            }
        }
    }

    // MARK: - Shard

    static func simulateShard(_ s: inout GameState, _ si: Int, _ ctx: SimContext, _ events: inout [GameEvent]) {
        let tick = s.tick
        var sh = s.shards[si]
        let maxSpeed = (Tuning.shardBaseMaxSpeed + Tuning.shardHeatMaxSpeed * Int(sh.heat)) * ctx.shardSpeedScale
        sh.vel = (sh.vel * Tuning.shardDrag).limited(maxSpeed)
        if sh.portalCooldown > 0 { sh.portalCooldown -= 1 }

        // Heat decays when nobody keeps the rally going.
        sh.heatTimer += 1
        if sh.heatTimer >= Tuning.heatDecayTicks && sh.heat > 0 {
            sh.heat -= 1
            sh.heatTimer = 0
            if sh.heat == 0 { sh.owner = -1 }
        }

        let speed = sh.vel.length
        let substeps = 1 + Int(speed.raw / Fx(14).raw)
        let stepVel = sh.vel / substeps
        var bounced = false

        for _ in 0..<substeps {
            sh.pos += stepVel
            // Walls.
            for seg in ctx.arena.segments where seg.blocksShard {
                if let n = resolveSegment(&sh.pos, radius: Tuning.shardRadius, seg) {
                    let vn = sh.vel.dot(n)
                    if vn < .zero {
                        sh.vel -= n * (vn * (Fx.one + Tuning.shardWallRestitution))
                        bounced = true
                    }
                }
            }
            // Pillars.
            for pillar in ctx.arena.pillars {
                let c = pillar.position(atTick: tick)
                let minD = pillar.radius + Tuning.shardRadius
                let d = sh.pos - c
                if d.lengthSquaredRaw < minD.raw * minD.raw {
                    let dist = d.length
                    let n = dist.raw == 0 ? FxVec(0, 1) : d.normalized
                    sh.pos = c + n * minD
                    let rel = sh.vel - pillar.velocity(atTick: tick)
                    let vn = rel.dot(n)
                    if vn < .zero {
                        sh.vel -= n * (vn * (Fx.one + Tuning.shardWallRestitution))
                        bounced = true
                    }
                }
            }
            // Players.
            for pi in s.players.indices {
                let p = s.players[pi]
                guard p.isActive, !p.isDashing else { continue }
                let minD = Tuning.playerRadius + Tuning.shardRadius
                let d = sh.pos - p.pos
                guard d.lengthSquaredRaw < minD.raw * minD.raw else { continue }
                let dist = d.length
                let n = dist.raw == 0 ? FxVec(p.team == 0 ? 1 : -1, 0) : d.normalized
                sh.pos = p.pos + n * minD
                let hostile = sh.owner >= 0 && UInt8(sh.owner) != p.team
                let fast = sh.vel.length >= Tuning.shatterMinSpeed
                if hostile && sh.heat >= ctx.shatterHeat && fast && p.shieldTicks == 0 {
                    // Shatter!
                    s.players[pi].shatteredTicks = Tuning.shatterRespawnTicks
                    s.players[pi].timesShattered &+= 1
                    s.players[pi].vel = .zero
                    if sh.lastToucher >= 0 { s.players[Int(sh.lastToucher)].shatters &+= 1 }
                    events.append(GameEvent(tick: tick, kind: .shatter, player: pi, team: Int(p.team), at: p.pos))
                    let vn = sh.vel.dot(n)
                    if vn < .zero { sh.vel -= n * (vn * Fx(2)) }
                    sh.vel = sh.vel * Fx.ratio(75, 100)
                    sh.heat = sh.heat > 0 ? sh.heat - 1 : 0
                } else {
                    let rel = sh.vel - p.vel
                    let vn = rel.dot(n)
                    if vn < .zero {
                        sh.vel -= n * (vn * (Fx.one + Tuning.shardBodyRestitution))
                        if hostile && sh.heat > 0 {
                            sh.heat -= 1
                            events.append(GameEvent(tick: tick, kind: .bodyBlock, player: pi, team: Int(p.team), at: sh.pos))
                        }
                    }
                    s.players[pi].vel -= n * Fx.ratio(15, 10)
                }
            }

            // Goal check: fully past the goal line.
            if sh.pos.x < -Tuning.shardRadius || sh.pos.x > ctx.arena.width + Tuning.shardRadius {
                let scoringTeam = sh.pos.x < .zero ? 1 : 0
                scoreGoal(&s, &sh, team: scoringTeam, ctx, &events)
                s.shards[si] = sh
                return
            }
        }

        if bounced && speed > Fx(4) {
            events.append(GameEvent(tick: tick, kind: .wallBounce, team: Int(sh.owner), at: sh.pos))
        }

        // Portals.
        if sh.portalCooldown == 0 {
            outer: for portal in ctx.arena.portals {
                for (from, to) in [(portal.a, portal.b), (portal.b, portal.a)] {
                    if FxVec.withinRadius(sh.pos, from, portal.radius) {
                        sh.pos = to + (sh.pos - from)
                        sh.portalCooldown = 24
                        events.append(GameEvent(tick: tick, kind: .portal, team: Int(sh.owner), at: to))
                        break outer
                    }
                }
            }
        }

        // Keep the shard inside the playable envelope (goal boxes included).
        sh.pos.y = sh.pos.y.clamped(Tuning.shardRadius, ctx.arena.height - Tuning.shardRadius)
        s.shards[si] = sh
    }

    static func scoreGoal(_ s: inout GameState, _ sh: inout ShardState, team: Int, _ ctx: SimContext, _ events: inout [GameEvent]) {
        if team == 0 { s.scores.0 &+= 1 } else { s.scores.1 &+= 1 }
        var scorer = -1
        if sh.lastToucher >= 0 && ctx.team(of: Int(sh.lastToucher)) == team {
            scorer = Int(sh.lastToucher)
            s.players[scorer].goals &+= 1
            if sh.prevToucher >= 0 && Int(sh.prevToucher) != scorer && ctx.team(of: Int(sh.prevToucher)) == team {
                s.players[Int(sh.prevToucher)].assists &+= 1
            }
        }
        s.lastGoalTeam = Int8(team)
        s.lastGoalScorer = Int8(scorer)
        events.append(GameEvent(tick: s.tick, kind: .goal, player: scorer, team: team, at: sh.pos))
        // Every shard leaves play for the celebration.
        sh.active = false
        sh.vel = .zero
        for i in s.shards.indices { s.shards[i].active = false }
        s.phase = .goalScored
        s.phaseTimer = Tuning.goalCelebrationTicks
    }
}
