import SwiftUI
import UIKit
import QuartzCore

struct Banner: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var subtitle: String?
    var color: Color
    var big = false
    var small = false
}

struct HUDPlayer: Identifiable, Equatable {
    var id: Int
    var name: String
    var team: Int
    var isBot: Bool
    var isLocal: Bool
    var goals: Int
    var assists: Int
    var shatters: Int
    var parries: Int
    var timesShattered: Int
    var connected: Bool
    var quality: String
}

struct HUDState: Equatable {
    var scores = (0, 0)
    var rounds = (0, 0)
    var bestOf = 1
    var round = 1
    var timeText = "--:--"
    var phase: MatchPhase = .countdown
    var overtime = false
    var paused = false
    var pausedBy = ""
    var resumeIn: Double?
    var connectionBanner: String?
    var diagnostics: [String] = []
    var quality = "Excellent"
    var players: [HUDPlayer] = []
    var matchWinner = -1
    var isHost = true
    var isPractice = true
    var localTeam = 0
    var arenaName = ""
    var formatLabel = ""
    var pausesLeftNote = ""

    static func == (a: HUDState, b: HUDState) -> Bool {
        a.scores == b.scores && a.rounds == b.rounds && a.round == b.round && a.timeText == b.timeText && a.phase == b.phase
            && a.overtime == b.overtime && a.paused == b.paused && a.resumeIn.map { Int($0 * 10) } == b.resumeIn.map { Int($0 * 10) }
            && a.connectionBanner == b.connectionBanner && a.diagnostics == b.diagnostics && a.quality == b.quality
            && a.players == b.players && a.matchWinner == b.matchWinner && a.isHost == b.isHost && a.pausedBy == b.pausedBy
    }
}

enum Screen: Equatable {
    case menu, practiceSetup, join, lobby, game, settings, howTo
}

final class AppModel: ObservableObject {
    @Published var screen: Screen = .menu
    @Published var lobby: LobbyState?
    @Published var rooms: [RoomAdvert] = []
    @Published var hud = HUDState()
    @Published var banner: Banner?
    @Published var alert: String?
    @Published var startBlockers: [String] = []
    @Published var localMemberID: UInt8?
    @Published var practiceSettings: MatchSettings
    @Published var browserState = ""

    let prefs = Preferences.shared
    let controller: SessionController
    let sampler = InputSampler()
    let provider = BonjourNetworkProvider()
    private var browser: BonjourRoomBrowser?
    private var displayLink: CADisplayLink?
    private var lastSceneFrame: CFTimeInterval = 0
    private var lastPublish: CFTimeInterval = 0
    private var bannerClear: DispatchWorkItem?
    private var backgroundedAt: CFTimeInterval?
    weak var controls: TouchControlsView?

    init() {
        controller = SessionController(token: Preferences.shared.deviceToken, playerName: Preferences.shared.playerName)
        if let d = Preferences.shared.lastSettings, let s = try? JSONDecoder().decode(MatchSettings.self, from: d) {
            practiceSettings = s
        } else {
            practiceSettings = MatchSettings(format: .duo, roundSeconds: 120, goalsToWin: 5, bestOf: 1, arena: .foundry, botDifficulty: .normal)
        }
        let link = CADisplayLink(target: self, selector: #selector(displayTick))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        // Attract/demo mode used by CI to verify rendering: a full bot match.
        if ProcessInfo.processInfo.arguments.contains("-RiftDemo") {
            Preferences.shared.hasSeenTutorial = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startDemo() }
        }
    }

    func startDemo() {
        var s = MatchSettings(format: .duo, roundSeconds: 120, goalsToWin: 5, bestOf: 1, arena: .pillarDrift, botDifficulty: .hard)
        s.modifiers = []
        controller.startPractice(settings: s, seed: 2026, now: CACurrentMediaTime(), demo: true)
        screen = .game
    }

    // MARK: - Loop

    @objc private func displayTick() {
        let now = CACurrentMediaTime()
        // While the game scene renders it drives the loop itself (frame-aligned at up to 120 Hz).
        if now - lastSceneFrame > 0.1 { step(now: now) }
    }

    /// Called by GameScene every rendered frame.
    func sceneFrame(now: CFTimeInterval) {
        lastSceneFrame = now
        step(now: now)
    }

