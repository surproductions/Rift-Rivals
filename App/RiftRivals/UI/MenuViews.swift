import SwiftUI

@main
struct RiftRivalsApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(Preferences.shared)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background: model.enterBackground()
            case .active: model.returnFromForeground()
            default: break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        ZStack {
            RiftBackdrop()
            switch model.screen {
            case .menu: MainMenuView().transition(.opacity)
            case .practiceSetup: PracticeSetupView().transition(.move(edge: .trailing).combined(with: .opacity))
            case .join: JoinView().transition(.move(edge: .trailing).combined(with: .opacity))
            case .lobby: LobbyView().transition(.opacity)
            case .game: GameScreen().transition(.opacity)
            case .settings: SettingsView().transition(.move(edge: .trailing).combined(with: .opacity))
            case .howTo: HowToPlayView().transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(prefs.reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.screen)
        .alert("Rift Rivals", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .onAppear {
            if !prefs.hasSeenTutorial { model.screen = .howTo }
        }
    }
}

struct BackBar: View {
    var title: String
    var action: () -> Void
    var body: some View {
        HStack {
            Button(action: { SoundEngine.shared.play(.uiTap); action() }) {
                Label("Back", systemImage: "chevron.left").font(Typo.body(15))
            }
            .foregroundStyle(Palette.dim)
            Spacer()
            Text(title.uppercased()).font(Typo.title(18)).tracking(3).foregroundStyle(Palette.text)
            Spacer()
            Color.clear.frame(width: 60, height: 1)
        }
    }
}

struct MainMenuView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences
    @State private var appear = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    Spacer()
                    RiftLogo(size: min(64, geo.size.width * 0.07))
                    Text("Strike the shard. Shatter your rivals. Break their rift.")
                        .font(Typo.body(15)).foregroundStyle(Palette.dim)
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.fill").foregroundStyle(Palette.rift)
                        TextField("Your name", text: $prefs.playerName)
                            .font(Typo.body(16))
                            .foregroundStyle(Palette.text)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .onChange(of: prefs.playerName) { v in
                                if v.count > 14 { prefs.playerName = String(v.prefix(14)) }
                            }
                    }
                    .padding(12)
                    .frame(maxWidth: 300)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.panel.opacity(0.9)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
                    Text("No account needed. Plays over local Wi-Fi — no servers.")
                        .font(Typo.label(11)).foregroundStyle(Palette.dim.opacity(0.8))
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 12) {
                    Spacer()
                    Button("HOST LOCAL MATCH") { SoundEngine.shared.play(.uiConfirm); model.hostRoom() }
                        .buttonStyle(BladeButtonStyle(color: Palette.team(0)))
                    Button("JOIN NEARBY") { SoundEngine.shared.play(.uiConfirm); model.openJoin() }
                        .buttonStyle(BladeButtonStyle(color: Palette.team(1)))
                    Button("PRACTICE VS BOTS") { SoundEngine.shared.play(.uiTap); model.screen = .practiceSetup }
                        .buttonStyle(BladeButtonStyle(color: Palette.rift, filled: false))
                    HStack(spacing: 12) {
                        Button("HOW TO PLAY") { SoundEngine.shared.play(.uiTap); model.screen = .howTo }
                            .buttonStyle(BladeButtonStyle(color: Palette.dim, filled: false, height: 42))
                        Button("SETTINGS") { SoundEngine.shared.play(.uiTap); model.screen = .settings }
                            .buttonStyle(BladeButtonStyle(color: Palette.dim, filled: false, height: 42))
                    }
                    Spacer()
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                        .font(Typo.mono(10)).foregroundStyle(Palette.dim.opacity(0.6))
                }
                .frame(width: min(340, geo.size.width * 0.38))
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 20)
            .opacity(appear ? 1 : 0)
            .offset(y: appear ? 0 : 12)
            .onAppear { withAnimation(.easeOut(duration: 0.5)) { appear = true } }
        }
    }
}

// MARK: - Settings editor shared by practice and lobby

