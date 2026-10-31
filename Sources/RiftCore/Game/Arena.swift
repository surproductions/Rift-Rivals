// RIFT RIVALS — arena geometry. All arenas are mirror-symmetric across the
// centre line (x = width/2) so neither team has a positional advantage.

public enum ArenaID: UInt8, CaseIterable, Codable, Sendable {
    case foundry = 0, twinRifts = 1, pillarDrift = 2, narrows = 3

    public var displayName: String {
        switch self {
        case .foundry: return "The Foundry"
        case .twinRifts: return "Twin Rifts"
        case .pillarDrift: return "Pillar Drift"
        case .narrows: return "The Narrows"
        }
    }

    public var blurb: String {
        switch self {
        case .foundry: return "Open floor. Pure skill, nowhere to hide."
        case .twinRifts: return "Two linked rifts fold the arena in half."
        case .pillarDrift: return "Drifting pylons reshape every lane."
        case .narrows: return "Crushing wedges choke the midfield."
        }
    }
}

public struct WallSegment: Sendable {
    public var a: FxVec
    public var b: FxVec
    public var blocksPlayers: Bool
    public var blocksShard: Bool
}

public struct Pillar: Sendable {
    public var base: FxVec
    /// Peak displacement for moving pillars (zero for static ones).
    public var travel: FxVec
    /// Full oscillation period in ticks (0 = static).
    public var period: Int32
    public var radius: Fx

    /// Position is a pure function of the tick — no state to roll back.
    public func position(atTick tick: Int32) -> FxVec {
        if period == 0 { return base }
        let t = Int64(((tick % period) + period) % period)
        let half = Int64(period / 2)
        // Triangle wave in [-1, 1] as fixed point.
        let phase = t < half ? t : (Int64(period) - t)
        let unit = Fx(raw: (phase << 17) / Int64(period)) - Fx.half // 0..1 -> -0.5..0.5
        return base + travel * (unit * 2)
    }

    /// Velocity estimate (per tick) for bounce responses.
    public func velocity(atTick tick: Int32) -> FxVec {
        position(atTick: tick + 1) - position(atTick: tick)
    }
}

public struct PortalPair: Sendable {
    public var a: FxVec
    public var b: FxVec
    public var radius: Fx
}

public struct Arena: Sendable {
    public let id: ArenaID
    public let width: Fx
    public let height: Fx
    public let goalHalfWidth: Fx
    public let goalDepth: Fx
    public let segments: [WallSegment]
    public let pillars: [Pillar]
    public let portals: [PortalPair]

    public var center: FxVec { FxVec(x: width / 2, y: height / 2) }
    /// Centre of the goal defended by `team`.
    public func goalCenter(ofTeam team: Int) -> FxVec {
        FxVec(x: team == 0 ? .zero : width, y: height / 2)
    }

    public static let standardWidth = 1600
    public static let standardHeight = 900

    public static func make(_ id: ArenaID) -> Arena {
        let w = standardWidth, h = standardHeight
        let gh = 130            // goal half-width
        let gd = 70             // goal depth
        let c = 110             // corner chamfer
        let my = h / 2
        var segs: [WallSegment] = []
        func wall(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int, players: Bool = true, shard: Bool = true) {
            segs.append(WallSegment(a: FxVec(ax, ay), b: FxVec(bx, by), blocksPlayers: players, blocksShard: shard))
        }
        // Outer boundary.
        wall(c, 0, w - c, 0)
        wall(w - c, 0, w, c)
        wall(w, c, w, my - gh)
        wall(w, my - gh, w, my + gh, players: true, shard: false) // goal mouth: players only
        wall(w, my + gh, w, h - c)
        wall(w, h - c, w - c, h)
        wall(w - c, h, c, h)
        wall(c, h, 0, h - c)
        wall(0, h - c, 0, my + gh)
        wall(0, my + gh, 0, my - gh, players: true, shard: false)
        wall(0, my - gh, 0, c)
        wall(0, c, c, 0)
        // Goal boxes.
        wall(w, my - gh, w + gd, my - gh)
        wall(w + gd, my - gh, w + gd, my + gh)
        wall(w + gd, my + gh, w, my + gh)
        wall(0, my - gh, -gd, my - gh)
        wall(-gd, my - gh, -gd, my + gh)
        wall(-gd, my + gh, 0, my + gh)

        var pillars: [Pillar] = []
        var portals: [PortalPair] = []
        switch id {
        case .foundry:
            break
        case .twinRifts:
            portals.append(PortalPair(a: FxVec(430, 175), b: FxVec(w - 430, 175), radius: Fx(40)))
            portals.append(PortalPair(a: FxVec(430, h - 175), b: FxVec(w - 430, h - 175), radius: Fx(40)))
        case .pillarDrift:
            pillars.append(Pillar(base: FxVec(w / 2, 225), travel: .zero, period: 0, radius: Fx(46)))
            pillars.append(Pillar(base: FxVec(w / 2, h - 225), travel: .zero, period: 0, radius: Fx(46)))
            pillars.append(Pillar(base: FxVec(470, my), travel: FxVec(0, 230), period: 420, radius: Fx(40)))
            pillars.append(Pillar(base: FxVec(w - 470, my), travel: FxVec(0, 230), period: 420, radius: Fx(40)))
        case .narrows:
            let half = w / 2
            wall(half - 170, h, half, h - 190)
            wall(half, h - 190, half + 170, h)
            wall(half - 170, 0, half, 190)
            wall(half, 190, half + 170, 0)
        }
        return Arena(id: id, width: Fx(w), height: Fx(h), goalHalfWidth: Fx(gh), goalDepth: Fx(gd),
                     segments: segs, pillars: pillars, portals: portals)
    }

    /// Mirror-symmetric spawn points. Team 1 mirrors team 0 across the centre line.
    public func spawnPoint(team: Int, indexInTeam: Int, teamSize: Int) -> FxVec {
        let layouts: [[(Int, Int)]] = [
            [(360, 450)],
            [(360, 300), (360, 600)],
            [(300, 450), (450, 240), (450, 660)],
            [(270, 330), (270, 570), (500, 190), (500, 710)],
        ]
        let layout = layouts[max(0, min(3, teamSize - 1))]
        let p = layout[indexInTeam % layout.count]
        let x = team == 0 ? p.0 : Arena.standardWidth - p.0
        return FxVec(x, p.1)
    }

    public func kickoffPoints(shardCount: Int) -> [FxVec] {
        let cx = Arena.standardWidth / 2
        if shardCount == 1 { return [FxVec(cx, 450)] }
        return [FxVec(cx, 300), FxVec(cx, 600)]
    }

    public static let all: [ArenaID: Arena] = {
        var d: [ArenaID: Arena] = [:]
        for id in ArenaID.allCases { d[id] = make(id) }
        return d
    }()
}
