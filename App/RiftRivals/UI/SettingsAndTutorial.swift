import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        VStack(spacing: 12) {
            BackBar(title: "Settings") { model.screen = .menu }
            ScrollView {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        Panel(title: "Player") {
                            TextField("Name", text: $prefs.playerName).font(Typo.body(16))
                                .textInputAutocapitalization(.words).autocorrectionDisabled()
                            Text("Shown to other players. Stored only on this device.").font(Typo.label(10)).foregroundStyle(Palette.dim)
                        }
                        Panel(title: "Audio & feel") {
                            HStack {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Palette.dim)
                                Slider(value: $prefs.soundVolume, in: 0...1, onEditingChanged: { _ in SoundEngine.shared.play(.uiTap) })
                            }
                            Toggle("Haptics", isOn: $prefs.haptics)
                            Toggle("Screen shake", isOn: $prefs.screenShake)
                        }
                        Panel(title: "Controls") {
                            Toggle("Left-handed layout (stick on the right)", isOn: $prefs.leftHanded)
                            Toggle("Fixed joystick position", isOn: $prefs.fixedJoystick)
                        }
                    }
                    VStack(spacing: 14) {
                        Panel(title: "Accessibility") {
                            Toggle("Colour-blind team palette (orange / blue)", isOn: $prefs.colorblindPalette)
                            Toggle("Reduce motion & flashes", isOn: $prefs.reduceMotion)
                            Toggle("Larger HUD", isOn: $prefs.largeHUD)
                            Text("Teams are also marked by shape: ▲ Ember, ◆ Tide.").font(Typo.label(10)).foregroundStyle(Palette.dim)
                        }
                        Panel(title: "Network") {
                            Toggle("Show network diagnostics overlay", isOn: $prefs.showDiagnostics)
                            Text("Shows tick, host, RTT, jitter, loss, input delay, prediction depth, rollbacks, state hash and simulation cost during matches.")
                                .font(Typo.label(10)).foregroundStyle(Palette.dim)
                        }
                        Panel(title: "About") {
                            Text("RIFT RIVALS — original local multiplayer arena game. Deterministic 60 Hz fixed-point simulation with rollback netcode over local Wi-Fi / peer-to-peer. No accounts, no servers.")
                                .font(Typo.body(12)).foregroundStyle(Palette.dim)
                            Button("Replay tutorial") { model.screen = .howTo }.font(Typo.body(14))
                        }
                    }
                }
                .font(Typo.body(14))
                .tint(Palette.rift)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 14)
    }
}

struct HowToPlayView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Preferences
    @State private var page = 0

    struct Card { let icon: String; let title: String; let text: String; let color: Color }
    var cards: [Card] {
        [
            Card(icon: "diamond.fill", title: "Break their rift", text: "Two teams — EMBER ▲ and TIDE ◆ — fight over a charged shard. Drive it into the glowing goal on the enemy side to score.", color: Palette.rift),
            Card(icon: "dot.radiowaves.left.and.right", title: "Pulse", text: "Tap PULSE to fire a shockwave. It launches the shard away from you — aim with the stick. Pulse at point-blank range for a PERFECT strike: faster and more charged.", color: Palette.team(0)),
            Card(icon: "bolt.fill", title: "Charge & shatter", text: "Every hit charges the shard (pips around it) and paints it your colour. A charged shard SHATTERS any rival it hits — they respawn after a moment.", color: Palette.gold),
            Card(icon: "shield.lefthalf.filled", title: "Parry or dash", text: "Incoming charged shard? Pulse it back to PARRY, or DASH through it — dashing makes you intangible. Body-blocking drains its charge.", color: Palette.team(1)),
            Card(icon: "person.3.fill", title: "Play as a team", text: "Your pulse slingshots teammates forward and knocks rivals back. Hold your lane, set up passes, and rotate a defender to guard your rift.", color: Palette.ok),
        ]
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("HOW TO PLAY").font(Typo.title(18)).tracking(3)
                Spacer()
                Button("Skip") { finish() }.font(Typo.body(14)).foregroundStyle(Palette.dim)
            }
            TabView(selection: $page) {
                ForEach(cards.indices, id: \.self) { k in
                    let c = cards[k]
                    HStack(spacing: 30) {
                        ZStack {
                            Circle().fill(c.color.opacity(0.15)).frame(width: 150, height: 150)
                            Circle().stroke(c.color.opacity(0.6), lineWidth: 2).frame(width: 150, height: 150)
                            Image(systemName: c.icon).font(.system(size: 60, weight: .bold)).foregroundStyle(c.color)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(k + 1) / \(cards.count)").font(Typo.mono(12)).foregroundStyle(Palette.dim)
                            Text(c.title.uppercased()).font(Typo.display(34)).foregroundStyle(Palette.text)
                            Text(c.text).font(Typo.body(16)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 440, alignment: .leading)
                    }
                    .tag(k)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button(page == cards.count - 1 ? "LET'S PLAY" : "NEXT") {
                SoundEngine.shared.play(.uiTap)
                if page == cards.count - 1 { finish() } else { withAnimation { page += 1 } }
            }
            .buttonStyle(BladeButtonStyle(color: Palette.rift))
            .frame(width: 280)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 14)
    }

    func finish() {
        prefs.hasSeenTutorial = true
        model.screen = .menu
    }
}