struct MatchSettingsEditor: View {
    @Binding var settings: MatchSettings
    var editable = true
    var showBotFill = true
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("FORMAT") {
                Picker("Format", selection: $settings.format) {
                    ForEach(MatchFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("ARENA").font(Typo.label()).tracking(2).foregroundStyle(Palette.dim)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ArenaID.allCases, id: \.self) { a in
                            Button { settings.arena = a; SoundEngine.shared.play(.uiTap) } label: {
                                ArenaCard(arena: a, selected: settings.arena == a)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            row("ROUND") {
                Picker("Time", selection: $settings.roundSeconds) {
                    Text("1:00").tag(UInt16(60)); Text("2:00").tag(UInt16(120)); Text("3:00").tag(UInt16(180))
                    Text("5:00").tag(UInt16(300)); Text("∞").tag(UInt16(0))
                }.pickerStyle(.segmented)
            }
            row("GOALS") {
                Picker("Goals", selection: $settings.goalsToWin) {
                    Text("3").tag(UInt8(3)); Text("5").tag(UInt8(5)); Text("7").tag(UInt8(7)); Text("Time").tag(UInt8(0))
                }.pickerStyle(.segmented)
            }
            row("SERIES") {
                Picker("Best of", selection: $settings.bestOf) {
                    Text("Single").tag(UInt8(1)); Text("Best of 3").tag(UInt8(3)); Text("Best of 5").tag(UInt8(5))
                }.pickerStyle(.segmented)
            }
            row("BOTS") {
                Picker("Difficulty", selection: $settings.botDifficulty) {
                    ForEach(BotDifficulty.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("MODIFIERS").font(Typo.label()).tracking(2).foregroundStyle(Palette.dim)
                FlowChips(settings: $settings)
            }
            if showBotFill {
                Toggle("Fill empty slots with bots", isOn: $settings.fillWithBots).font(Typo.body(14))
                Toggle("Autopilot for disconnected players", isOn: $settings.autopilotOnDisconnect).font(Typo.body(14))
            }
        }
        .tint(Palette.rift)
        .disabled(!editable)
        .opacity(editable ? 1 : 0.75)
    }

    @ViewBuilder func row<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(title).font(Typo.label()).tracking(2).foregroundStyle(Palette.dim).frame(width: 74, alignment: .leading)
            c()
        }
    }
}

struct FlowChips: View {
    @Binding var settings: MatchSettings
    var body: some View {
        let mods = Modifiers.all
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(0..<mods.count, id: \.self) { k in
                let m = mods[k].0
                let name = mods[k].1
                let on = settings.modifiers.contains(m)
                Button {
                    if on { settings.modifiers.remove(m) } else { settings.modifiers.insert(m) }
                    SoundEngine.shared.play(.uiTap)
                } label: {
                    Text(name.uppercased())
                        .font(Typo.label(11)).tracking(1)
                        .padding(.vertical, 7).frame(maxWidth: .infinity)
                        .foregroundStyle(on ? Palette.ink : Palette.text)
                        .background(Capsule().fill(on ? Palette.rift : Palette.panelHi))
                        .overlay(Capsule().stroke(Palette.line))
                }
                .buttonStyle(.plain)
                .accessibilityValue(on ? "On" : "Off")
            }
        }
    }
}

struct ArenaCard: View {
    var arena: ArenaID
    var selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArenaThumbnail(arena: arena).frame(width: 128, height: 72)
            Text(arena.displayName.uppercased()).font(Typo.label(11)).tracking(1).foregroundStyle(Palette.text)
            Text(arena.blurb).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Palette.dim).lineLimit(2)
                .frame(width: 128, alignment: .leading)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Palette.panelHi : Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Palette.rift : Palette.line, lineWidth: selected ? 2 : 1))
    }
}

/// Mini-map drawn from the real arena geometry.
struct ArenaThumbnail: View {
    var arena: ArenaID
    var body: some View {
        Canvas { g, size in
            let a = Arena.make(arena)
            let sx = size.width / 1740, sy = size.height / 900
            func p(_ v: FxVec) -> CGPoint { CGPoint(x: (v.x.double + 70) * sx, y: size.height - v.y.double * sy) }
            g.fill(Path(CGRect(x: 0, y: size.height / 2 - 130 * sy, width: 70 * sx, height: 260 * sy)), with: .color(Palette.team(0).opacity(0.6)))
            g.fill(Path(CGRect(x: size.width - 70 * sx, y: size.height / 2 - 130 * sy, width: 70 * sx, height: 260 * sy)), with: .color(Palette.team(1).opacity(0.6)))
            var walls = Path()
            for s in a.segments where s.blocksShard { walls.move(to: p(s.a)); walls.addLine(to: p(s.b)) }
            g.stroke(walls, with: .color(Palette.rift), lineWidth: 1.4)
            for pl in a.pillars {
                let c = p(pl.base), r = pl.radius.double * sx
                g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Palette.rift.opacity(0.8)))
            }
            for pr in a.portals {
                for e in [pr.a, pr.b] {
                    let c = p(e), r = pr.radius.double * sx
                    g.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Color(hex: 0x9B8CFF)), lineWidth: 1.5)
                }
            }
            var mid = Path()
            mid.move(to: CGPoint(x: size.width / 2, y: 0)); mid.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            g.stroke(mid, with: .color(Palette.rift.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.ink2))
    }
}

