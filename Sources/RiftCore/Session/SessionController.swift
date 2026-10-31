// RIFT RIVALS — session orchestration: practice, host, client and the
// transitions between them (host migration, demotion of a stale host).

/// Single-device match against bots — same engine, no network.
public final class PracticeSession {
    public let setup: MatchSetup
    public let engine: RollbackEngine
    private var clock = FixedStepClock()
    public private(set) var paused = false

    /// - Parameter autopilotLocal: the local slot is also bot-driven (attract / demo mode).
    public init(settings: MatchSettings, playerName: String, seed: UInt64, now: Double, autopilotLocal: Bool = false) {
        var slots: [RosterSlot] = []
        let size = settings.format.teamSize
        for t in 0..<2 {
            for k in 0..<size {
                if t == 0 && k == 0 {
                    slots.append(RosterSlot(name: NameRules.sanitize(playerName), isBot: autopilotLocal, memberID: 0))
                } else {
                    slots.append(RosterSlot(name: BotNames.name(team: t, index: k), isBot: true, memberID: nil))
                }
            }
        }
        setup = MatchSetup(matchID: 1, seed: seed, settings: settings.sanitized(), slots: slots)
        engine = RollbackEngine(setup: setup)
        engine.localPlayer = 0
        clock.reset(now: now)
    }

    public func setPaused(_ p: Bool, now: Double) {
        paused = p
        clock.reset(now: now)
    }

    public func update(now: Double, input: LocalInputSource?) {
        if paused || engine.state.phase == .matchOver { clock.reset(now: now); return }
        let due = clock.ticksDue(now: now)
        for _ in 0..<due {
            let t = engine.currentTick
            engine.confirm(player: 0, tick: t, input?.sampleInput(forTick: t) ?? .neutral)
            engine.advance()
        }
    }

    public var alpha: Double { clock.alpha }
}

public final class SessionController {
    public enum Mode {
        case idle
        case practice(PracticeSession)
        case host(HostSession)
        case client(ClientSession)
    }

    public private(set) var mode: Mode = .idle
    public let token: UInt64
    public var playerName: String
    public private(set) var transitions: [String] = []

    public init(token: UInt64, playerName: String) {
        self.token = token
        self.playerName = playerName
    }

    public func startPractice(settings: MatchSettings, seed: UInt64, now: Double, demo: Bool = false) {
        end()
        mode = .practice(PracticeSession(settings: settings, playerName: playerName, seed: seed, now: now, autopilotLocal: demo))
    }

    public func host(provider: NetworkProvider, settings: MatchSettings, seed: UInt64, now: Double) throws {
        end()
        mode = .host(try HostSession(provider: provider, hostName: playerName, settings: settings, seed: seed, now: now))
    }

    public func join(provider: NetworkProvider, advert: RoomAdvert, now: Double) throws {
        end()
        mode = .client(try ClientSession(provider: provider, advert: advert, name: playerName, token: token, now: now))
    }

    public func end() {
        switch mode {
        case .host(let h): h.close()
        case .client(let c): c.leave()
        default: break
        }
        mode = .idle
    }

    public func update(now: Double, input: LocalInputSource?) {
        switch mode {
        case .idle: break
        case .practice(let p): p.update(now: now, input: input)
        case .host(let h):
            h.update(now: now, input: input)
            if let target = h.demotionTarget, let s = h.setup {
                // A newer host exists and we have nobody left: rejoin as a client.
                let lobby = h.lobby
                h.close()
                if let c = try? ClientSession(provider: h.provider, rejoining: target, memberID: h.localMemberID,
                                               matchID: s.matchID, name: playerName, token: token, lobby: lobby, now: now) {
                    mode = .client(c)
                    transitions.append("demoted to client (epoch \(target.epoch))")
                }
            }
        case .client(let c):
            c.update(now: now, input: input)
            if let epoch = c.promotionEpoch {
                c.shutdownForPromotion()
                if let h = try? HostSession(promoting: c, newEpoch: epoch, now: now) {
                    mode = .host(h)
                    transitions.append("promoted to host (epoch \(epoch))")
                }
            }
        }
    }

    // MARK: - Unified accessors for UI and tests

    public var engine: RollbackEngine? {
        switch mode {
        case .idle: return nil
        case .practice(let p): return p.engine
        case .host(let h): return h.engine
        case .client(let c): return c.engine
        }
    }

    public var setup: MatchSetup? {
        switch mode {
        case .idle: return nil
        case .practice(let p): return p.setup
        case .host(let h): return h.setup
        case .client(let c): return c.setup
        }
    }

    public var lobby: LobbyState? {
        switch mode {
        case .host(let h): return h.lobby
        case .client(let c): return c.lobby
        default: return nil
        }
    }

    public var diagnostics: NetDiagnostics {
        switch mode {
        case .host(let h): return h.diagnostics
        case .client(let c): return c.diagnostics
        case .practice(let p):
            var d = NetDiagnostics()
            d.isHost = true
            d.hostName = "Local"
            d.tick = p.engine.currentTick
            d.confirmedTick = p.engine.confirmedTick
            d.stepMicros = p.engine.stats.lastStepMicros
            if let v = p.engine.latestVerified { d.lastHashTick = v.tick; d.lastHash = v.hash }
            return d
        case .idle: return NetDiagnostics()
        }
    }

    public var isHost: Bool {
        if case .host = mode { return true }
        if case .practice = mode { return true }
        return false
    }

    public var isNetworked: Bool {
        switch mode { case .host, .client: return true; default: return false }
    }

    public var localMemberID: UInt8? {
        switch mode {
        case .host(let h): return h.localMemberID
        case .client(let c): return c.memberID
        case .practice: return 0
        case .idle: return nil
        }
    }

    public var isPaused: Bool {
        switch mode {
        case .host(let h): return h.paused
        case .client(let c): return c.paused
        case .practice(let p): return p.paused
        case .idle: return false
        }
    }

    public var resumeCountdown: Double? {
        switch mode {
        case .host(let h): return h.resumeCountdown
        case .client(let c): return c.resumeCountdown
        default: return nil
        }
    }

    /// Short human-readable connection state for the HUD.
    public var connectionBanner: String? {
        switch mode {
        case .client(let c):
            switch c.phase {
            case .reconnecting: return "Reconnecting to host…"
            case .migrating: return "Host left — moving the match to a new host…"
            case .closed(let why): return why
            default: return nil
            }
        case .host(let h):
            if h.paused && h.resumeCountdown == nil && h.pausedByMember == h.localMemberID && h.epoch > 1 && h.connectedRemoteCount < h.lobby.members.count - 1 {
                return "You are the new host — waiting for players to reconnect…"
            }
            return nil
        default: return nil
        }
    }
}

extension ClientSession {
    /// Stop using the old host link before this device becomes the host.
    public func shutdownForPromotion() {
        stopTransport()
    }
}
