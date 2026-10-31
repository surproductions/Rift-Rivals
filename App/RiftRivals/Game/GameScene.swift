import SpriteKit
import UIKit

/// Renders the deterministic simulation. Rendering never feeds back into the
/// simulation: positions are smoothed/extrapolated purely for display, so a
/// 120 Hz display and a 60 Hz display see the same match.
final class GameScene: SKScene {
    weak var model: AppModel?

    private let world = SKNode()
    private let cam = SKCameraNode()
    private let fxLayer = SKNode()
    private var arenaBuilt: ArenaID?
    private var setupID: UInt32 = 0
    private var playerNodes: [PlayerSprite] = []
    private var shardNodes: [ShardSprite] = []
    private var pillarNodes: [SKShapeNode] = []
    private var portalNodes: [SKNode] = []
    private var lastTick: Int32 = -1
    private var lastTickTime: TimeInterval = 0
    private var lastFrame: TimeInterval = 0
    private var seen = Set<EventKey>()
    private var eventBuffer: [GameEvent] = []
    private var shake: CGFloat = 0
    private var flash = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 10))

    struct EventKey: Hashable { let tick: Int32; let kind: UInt8; let player: Int8; let team: Int8 }

    static let glowTexture: SKTexture = {
        let size = CGSize(width: 128, height: 128)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 64, y: 64), startRadius: 0,
                                             endCenter: CGPoint(x: 64, y: 64), endRadius: 64, options: [])
        }
        return SKTexture(image: img)
    }()

    static let sparkTexture: SKTexture = {
        let size = CGSize(width: 16, height: 16)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 4, y: 4, width: 8, height: 8))
        }
        return SKTexture(image: img)
    }()

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = UIColor(hex: 0x070A14)
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        addChild(world)
        addChild(cam)
        camera = cam
        world.addChild(fxLayer)
        fxLayer.zPosition = 50
        flash.alpha = 0
        flash.zPosition = 500
        flash.blendMode = .add
        cam.addChild(flash)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        fitCamera()
    }

    private func fitCamera() {
        guard size.width > 0, size.height > 0 else { return }
        let worldW = CGFloat(Arena.standardWidth) + 200
        let worldH = CGFloat(Arena.standardHeight) + 70
        let s = max(worldW / size.width, worldH / size.height)
        cam.setScale(s)
        cam.position = CGPoint(x: CGFloat(Arena.standardWidth) / 2, y: CGFloat(Arena.standardHeight) / 2 - 10)
        flash.size = CGSize(width: size.width * 1.2, height: size.height * 1.2)
    }

    // MARK: - Build

    private func build(_ setup: MatchSetup, local: Int?) {
        world.removeAllChildren()
        world.addChild(fxLayer)
        playerNodes.removeAll()
        shardNodes.removeAll()
        pillarNodes.removeAll()
        portalNodes.removeAll()
        seen.removeAll()
        let arena = Arena.make(setup.settings.arena)
        arenaBuilt = arena.id
        setupID = setup.matchID
        buildArena(arena)
        for (i, slot) in setup.slots.enumerated() {
            let team = setup.team(of: i)
            let p = PlayerSprite(team: team, number: i % setup.teamSize + 1, name: slot.name, isLocal: i == local, isBot: slot.isBot)
            p.zPosition = 20
            world.addChild(p)
            playerNodes.append(p)
        }
        let shardCount = setup.settings.modifiers.contains(.twinShards) ? 2 : 1
        for _ in 0..<shardCount {
            let s = ShardSprite(trailTarget: world)
            s.zPosition = 30
            world.addChild(s)
            shardNodes.append(s)
        }
        fitCamera()
    }

    private func buildArena(_ arena: Arena) {
        let W = CGFloat(Arena.standardWidth), H = CGFloat(Arena.standardHeight)
        let c: CGFloat = 110
        let floor = CGMutablePath()
        floor.addLines(between: [CGPoint(x: c, y: 0), CGPoint(x: W - c, y: 0), CGPoint(x: W, y: c), CGPoint(x: W, y: H - c),
                                 CGPoint(x: W - c, y: H), CGPoint(x: c, y: H), CGPoint(x: 0, y: H - c), CGPoint(x: 0, y: c)])
        floor.closeSubpath()
        let floorNode = SKShapeNode(path: floor)
        floorNode.fillColor = UIColor(hex: 0x0E1426)
        floorNode.strokeColor = .clear
        floorNode.zPosition = 0
        world.addChild(floorNode)

        // Team halves tint.
        for t in 0..<2 {
            let half = SKShapeNode(rect: CGRect(x: t == 0 ? 0 : W / 2, y: 0, width: W / 2, height: H))
            half.fillColor = Palette.teamUIColor(t).withAlphaComponent(0.035)
            half.strokeColor = .clear
            half.zPosition = 1
            world.addChild(half)
        }
        // Floor grid.
        let grid = CGMutablePath()
        var x: CGFloat = 100
        while x < W { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: H)); x += 100 }
        var y: CGFloat = 100
        while y < H { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: W, y: y)); y += 100 }
        let gridNode = SKShapeNode(path: grid)
        gridNode.strokeColor = UIColor(hex: 0x2A3762, alpha: 0.35)
        gridNode.lineWidth = 1
        gridNode.zPosition = 2
        world.addChild(gridNode)

        // Centre line and circle.
        let centre = CGMutablePath()
        centre.move(to: CGPoint(x: W / 2, y: 0)); centre.addLine(to: CGPoint(x: W / 2, y: H))
        centre.addEllipse(in: CGRect(x: W / 2 - 110, y: H / 2 - 110, width: 220, height: 220))
        let centreNode = SKShapeNode(path: centre.copy(dashingWithPhase: 0, lengths: [18, 12]))
        centreNode.strokeColor = UIColor(hex: 0xD9D2FF, alpha: 0.28)
        centreNode.lineWidth = 3
        centreNode.zPosition = 3
        world.addChild(centreNode)

        // Goals: left goal is defended by Ember (team 0), right by Tide (team 1).
        for t in 0..<2 {
            let gx: CGFloat = t == 0 ? -70 : W
            let rect = CGRect(x: gx, y: H / 2 - 130, width: 70, height: 260)
            let goal = SKShapeNode(rect: rect)
            goal.fillColor = Palette.teamUIColor(t).withAlphaComponent(0.22)
            goal.strokeColor = .clear
            goal.zPosition = 1
            world.addChild(goal)
            let mouth = SKShapeNode(rect: CGRect(x: (t == 0 ? 0 : W) - 3, y: H / 2 - 130, width: 6, height: 260))
            mouth.fillColor = Palette.teamUIColor(t)
            mouth.strokeColor = .clear
            mouth.zPosition = 5
            mouth.run(.repeatForever(.sequence([.fadeAlpha(to: 0.45, duration: 0.9), .fadeAlpha(to: 1, duration: 0.9)])))
            world.addChild(mouth)
            let glow = SKSpriteNode(texture: GameScene.glowTexture, color: Palette.teamUIColor(t), size: CGSize(width: 260, height: 420))
            glow.colorBlendFactor = 1
            glow.blendMode = .add
            glow.alpha = 0.35
            glow.position = CGPoint(x: t == 0 ? 0 : W, y: H / 2)
            glow.zPosition = 4
            world.addChild(glow)
        }

        // Walls (players + shard) as bright edges.
        let walls = CGMutablePath()
        for seg in arena.segments where seg.blocksShard {
            walls.move(to: cg(seg.a)); walls.addLine(to: cg(seg.b))
        }
        let wallGlow = SKShapeNode(path: walls)
        wallGlow.strokeColor = UIColor(hex: 0xD9D2FF, alpha: 0.18)
        wallGlow.lineWidth = 14
        wallGlow.lineCap = .round
        wallGlow.zPosition = 6
        world.addChild(wallGlow)
        let wallLine = SKShapeNode(path: walls)
        wallLine.strokeColor = UIColor(hex: 0xD9D2FF, alpha: 0.95)
        wallLine.lineWidth = 3
        wallLine.lineCap = .round
        wallLine.zPosition = 7
        world.addChild(wallLine)

        // Narrows wedges are solid.
        if arena.id == .narrows {
            for top in [true, false] {
                let p = CGMutablePath()
                let yb: CGFloat = top ? H : 0, yt: CGFloat = top ? H - 190 : 190
                p.addLines(between: [CGPoint(x: W / 2 - 170, y: yb), CGPoint(x: W / 2, y: yt), CGPoint(x: W / 2 + 170, y: yb)])
                p.closeSubpath()
                let n = SKShapeNode(path: p)
                n.fillColor = UIColor(hex: 0x1C2747)
                n.strokeColor = .clear
                n.zPosition = 5
                world.addChild(n)
            }
        }

        for pillar in arena.pillars {
            let n = SKShapeNode(circleOfRadius: CGFloat(pillar.radius.double))
            n.fillColor = UIColor(hex: 0x1C2747)
            n.strokeColor = UIColor(hex: 0xD9D2FF, alpha: 0.9)
            n.lineWidth = 3
            n.glowWidth = 0
            n.zPosition = 8
            n.position = cg(pillar.base)
            let core = SKShapeNode(circleOfRadius: CGFloat(pillar.radius.double) * 0.45)
            core.fillColor = UIColor(hex: 0xD9D2FF, alpha: 0.25)
            core.strokeColor = .clear
            n.addChild(core)
            world.addChild(n)
            pillarNodes.append(n)
        }

        for pair in arena.portals {
            for end in [pair.a, pair.b] {
                let node = SKNode()
                node.position = cg(end)
                node.zPosition = 9
                let r = CGFloat(pair.radius.double)
                let ring = SKShapeNode(path: CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
                    .copy(dashingWithPhase: 0, lengths: [10, 7]))
                ring.strokeColor = UIColor(hex: 0xD9D2FF)
                ring.lineWidth = 4
                ring.run(.repeatForever(.rotate(byAngle: .pi * 2, duration: 4)))
                let swirl = SKSpriteNode(texture: GameScene.glowTexture, color: UIColor(hex: 0x9B8CFF), size: CGSize(width: r * 3, height: r * 3))
                swirl.colorBlendFactor = 1
                swirl.blendMode = .add
                swirl.alpha = 0.55
                node.addChild(swirl)
                node.addChild(ring)
                world.addChild(node)
                portalNodes.append(node)
            }
            let link = CGMutablePath()
            link.move(to: cg(pair.a)); link.addLine(to: cg(pair.b))
            let l = SKShapeNode(path: link.copy(dashingWithPhase: 0, lengths: [4, 14]))
            l.strokeColor = UIColor(hex: 0x9B8CFF, alpha: 0.25)
            l.lineWidth = 2
            l.zPosition = 2
            world.addChild(l)
        }
    }

    @inline(__always) func cg(_ v: FxVec) -> CGPoint { CGPoint(x: v.x.double, y: v.y.double) }

    // MARK: - Frame

    override func update(_ currentTime: TimeInterval) {
        model?.sceneFrame(now: CACurrentMediaTime())
        guard let model = model, let engine = model.controller.engine, let setup = model.controller.setup else { return }
        if arenaBuilt != setup.settings.arena || setupID != setup.matchID || playerNodes.count != setup.playerCount {
            build(setup, local: engine.localPlayer)
        }
        let dt = lastFrame == 0 ? 1.0 / 60 : min(0.1, currentTime - lastFrame)
        lastFrame = currentTime
        let state = engine.state
        if state.tick != lastTick {
            lastTick = state.tick
            lastTickTime = currentTime
        }
        let frac = CGFloat(min(1, (currentTime - lastTickTime) * 60))
        let follow = CGFloat(1 - exp(-dt * 38))
        let playing = state.phase == .playing || state.phase == .goalScored

        for (i, p) in state.players.enumerated() where i < playerNodes.count {
            let node = playerNodes[i]
            var target = cg(p.pos)
            if playing { target.x += CGFloat(p.vel.x.double) * frac; target.y += CGFloat(p.vel.y.double) * frac }
            node.apply(state: p, target: target, follow: follow, tick: state.tick, pulseRadius: CGFloat(engine.ctx.pulseRadius.double),
                       connected: model.isSlotConnected(i))
        }
        for (i, s) in state.shards.enumerated() where i < shardNodes.count {
            var target = cg(s.pos)
            if playing && s.active { target.x += CGFloat(s.vel.x.double) * frac; target.y += CGFloat(s.vel.y.double) * frac }
            shardNodes[i].apply(state: s, target: target, follow: follow)
        }
        let arena = engine.ctx.arena
        for (k, n) in pillarNodes.enumerated() where k < arena.pillars.count {
            n.position = cg(arena.pillars[k].position(atTick: state.tick))
        }

        // Presentation events (de-duplicated across rollbacks).
        eventBuffer.removeAll(keepingCapacity: true)
        engine.drainEvents(into: &eventBuffer)
        for e in eventBuffer {
            let key = EventKey(tick: e.tick, kind: e.kind.rawValue, player: e.player, team: e.team)
            if seen.contains(key) { continue }
            seen.insert(key)
            if e.tick < state.tick - 20 { continue } // too old to be worth showing
            present(e, pulseRadius: CGFloat(engine.ctx.pulseRadius.double))
        }
        if seen.count > 600 { seen = seen.filter { $0.tick > state.tick - 240 } }

        // Screen shake + flash decay.
        if shake > 0.1 && Preferences.shared.screenShake && !Preferences.shared.reduceMotion {
            cam.position = CGPoint(x: CGFloat(Arena.standardWidth) / 2 + CGFloat.random(in: -shake...shake),
                                   y: CGFloat(Arena.standardHeight) / 2 - 10 + CGFloat.random(in: -shake...shake))
            shake *= CGFloat(exp(-dt * 9))
        } else {
            shake = 0
            cam.position = CGPoint(x: CGFloat(Arena.standardWidth) / 2, y: CGFloat(Arena.standardHeight) / 2 - 10)
        }
    }

    private func present(_ e: GameEvent, pulseRadius: CGFloat) {
        let pos = CGPoint(x: CGFloat(e.x), y: CGFloat(e.y))
        let color = Palette.teamUIColor(Int(e.team))
        let isLocal = Int(e.player) == model?.controller.engine?.localPlayer
        switch e.kind {
        case .pulse:
            ring(at: pos, radius: pulseRadius, color: color, duration: 0.28, width: 5)
            SoundEngine.shared.play(.pulse, volume: isLocal ? 0.9 : 0.55)
            if isLocal { SoundEngine.shared.haptic(0) }
        case .perfectPulse:
            ring(at: pos, radius: 70, color: .white, duration: 0.35, width: 8)
            burst(at: pos, color: color, count: 26, speed: 380)
            SoundEngine.shared.play(.perfect)
            shake = max(shake, 6)
            model?.flashBanner("PERFECT", color: color, small: true)
        case .parry:
            burst(at: pos, color: .white, count: 18, speed: 300)
            SoundEngine.shared.play(.parry)
            if isLocal { SoundEngine.shared.haptic(1) }
        case .clash:
            ring(at: pos, radius: 90, color: UIColor(hex: 0xD9D2FF), duration: 0.4, width: 6)
            burst(at: pos, color: UIColor(hex: 0xD9D2FF), count: 30, speed: 420)
            SoundEngine.shared.play(.clash)
            shake = max(shake, 8)
            model?.flashBanner("CLASH!", color: .white, small: true)
        case .dash:
            if Int(e.player) < playerNodes.count { playerNodes[Int(e.player)].dashBurst() }
            SoundEngine.shared.play(.dash, volume: isLocal ? 0.8 : 0.4)
        case .shatter:
            burst(at: pos, color: color, count: 46, speed: 520, shards: true)
            ring(at: pos, radius: 120, color: color, duration: 0.5, width: 4)
            SoundEngine.shared.play(.shatter)
            shake = max(shake, 14)
            if isLocal { SoundEngine.shared.haptic(1) }
            if Int(e.player) < playerNodes.count { model?.flashBanner("\(playerNodes[Int(e.player)].displayName) SHATTERED", color: color, small: true) }
        case .respawn:
            ring(at: pos, radius: 60, color: color, duration: 0.5, width: 3)
            SoundEngine.shared.play(.respawn, volume: 0.5)
        case .wallBounce:
            SoundEngine.shared.play(.bounce, volume: 0.35)
        case .portal:
            ring(at: pos, radius: 50, color: UIColor(hex: 0x9B8CFF), duration: 0.35, width: 5)
            SoundEngine.shared.play(.portal, volume: 0.5)
        case .goal:
            burst(at: pos, color: color, count: 90, speed: 700)
            ring(at: pos, radius: 300, color: color, duration: 0.7, width: 10)
            SoundEngine.shared.play(.goal)
            SoundEngine.shared.haptic(2)
            shake = max(shake, 22)
            flashScreen(color)
            let scorer = Int(e.player) >= 0 && Int(e.player) < playerNodes.count ? playerNodes[Int(e.player)].displayName : "OWN GOAL"
            model?.flashBanner("GOAL — \(TeamInfo.names[max(0, Int(e.team))])", color: color, subtitle: scorer)
        case .countdownTick:
            SoundEngine.shared.play(.countdown)
            model?.flashBanner("\(e.player)", color: .white, big: true)
        case .roundStart:
            SoundEngine.shared.play(.go)
            model?.flashBanner("GO!", color: UIColor(hex: 0xD9D2FF), big: true)
        case .overtime:
            SoundEngine.shared.play(.roundOver, volume: 0.6)
            model?.flashBanner("GOLDEN GOAL", color: UIColor(hex: 0xFFD166), subtitle: "Next goal wins the round")
        case .roundOver:
            SoundEngine.shared.play(.roundOver)
            model?.flashBanner("ROUND TO \(TeamInfo.names[max(0, Int(e.team))])", color: color)
        case .matchOver:
            SoundEngine.shared.play(.goal, volume: 0.8)
            SoundEngine.shared.haptic(2)
        case .bodyBlock:
            SoundEngine.shared.play(.bounce, volume: 0.6, pitch: 0.7)
        }
    }

    private func ring(at p: CGPoint, radius: CGFloat, color: UIColor, duration: TimeInterval, width: CGFloat) {
        let n = SKShapeNode(circleOfRadius: radius)
        n.position = p
        n.strokeColor = color
        n.lineWidth = width
        n.fillColor = color.withAlphaComponent(0.08)
        n.setScale(0.25)
        n.blendMode = .add
        fxLayer.addChild(n)
        n.run(.sequence([.group([.scale(to: 1, duration: duration), .fadeOut(withDuration: duration)]), .removeFromParent()]))
    }

    private func burst(at p: CGPoint, color: UIColor, count: Int, speed: CGFloat, shards: Bool = false) {
        let em = SKEmitterNode()
        em.particleTexture = GameScene.sparkTexture
        em.particleBirthRate = CGFloat(count) * 40
        em.numParticlesToEmit = Preferences.shared.reduceMotion ? count / 3 : count
        em.particleLifetime = 0.55
        em.particleLifetimeRange = 0.3
        em.emissionAngleRange = .pi * 2
        em.particleSpeed = speed
        em.particleSpeedRange = speed * 0.6
        em.particleAlpha = 1
        em.particleAlphaSpeed = -1.8
        em.particleScale = shards ? 1.4 : 0.9
        em.particleScaleRange = 0.6
        em.particleScaleSpeed = -1.2
        em.particleColor = color
        em.particleColorBlendFactor = 1
        em.particleBlendMode = .add
        em.particleRotationRange = .pi * 2
        em.xAcceleration = 0
        em.yAcceleration = 0
        em.position = p
        fxLayer.addChild(em)
        em.run(.sequence([.wait(forDuration: 1.2), .removeFromParent()]))
    }

    private func flashScreen(_ color: UIColor) {
        guard !Preferences.shared.reduceMotion else { return }
        flash.color = color
        flash.alpha = 0.28
        flash.run(.fadeOut(withDuration: 0.45))
    }
}