// MARK: - Practice

struct PracticeSetupView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            BackBar(title: "Practice vs Bots") { model.screen = .menu }
            ScrollView {
                Panel(title: "Match") {
                    MatchSettingsEditor(settings: $model.practiceSettings, showBotFill: false)
                }
                Text("You play for EMBER. Every other slot is a bot at the chosen difficulty.")
                    .font(Typo.body(12)).foregroundStyle(Palette.dim).padding(.top, 4)
            }
            Button("START PRACTICE") { SoundEngine.shared.play(.go); model.startPractice() }
                .buttonStyle(BladeButtonStyle(color: Palette.team(0)))
                .frame(maxWidth: 360)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 14)
    }
}

// MARK: - Join

struct JoinView: View {
    @EnvironmentObject var model: AppModel
    @State private var code = ""

    var filtered: [RoomAdvert] {
        let c = RoomCode.normalize(code)
        let compatible = model.rooms.filter { $0.protocolVersion == NetProtocol.version }
        // One entry per room: the newest epoch (after a host migration).
        var newest: [String: RoomAdvert] = [:]
        for r in compatible { if (newest[r.roomCode]?.epoch ?? 0) <= r.epoch { newest[r.roomCode] = r } }
        let list = newest.values.sorted { $0.roomCode < $1.roomCode }
        return c.isEmpty ? list : list.filter { $0.roomCode.hasPrefix(c) }
    }

    var body: some View {
        VStack(spacing: 12) {
            BackBar(title: "Join Nearby") { model.stopBrowsing(); model.screen = .menu }
            HStack(alignment: .top, spacing: 16) {
                Panel(title: "Room code") {
                    TextField("ABCD", text: $code)
                        .font(Typo.display(34)).tracking(10)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .foregroundStyle(Palette.text)
                        .onChange(of: code) { v in code = RoomCode.normalize(v) }
                    Text("Type the code shown on the host's screen, or tap a room below.")
                        .font(Typo.body(12)).foregroundStyle(Palette.dim)
                    if let exact = filtered.first, filtered.count == 1, code.count == 4 {
                        Button("JOIN \(exact.roomCode)") { model.join(exact) }
                            .buttonStyle(BladeButtonStyle(color: Palette.team(1), height: 44))
                    }
                }
                .frame(width: 260)

                Panel(title: "Rooms on this network") {
                    if filtered.isEmpty {
                        VStack(spacing: 10) {
                            ProgressView().tint(Palette.rift)
                            Text("Searching for rooms…").font(Typo.body(14)).foregroundStyle(Palette.dim)
                            Text("Both devices need Wi-Fi (or Bluetooth for peer-to-peer) on, and Local Network access allowed for Rift Rivals.")
                                .font(Typo.body(11)).foregroundStyle(Palette.dim.opacity(0.8)).multilineTextAlignment(.center)
                            if model.browserState.hasPrefix("failed") || model.browserState.hasPrefix("waiting") {
                                Text(model.browserState).font(Typo.mono(10)).foregroundStyle(Palette.gold)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(filtered, id: \.endpoint) { r in RoomRow(room: r) { model.join(r) } }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 14)
    }
}

struct RoomRow: View {
    var room: RoomAdvert
    var action: () -> Void
    var body: some View {
        Button(action: { SoundEngine.shared.play(.uiConfirm); action() }) {
            HStack(spacing: 14) {
                Text(room.roomCode).font(Typo.title(24)).tracking(4).foregroundStyle(Palette.rift)
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.hostName).font(Typo.body(15)).foregroundStyle(Palette.text)
                    Text("\(room.format.label) · \(room.players) connected\(room.inMatch ? " · match in progress" : "")")
                        .font(Typo.label(11)).foregroundStyle(Palette.dim)
                }
                Spacer()
                Image(systemName: room.inMatch ? "lock.fill" : "arrow.right.circle.fill")
                    .font(.system(size: 22)).foregroundStyle(room.inMatch ? Palette.dim : Palette.team(1))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.panelHi))
        }
        .buttonStyle(.plain)
        .disabled(room.inMatch)
    }
}
