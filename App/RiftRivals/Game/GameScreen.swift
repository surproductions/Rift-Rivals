import SwiftUI
import SpriteKit

/// Hosts the SpriteKit view and the multi-touch control layer.
struct GameViewContainer: UIViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeUIView(context: Context) -> UIView {
        let root = UIView()
        root.backgroundColor = UIColor(hex: 0x070A14)
        let sk = SKView()
        sk.ignoresSiblingOrder = true
        sk.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond // 120 on ProMotion iPhones
        sk.shouldCullNonVisibleNodes = true
        sk.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sk)
        let controls = TouchControlsView(sampler: model.sampler)
        controls.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(controls)
        for v in [sk, controls] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor), v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                v.topAnchor.constraint(equalTo: root.topAnchor), v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        let scene = GameScene(size: CGSize(width: 1000, height: 560))
        scene.model = model
        sk.presentScene(scene)
        model.controls = controls
        context.coordinator.controls = controls
        return root
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let team = model.hud.localTeam
        context.coordinator.controls?.teamColor = Palette.teamUIColor(team)
        context.coordinator.controls?.dashEnabled = !(model.controller.setup?.settings.modifiers.contains(.noDash) ?? false)
        context.coordinator.controls?.isHidden = model.hud.phase == .matchOver
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { weak var controls: TouchControlsView? }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        for v in uiView.subviews { (v as? SKView)?.presentScene(nil) }
    }
}

struct GameScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        ZStack {
            GameViewContainer().ignoresSafeArea()
            HUDOverlay()
            if let b = model.banner { BannerView(banner: b).allowsHitTesting(false).id(b.id) }
            if model.hud.paused && model.hud.phase != .matchOver { PauseOverlay() }
            if model.hud.phase == .matchOver { ResultsOverlay() }
        }
        .statusBarHidden(true)
    }
}

struct HUDOverlay: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        let h = model.hud
        let scale: CGFloat = prefs.largeHUD ? 1.25 : 1
        VStack(spacing: 4) {
            HStack(alignment: .top) {
                Button { model.pauseToggle() } label: {
                    Image(systemName: "pause.fill").font(.system(size: 16 * scale, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Palette.panel.opacity(0.8)))
                }
                .foregroundStyle(Palette.text)
                .accessibilityLabel("Pause")
                Spacer()
                scoreboard(h, scale: scale)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    QualityDot(quality: h.quality)
                    Text(h.arenaName.uppercased()).font(Typo.label(9)).foregroundStyle(Palette.dim)
                }
                .frame(width: 90, alignment: .trailing)
            }
            if let c = h.connectionBanner {
                Text(c).font(Typo.body(13)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Palette.danger.opacity(0.85))).foregroundStyle(.white)
            }
            Spacer()
            if !h.diagnostics.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(h.diagnostics, id: \.self) { Text($0) }
                    }
                    .font(Typo.mono(9.5))
                    .foregroundStyle(Palette.ok)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.6)))
                    Spacer()
                }
                .padding(.bottom, 150)
                .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    func scoreboard(_ h: HUDState, scale: CGFloat) -> some View {
        HStack(spacing: 12 * scale) {
            roundPips(h.rounds.0, need: h.bestOf / 2 + 1, team: 0).opacity(h.bestOf > 1 ? 1 : 0)
            Text("\(h.scores.0)").font(Typo.display(34 * scale)).foregroundStyle(Palette.team(0)).monospacedDigit()
            VStack(spacing: 0) {
                Text(h.timeText).font(Typo.title(20 * scale)).monospacedDigit()
                    .foregroundStyle(h.overtime ? Palette.gold : Palette.text)
                Text(h.bestOf > 1 ? "ROUND \(h.round)" : h.formatLabel).font(Typo.label(9 * scale)).tracking(2).foregroundStyle(Palette.dim)
            }
            .frame(minWidth: 70 * scale)
            Text("\(h.scores.1)").font(Typo.display(34 * scale)).foregroundStyle(Palette.team(1)).monospacedDigit()
            roundPips(h.rounds.1, need: h.bestOf / 2 + 1, team: 1).opacity(h.bestOf > 1 ? 1 : 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .background(BladeShape(slant: 18).fill(Palette.ink.opacity(0.75)))
        .overlay(BladeShape(slant: 18).stroke(Palette.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ember \(h.scores.0), Tide \(h.scores.1), \(h.timeText) remaining")
    }

    func roundPips(_ won: Int, need: Int, team: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<max(1, need), id: \.self) { k in
                Circle().fill(k < won ? Palette.team(team) : Palette.line).frame(width: 7, height: 7)
            }
        }
    }
}

struct BannerView: View {
    var banner: Banner
    @State private var shown = false
    var body: some View {
        VStack(spacing: 4) {
            Text(banner.text)
                .font(banner.big ? Typo.display(110) : (banner.small ? Typo.title(20) : Typo.display(46)))
                .tracking(banner.small ? 2 : 4)
                .foregroundStyle(banner.color)
                .shadow(color: banner.color.opacity(0.7), radius: 16)
            if let s = banner.subtitle {
                Text(s.uppercased()).font(Typo.title(16)).tracking(3).foregroundStyle(Palette.text)
            }
        }
        .padding(.top, banner.small ? 70 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: banner.small ? .top : .center)
        .scaleEffect(shown ? 1 : (banner.big ? 1.6 : 0.8))
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { shown = true } }
    }
}

