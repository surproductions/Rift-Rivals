// RIFT RIVALS — deterministic bot / autopilot brain.
//
// Bots run *inside* the simulation, reading only `GameState` and consuming the
// state's RNG, so every device computes the exact same bot inputs without any
// network traffic. The same brain pilots disconnected players (autopilot).

public enum BotBrain {

    struct Profile {
        let thinkInterval: Int16
        let aimJitter: Int          // units of target noise
        let dodgeChance: UInt32     // out of 100
        let pulseEagerness: Fx      // min alignment to pulse toward goal
        let stickScale: Int         // stick magnitude 0…127
    }

    static func profile(_ d: BotDifficulty) -> Profile {
        switch d {
        case .easy: return Profile(thinkInterval: 14, aimJitter: 70, dodgeChance: 12, pulseEagerness: Fx.ratio(5, 10), stickScale: 96)
        case .normal: return Profile(thinkInterval: 7, aimJitter: 35, dodgeChance: 45, pulseEagerness: Fx.ratio(2, 10), stickScale: 118)
        case .hard: return Profile(thinkInterval: 3, aimJitter: 12, dodgeChance: 85, pulseEagerness: Fx.ratio(-1, 10), stickScale: 127)
        }
    }

    public static func decide(_ s: inout GameState, player i: Int, ctx: SimContext, difficulty: BotDifficulty) -> PlayerInput {
        let me = s.players[i]
        guard me.isActive, s.phase == .playing || s.phase == .countdown || s.phase == .goalScored else { return .neutral }
        let prof = profile(difficulty)
        let team = Int(me.team)
        let arena = ctx.arena
        let ownGoal = arena.goalCenter(ofTeam: team)
        let enemyGoal = arena.goalCenter(ofTeam: 1 - team)

        // Nearest active shard.
        var shardIndex = -1
        var best: Int64 = .max
        for (k, sh) in s.shards.enumerated() where sh.active {
            let d = (sh.pos - me.pos).lengthSquaredRaw
            if d < best { best = d; shardIndex = k }
        }
        if shardIndex < 0 || s.phase != .playing {
            return steer(me, toward: me.pos, scale: 0)
        }
        let sh = s.shards[shardIndex]

        // Role: rank teammates by distance to the shard.
        var rank = 0
        for (k, o) in s.players.enumerated() where k != i && Int(o.team) == team && o.isActive {
            let od = (sh.pos - o.pos).lengthSquaredRaw
            if od < best || (od == best && k < i) { rank += 1 }
        }

        var buttons: UInt8 = 0
        let toShard = sh.pos - me.pos
        let distToShard = toShard.length

        // Threat response: a charged enemy shard closing in.
        let hostile = sh.owner >= 0 && Int(sh.owner) != team && sh.heat >= ctx.shatterHeat
        if hostile && distToShard < Fx(260) {
            let closing = -(toShard.normalized.dot(sh.vel))
            if closing > Fx(6) {
                let ticksToImpact = closing.raw == 0 ? 99 : Int((distToShard / closing).intValue)
                if ticksToImpact < 14 {
                    let roll = s.rng.next(below: 100)
                    if roll < prof.dodgeChance {
                        if distToShard < ctx.pulseRadius && me.pulseCooldown == 0 {
                            buttons |= PlayerInput.pulse
                        } else if me.dashCooldown == 0 && !ctx.setup.settings.modifiers.contains(.noDash) {
                            buttons |= PlayerInput.dash
                            let side = sh.vel.normalized.perp
                            var input = steer(me, toward: me.pos + side * Fx(100), scale: 127)
                            input.buttons = buttons
                            return input
                        }
                    }
                }
            }
        }

        // Re-plan at the profile's reaction rate.
        var bot = s.players[i]
        if bot.botThinkTimer <= 0 {
            bot.botThinkTimer = prof.thinkInterval
            let jx = s.rng.range(-prof.aimJitter, prof.aimJitter)
            let jy = s.rng.range(-prof.aimJitter, prof.aimJitter)
            let jitter = FxVec(jx, jy)
            let shotDir = (enemyGoal - sh.pos).normalized
            switch rank {
            case 0:
                // Striker: get behind the shard relative to the enemy goal.
                let lead = sh.pos + sh.vel * Fx(6)
                bot.botTarget = lead - shotDir * (Tuning.playerRadius + Tuning.shardRadius + Fx(24)) + jitter
            case 1 where ctx.teamSize >= 3:
                // Support: lurk ahead of the shard, offset toward the open lane.
                let mid = (sh.pos + enemyGoal) / 2
                let lane = Fx(sh.pos.y < arena.height / 2 ? 170 : -170)
                bot.botTarget = FxVec(x: mid.x, y: arena.height / 2 + lane) + jitter
            default:
                // Defender: hold between the shard and our goal.
                let guardDir = (sh.pos - ownGoal).normalized
                let depth = Fx(rank >= 2 ? 150 : 230)
                bot.botTarget = ownGoal + guardDir * depth + jitter
            }
            bot.botWantsPulse = false
        } else {
            bot.botThinkTimer -= 1
        }

        // Pulse when the shard is in reach and the hit points the right way.
        if distToShard < ctx.pulseRadius + Tuning.shardRadius - Fx(6) && me.pulseCooldown == 0 {
            let shotDir = (enemyGoal - sh.pos).normalized
            let hitDir = toShard.normalized
            let towardOwnGoal = (ownGoal - sh.pos).normalized
            if hitDir.dot(shotDir) > prof.pulseEagerness || hitDir.dot(towardOwnGoal) < Fx.ratio(-5, 10) {
                buttons |= PlayerInput.pulse
            }
        }
        s.players[i] = bot

        var input = steer(me, toward: bot.botTarget, scale: prof.stickScale)
        // Aim the pulse at the enemy goal using the stick.
        if buttons & PlayerInput.pulse != 0 {
            let aim = (enemyGoal - sh.pos).normalized
            input.moveX = Int8(clamping: Int((aim.x * prof.stickScale).intValue))
            input.moveY = Int8(clamping: Int((aim.y * prof.stickScale).intValue))
        }
        // Release buttons on alternate ticks so edge-triggered actions re-arm.
        if me.prevButtons & buttons != 0 { buttons = 0 }
        input.buttons = buttons
        return input
    }

    static func steer(_ me: PlayerState, toward target: FxVec, scale: Int) -> PlayerInput {
        let d = target - me.pos
        let dist = d.length
        if dist < Fx(6) || scale == 0 { return .neutral }
        let dir = d.normalized
        // Ease off when close to avoid oscillation.
        let mag = dist < Fx(60) ? max(30, scale * dist.intValue / 60) : scale
        return PlayerInput(moveX: Int8(clamping: (dir.x * mag).intValue),
                           moveY: Int8(clamping: (dir.y * mag).intValue),
                           buttons: 0)
    }
}