/// A Riftrunner on screen.
final class PlayerSprite: SKNode {
    let team: Int
    let displayName: String
    private let body = SKShapeNode(circleOfRadius: 28)
    private let core = SKShapeNode(circleOfRadius: 13)
    private let facingNode = SKShapeNode()
    private let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let nameLabel = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    private let localRing = SKShapeNode(circleOfRadius: 40)
    private let shield = SKShapeNode(circleOfRadius: 38)
    private let cooldownArc = SKShapeNode()
    private let glow = SKSpriteNode(texture: GameScene.glowTexture)
    private let statusLabel = SKLabelNode(fontNamed: "AvenirNext-Bold")
    private var displayPos: CGPoint?
    private let isLocal: Bool
    private let isBot: Bool
    private var lastCooldownFrac: CGFloat = -1

    init(team: Int, number: Int, name: String, isLocal: Bool, isBot: Bool) {
        self.team = team
        self.displayName = name.replacingOccurrences(of: " [BOT]", with: "").uppercased()
        self.isLocal = isLocal
        self.isBot = isBot
        super.init()
        let color = Palette.teamUIColor(team)
        glow.color = color
        glow.colorBlendFactor = 1
        glow.blendMode = .add
        glow.alpha = isLocal ? 0.55 : 0.35
        glow.size = CGSize(width: 150, height: 150)
        addChild(glow)

        body.fillColor = color
        body.strokeColor = UIColor.white.withAlphaComponent(0.85)
        body.lineWidth = 3
        addChild(body)
        core.fillColor = UIColor(hex: 0x070A14, alpha: 0.55)
        core.strokeColor = .clear
        addChild(core)

        // Team shape marker on the facing notch: triangle (Ember) / diamond (Tide).
        let notch = CGMutablePath()
        if team == 0 {
            notch.move(to: CGPoint(x: 46, y: 0)); notch.addLine(to: CGPoint(x: 34, y: 9)); notch.addLine(to: CGPoint(x: 34, y: -9))
        } else {
            notch.move(to: CGPoint(x: 47, y: 0)); notch.addLine(to: CGPoint(x: 39, y: 8)); notch.addLine(to: CGPoint(x: 31, y: 0)); notch.addLine(to: CGPoint(x: 39, y: -8))
        }
        notch.closeSubpath()
        facingNode.path = notch
        facingNode.fillColor = .white
        facingNode.strokeColor = .clear
        addChild(facingNode)

        label.text = "\(number)"
        label.fontSize = 22
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        addChild(label)

        nameLabel.text = isLocal ? "YOU" : displayName
        nameLabel.fontSize = isLocal ? 22 : 18
        nameLabel.fontColor = isLocal ? .white : color.withAlphaComponent(0.95)
        nameLabel.position = CGPoint(x: 0, y: 46)
        nameLabel.verticalAlignmentMode = .bottom
        addChild(nameLabel)

        statusLabel.fontSize = 14
        statusLabel.fontColor = UIColor(hex: 0xFFD166)
        statusLabel.position = CGPoint(x: 0, y: -62)
        statusLabel.text = isBot ? "BOT" : ""
        statusLabel.alpha = 0.8
        addChild(statusLabel)

        if isLocal {
            localRing.path = CGPath(ellipseIn: CGRect(x: -42, y: -42, width: 84, height: 84), transform: nil).copy(dashingWithPhase: 0, lengths: [9, 6])
            localRing.strokeColor = .white
            localRing.lineWidth = 2.5
            localRing.run(.repeatForever(.rotate(byAngle: .pi * 2, duration: 6)))
            addChild(localRing)
        }
        shield.strokeColor = UIColor(hex: 0xD9D2FF)
        shield.fillColor = UIColor(hex: 0xD9D2FF, alpha: 0.12)
        shield.lineWidth = 2
        shield.isHidden = true
        addChild(shield)
        cooldownArc.strokeColor = color.withAlphaComponent(0.9)
        cooldownArc.lineWidth = 4
        cooldownArc.lineCap = .round
        addChild(cooldownArc)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(state p: PlayerState, target: CGPoint, follow: CGFloat, tick: Int32, pulseRadius: CGFloat, connected: Bool) {
        if p.shatteredTicks > 0 {
            isHidden = true
            displayPos = nil
            return
        }
        isHidden = false
        if let d = displayPos, hypot(d.x - target.x, d.y - target.y) < 70 {
            displayPos = CGPoint(x: d.x + (target.x - d.x) * follow, y: d.y + (target.y - d.y) * follow)
        } else {
            displayPos = target   // teleports / big corrections snap
        }
        position = displayPos!
        let angle = atan2(CGFloat(p.facing.y.double), CGFloat(p.facing.x.double))
        facingNode.zRotation = angle
        body.setScale(p.isDashing ? 1.12 : (p.staggerTicks > 0 ? 0.92 : 1))
        body.alpha = p.isDashing ? 0.55 : 1
        shield.isHidden = p.shieldTicks == 0
        glow.alpha = p.isDashing ? 0.8 : (isLocal ? 0.55 : 0.35)

        // Pulse cooldown arc (only redrawn when it changes).
        let frac = CGFloat(p.pulseCooldown) / 32
        if abs(frac - lastCooldownFrac) > 0.02 {
            lastCooldownFrac = frac
            if p.pulseCooldown > 0 {
                let path = UIBezierPath(arcCenter: .zero, radius: 33, startAngle: .pi / 2, endAngle: .pi / 2 + .pi * 2 * min(1, frac), clockwise: true)
                cooldownArc.path = path.cgPath
            } else {
                cooldownArc.path = nil
            }
        }
        if !isBot {
            let auto = !connected
            statusLabel.text = auto ? "AUTOPILOT" : ""
            alpha = auto ? 0.6 : 1
        }
    }

    func dashBurst() {
        guard let scene = scene, let parent = parent else { return }
        _ = scene
        for k in 0..<3 {
            let ghost = SKShapeNode(circleOfRadius: 28)
            ghost.fillColor = Palette.teamUIColor(team).withAlphaComponent(0.35)
            ghost.strokeColor = .clear
            ghost.position = position
            ghost.zPosition = 15
            parent.addChild(ghost)
            ghost.run(.sequence([.wait(forDuration: Double(k) * 0.04), .group([.fadeOut(withDuration: 0.3), .scale(to: 0.6, duration: 0.3)]), .removeFromParent()]))
        }
    }
}

/// The shard: a charged crystal whose colour shows which team last struck it
/// and whose glow and trail grow with its charge.
final class ShardSprite: SKNode {
    private let crystal = SKShapeNode(rectOf: CGSize(width: 30, height: 30), cornerRadius: 4)
    private let inner = SKShapeNode(rectOf: CGSize(width: 14, height: 14), cornerRadius: 2)
    private let glow = SKSpriteNode(texture: GameScene.glowTexture)
    private let trail = SKEmitterNode()
    private var heatPips: [SKShapeNode] = []
    private var displayPos: CGPoint?