struct PauseOverlay: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let h = model.hud
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                if let r = h.resumeIn {
                    Text("RESUMING").font(Typo.title(18)).tracking(4).foregroundStyle(Palette.dim)
                    Text("\(Int(r.rounded(.up)))").font(Typo.display(90)).foregroundStyle(Palette.rift)
                } else {
                    Text("PAUSED").font(Typo.display(48)).tracking(6).foregroundStyle(Palette.text)
                    if !h.pausedBy.isEmpty && !h.isPractice {
                        Text("by \(h.pausedBy)").font(Typo.body(14)).foregroundStyle(Palette.dim)
                    }
                    if let c = h.connectionBanner { Text(c).font(Typo.body(13)).foregroundStyle(Palette.gold) }
                    Button("RESUME") { model.pauseToggle() }
                        .buttonStyle(BladeButtonStyle(color: Palette.ok))
                        .frame(width: 260)
                    Button(h.isPractice ? "QUIT TO MENU" : "LEAVE MATCH") { model.leaveSession() }
                        .buttonStyle(BladeButtonStyle(color: Palette.danger, filled: false))
                        .frame(width: 260)
                    if !h.isPractice && !h.isHost {
                        Text("Clients may pause twice per team per match. The pausing player or host resumes.")
                            .font(Typo.label(10)).foregroundStyle(Palette.dim)
                    }
                }
            }
        }
    }
}

struct ResultsOverlay: View {
    @EnvironmentObject var model: AppModel
    @State private var shown = false

    var body: some View {
        let h = model.hud
        let winner = max(0, h.matchWinner)
        let won = h.localTeam == winner
        let mvp = h.players.max { score($0) < score($1) }
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 10) {
                Text(won ? "VICTORY" : "DEFEAT").font(Typo.display(54)).tracking(8)
                    .foregroundStyle(won ? Palette.team(winner) : Palette.dim)
                    .shadow(color: Palette.team(winner).opacity(0.6), radius: 20)
                Text("\(TeamInfo.names[winner]) WINS  \(h.bestOf > 1 ? "\(h.rounds.0)–\(h.rounds.1) in rounds" : "\(h.scores.0)–\(h.scores.1)")")
                    .font(Typo.title(16)).tracking(3).foregroundStyle(Palette.text)
                statsTable(h, mvp: mvp?.id)
                    .frame(maxWidth: 620)
                HStack(spacing: 12) {
                    if h.isPractice {
                        Button("PLAY AGAIN") { model.rematch() }.buttonStyle(BladeButtonStyle(color: Palette.ok))
                        Button("MENU") { model.leaveSession() }.buttonStyle(BladeButtonStyle(color: Palette.dim, filled: false))
                    } else if h.isHost {
                        Button("REMATCH") { model.rematch() }.buttonStyle(BladeButtonStyle(color: Palette.ok))
                        Button("LOBBY") { model.backToLobby() }.buttonStyle(BladeButtonStyle(color: Palette.rift, filled: false))
                        Button("CLOSE") { model.leaveSession() }.buttonStyle(BladeButtonStyle(color: Palette.danger, filled: false))
                    } else {
                        Text("Waiting for the host…").font(Typo.body(14)).foregroundStyle(Palette.dim)
                        Button("LEAVE") { model.leaveSession() }.buttonStyle(BladeButtonStyle(color: Palette.danger, filled: false))
                            .frame(width: 160)
                    }
                }
                .frame(maxWidth: 560)
            }
            .padding(20)
            .scaleEffect(shown ? 1 : 0.92)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.35)) { shown = true } }
        }
    }

    func score(_ p: HUDPlayer) -> Int { p.goals * 5 + p.assists * 3 + p.shatters * 2 + p.parries }

    func statsTable(_ h: HUDState, mvp: Int?) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text("PLAYER").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(["G", "A", "SHT", "PRY", "DWN"], id: \.self) { Text($0).frame(width: 44) }
            }
            .font(Typo.label(10)).tracking(1).foregroundStyle(Palette.dim)
            ForEach(h.players) { p in
                HStack {
                    HStack(spacing: 6) {
                        Text(Palette.teamGlyph(p.team)).foregroundStyle(Palette.team(p.team))
                        Text(p.name).foregroundStyle(p.isLocal ? Palette.text : Palette.text.opacity(0.85))
                        if p.isBot { Text("BOT").font(Typo.label(9)).foregroundStyle(Palette.dim) }
                        if p.id == mvp { Text("MVP").font(Typo.label(9)).padding(.horizontal, 5).background(Capsule().fill(Palette.gold)).foregroundStyle(Palette.ink) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach([p.goals, p.assists, p.shatters, p.parries, p.timesShattered].indices, id: \.self) { k in
                        Text("\([p.goals, p.assists, p.shatters, p.parries, p.timesShattered][k])").frame(width: 44).monospacedDigit()
                    }
                }
                .font(Typo.body(13))
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(p.isLocal ? Palette.panelHi : Color.clear))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.panel.opacity(0.9)))
    }
}