    private func step(now: CFTimeInterval) {
        controller.playerName = prefs.playerName
        let inGame = screen == .game
        controller.update(now: now, input: inGame && !controller.isPaused ? sampler : nil)
        if let b = browser, screen == .join, now - lastPublish > 0.25 {
            let r = b.rooms
            if r != rooms { rooms = r }
            if browserState != b.state { browserState = b.state }
        }
        let interval = inGame ? 1.0 / 15 : 1.0 / 8
        if now - lastPublish >= interval {
            lastPublish = now
            publish()
        }
        if inGame, let e = controller.engine, let lp = e.localPlayer, lp < e.state.players.count {
            let p = e.state.players[lp]
            controls?.setCooldowns(pulse: CGFloat(p.pulseCooldown) / CGFloat(e.ctx.pulseCooldown),
                                   dash: CGFloat(p.dashCooldown) / CGFloat(Tuning.dashCooldown))
        }
    }

    private func publish() {
        // Session closed underneath us (host left, kicked, …).
        if case .client(let c) = controller.mode, case .closed(let why) = c.phase {
            controller.end()
            goMenu(alert: why)
            return
        }
        let l = controller.lobby
        if l != lobby { lobby = l }
        if localMemberID != controller.localMemberID { localMemberID = controller.localMemberID }
        if case .host(let h) = controller.mode {
            let b = h.startBlockers
            if b != startBlockers { startBlockers = b }
        }
        // Screen transitions driven by the session.
        if controller.engine != nil && screen == .lobby { screen = .game; sampler.reset() }
        if controller.engine == nil && screen == .game && controller.isNetworked { screen = .lobby }
        if screen == .game { updateHUD() }
    }

    func isSlotConnected(_ index: Int) -> Bool {
        guard let setup = controller.setup, index < setup.slots.count, let id = setup.slots[index].memberID else { return true }
        return lobby?.members.first { $0.id == id }?.connected ?? true
    }

    private func updateHUD() {
        guard let e = controller.engine, let setup = controller.setup else { return }
        let s = e.state
        var h = HUDState()
        h.scores = (s.score(team: 0), s.score(team: 1))
        h.rounds = (s.rounds(team: 0), s.rounds(team: 1))
        h.bestOf = Int(setup.settings.bestOf)
        h.round = Int(s.round)
        if s.overtime {
            h.timeText = "OT"
        } else if setup.settings.roundSeconds == 0 {
            h.timeText = "∞"
        } else {
            let secs = Int((Double(s.timeRemaining) / 60).rounded(.up))
            h.timeText = String(format: "%d:%02d", secs / 60, secs % 60)
        }
        h.phase = s.phase
        h.overtime = s.overtime
        h.paused = controller.isPaused
        h.resumeIn = controller.resumeCountdown
        h.connectionBanner = controller.connectionBanner
        let diag = controller.diagnostics
        h.diagnostics = prefs.showDiagnostics ? diag.lines : []
        h.quality = controller.isNetworked ? diag.quality.label : "Local"
        h.matchWinner = Int(s.matchWinner)
        h.isHost = controller.isHost
        if case .practice = controller.mode { h.isPractice = true } else { h.isPractice = false }
        h.localTeam = e.localPlayer.map { setup.team(of: $0) } ?? 0
        h.arenaName = setup.settings.arena.displayName
        h.formatLabel = setup.settings.format.label
        if case .host(let host) = controller.mode, host.paused {
            h.pausedBy = lobby?.members.first { $0.id == host.pausedByMember }?.name ?? ""
        }
        if case .client(let c) = controller.mode, c.paused {
            h.pausedBy = lobby?.members.first { $0.id == c.pausedByMember }?.name ?? ""
        }
        h.players = s.players.enumerated().map { i, p in
            let slot = setup.slots[i]
            var q = "Excellent"
            if case .host(let host) = controller.mode, let id = slot.memberID { q = host.quality(ofMember: id).label }
            return HUDPlayer(id: i, name: slot.name.replacingOccurrences(of: " [BOT]", with: ""), team: setup.team(of: i), isBot: slot.isBot,
                             isLocal: i == e.localPlayer, goals: Int(p.goals), assists: Int(p.assists), shatters: Int(p.shatters),
                             parries: Int(p.parries), timesShattered: Int(p.timesShattered), connected: isSlotConnected(i), quality: q)
        }
        if h != hud { hud = h }
    }

    // MARK: - Banners