    init(trailTarget: SKNode) {
        super.init()
        glow.size = CGSize(width: 120, height: 120)
        glow.colorBlendFactor = 1
        glow.blendMode = .add
        addChild(glow)
        trail.particleTexture = GameScene.sparkTexture
        trail.particleBirthRate = 0
        trail.particleLifetime = 0.35
        trail.particleAlphaSpeed = -2.8
        trail.particleScale = 1.6
        trail.particleScaleSpeed = -3
        trail.particleColorBlendFactor = 1
        trail.particleBlendMode = .add
        trail.targetNode = trailTarget
        addChild(trail)
        crystal.zRotation = .pi / 4
        crystal.lineWidth = 3
        crystal.strokeColor = .white
        addChild(crystal)
        inner.zRotation = .pi / 4
        inner.fillColor = .white
        inner.strokeColor = .clear
        addChild(inner)
        for k in 0..<6 {
            let pip = SKShapeNode(circleOfRadius: 3.5)
            let a = CGFloat(k) / 6 * .pi * 2
            pip.position = CGPoint(x: cos(a) * 30, y: sin(a) * 30)
            pip.fillColor = .white
            pip.strokeColor = .clear
            pip.isHidden = true
            addChild(pip)
            heatPips.append(pip)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(state s: ShardState, target: CGPoint, follow: CGFloat) {
        isHidden = !s.active
        guard s.active else { displayPos = nil; trail.particleBirthRate = 0; return }
        if let d = displayPos, hypot(d.x - target.x, d.y - target.y) < 90 {
            displayPos = CGPoint(x: d.x + (target.x - d.x) * min(1, follow * 1.3), y: d.y + (target.y - d.y) * min(1, follow * 1.3))
        } else {
            displayPos = target
        }
        position = displayPos!
        let color = Palette.teamUIColor(Int(s.owner))
        crystal.fillColor = color
        glow.color = color
        let heat = CGFloat(s.heat)
        glow.size = CGSize(width: 110 + heat * 30, height: 110 + heat * 30)
        glow.alpha = 0.55 + heat * 0.06
        let speed = CGFloat(s.vel.length.double)
        trail.particleColor = color
        trail.particleBirthRate = speed > 2 ? 60 + heat * 50 : 0
        crystal.zRotation += 0.02 + speed * 0.006
        inner.zRotation = crystal.zRotation
        for (k, pip) in heatPips.enumerated() { pip.isHidden = k >= Int(s.heat) }
    }
}