    func flashBanner(_ text: String, color: UIColor, subtitle: String? = nil, big: Bool = false, small: Bool = false) {
        // Small banners never override a big announcement still on screen.
        if small, let b = banner, !b.small { return }
        banner = Banner(text: text, subtitle: subtitle, color: Color(color), big: big, small: small)
        bannerClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.banner = nil }
        bannerClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (big ? 0.85 : 1.6), execute: work)
    }

    // MARK: - Navigation & actions

    func goMenu(alert: String? = nil) {
        stopBrowsing()
        screen = .menu
        lobby = nil
        if let a = alert { self.alert = a }
    }

    func savePracticeSettings() {
        prefs.lastSettings = try? JSONEncoder().encode(practiceSettings)
    }

    func startPractice() {
        savePracticeSettings()
        SoundEngine.shared.start()
        controller.playerName = prefs.playerName
        controller.startPractice(settings: practiceSettings, seed: UInt64.random(in: 1...UInt64.max), now: CACurrentMediaTime())
        sampler.reset()
        screen = .game
    }

    func hostRoom() {
        SoundEngine.shared.start()
        controller.playerName = prefs.playerName
        do {
            var s = practiceSettings
            s.fillWithBots = true
            try controller.host(provider: provider, settings: s, seed: UInt64.random(in: 1...UInt64.max), now: CACurrentMediaTime())
            screen = .lobby
            publish()
        } catch {
            alert = "Could not open a room: \(error.localizedDescription). Check that Local Network access is allowed in Settings › Privacy › Local Network."
        }
    }

    func openJoin() {
        SoundEngine.shared.start()
        rooms = []
        let b = BonjourRoomBrowser()
        b.start()
        browser = b
        screen = .join
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
    }

    func join(_ advert: RoomAdvert) {
        controller.playerName = prefs.playerName
        do {
            try controller.join(provider: provider, advert: advert, now: CACurrentMediaTime())
            stopBrowsing()
            screen = .lobby
        } catch {
            alert = "Could not join: \(error.localizedDescription)"
        }
    }

    func leaveSession() {
        controller.end()
        sampler.reset()
        goMenu()
    }

    // Lobby
    var hostSession: HostSession? { if case .host(let h) = controller.mode { return h }; return nil }
    var clientSession: ClientSession? { if case .client(let c) = controller.mode { return c }; return nil }

    func setTeam(_ t: UInt8) {
        if let h = hostSession { h.setTeam(member: h.localMemberID, team: t) }
        clientSession?.setTeam(t)
        SoundEngine.shared.play(.uiTap)
    }

    func toggleReady() {
        guard let c = clientSession, let me = c.memberID else { return }
        let ready = lobby?.members.first { $0.id == me }?.ready ?? false
        c.setReady(!ready)
        SoundEngine.shared.play(.uiConfirm)
    }

    func updateRoomSettings(_ s: MatchSettings) {
        guard let h = hostSession else { return }
        if !h.updateSettings(s) { alert = "Too many players for that format." }
        practiceSettings = s
        savePracticeSettings()
        publish()
    }

    func moveMember(_ id: UInt8, to team: UInt8) { hostSession?.setTeam(member: id, team: team) }
    func kick(_ id: UInt8) { hostSession?.kick(member: id) }

    func startMatch() {
        guard let h = hostSession else { return }
        if h.startMatch() { SoundEngine.shared.play(.go); sampler.reset() }
    }

    // In game
    func pauseToggle() {
        switch controller.mode {
        case .practice(let p): p.setPaused(!p.paused, now: CACurrentMediaTime())
        case .host(let h): if h.paused { h.resume() } else { h.pause() }
        case .client(let c): if c.paused { c.requestResume() } else { c.requestPause() }
        case .idle: break
        }
        controls?.releaseAll()
    }

    func rematch() {
        switch controller.mode {
        case .practice: startPractice()
        case .host(let h): h.rematch()
        default: break
        }
        sampler.reset()
    }

    func backToLobby() {
        if case .practice = controller.mode { leaveSession(); return }
        hostSession?.backToLobby()
        screen = .lobby
    }

    // MARK: - App lifecycle

    func enterBackground() {
        backgroundedAt = CACurrentMediaTime()
        if case .practice(let p) = controller.mode, !p.paused { p.setPaused(true, now: CACurrentMediaTime()) }
        controls?.releaseAll()
    }

    func returnFromForeground() {
        SoundEngine.shared.resumeIfNeeded()
        guard let t = backgroundedAt else { return }
        backgroundedAt = nil
        let away = CACurrentMediaTime() - t
        clientSession?.handleReturnFromBackground(awayFor: away)
        // A host that was away long enough to be replaced steps down automatically
        // (HostSession watches discovery for a newer host of the same match).
    }
}
