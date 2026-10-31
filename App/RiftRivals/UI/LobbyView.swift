import SwiftUI

struct LobbyView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing = MatchSettings()
    @State private var showSettings = false

    var isHost: Bool { model.hostSession != nil }

    var body: some View {
        VStack(spacing: 10) {
            header
            if let lobby = model.lobby {
                HStack(alignment: .top, spacing: 14) {
                    TeamColumn(team: 0, lobby: lobby, isHost: isHost)
                    centre(lobby)
                    TeamColumn(team: 1, lobby: lobby, isHost: isHost)
                }
            } else {
                Spacer()
                ProgressView("Connecting to room…").tint(Palette.rift).font(Typo.body())
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .sheet(isPresented: $showSettings) {
            ZStack {
                Palette.ink.ignoresSafeArea()
                VStack(spacing: 10) {
                    HStack {
                        Text("MATCH SETTINGS").font(Typo.title(18)).tracking(3)
                        Spacer()
                        Button("Done") { model.updateRoomSettings(editing); showSettings = false }.font(Typo.body(16))
                    }
                    ScrollView { MatchSettingsEditor(settings: $editing) }
                }
                .padding(20)
            }
            .preferredColorScheme(.dark)
        }
    }

    var header: some View {
        HStack {
            Button { SoundEngine.shared.play(.uiTap); model.leaveSession() } label: {
                Label(isHost ? "Close room" : "Leave", systemImage: "xmark").font(Typo.body(14))
            }
            .foregroundStyle(Palette.dim)
            Spacer()
            if let l = model.lobby {
                VStack(spacing: 0) {
                    Text("ROOM CODE").font(Typo.label(10)).tracking(3).foregroundStyle(Palette.dim)
                    Text(l.roomCode).font(Typo.display(34)).tracking(12).foregroundStyle(Palette.rift)
                        .shadow(color: Palette.rift.opacity(0.4), radius: 10)
                        .accessibilityLabel("Room code \(l.roomCode.map(String.init).joined(separator: " "))")
                }
            }
            Spacer()
            if isHost {
                Button { editing = model.lobby?.settings ?? editing; showSettings = true } label: {
                    Label("Settings", systemImage: "slider.horizontal.3").font(Typo.body(14))
                }
                .foregroundStyle(Palette.text)
            } else {
                Color.clear.frame(width: 90, height: 1)
            }
        }
    }

    @ViewBuilder func centre(_ lobby: LobbyState) -> some View {
        VStack(spacing: 10) {
            Panel(title: "Match") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lobby.settings.format.label).font(Typo.title(26)).foregroundStyle(Palette.text)
                        Spacer()
                        ArenaThumbnail(arena: lobby.settings.arena).frame(width: 96, height: 54)
                    }
                    Text(lobby.settings.arena.displayName).font(Typo.body(14)).foregroundStyle(Palette.rift)
                    Text(summary(lobby.settings)).font(Typo.label(11)).foregroundStyle(Palette.dim)
                    if !lobby.settings.modifiers.isEmpty {
                        Text(Modifiers.all.filter { lobby.settings.modifiers.contains($0.0) }.map { $0.1 }.joined(separator: " · "))
                            .font(Typo.label(11)).foregroundStyle(Palette.gold)
                    }
                }
            }
            if isHost {
                let blockers = model.startBlockers
                Button("START MATCH") { model.startMatch() }
                    .buttonStyle(BladeButtonStyle(color: blockers.isEmpty ? Palette.ok : Palette.dim))
                    .disabled(!blockers.isEmpty)
                if !blockers.isEmpty {
                    Text(blockers.joined(separator: "\n")).font(Typo.label(11)).foregroundStyle(Palette.gold).multilineTextAlignment(.center)
                } else {
                    Text(lobby.members.count == 1 ? "Waiting for players to join… (or start now vs bots)" : "Everyone is ready.")
                        .font(Typo.label(11)).foregroundStyle(Palette.dim).multilineTextAlignment(.center)
                }
            } else {
                let me = lobby.members.first { $0.id == model.localMemberID }
                Button(me?.ready == true ? "READY ✓" : "READY UP") { model.toggleReady() }
                    .buttonStyle(BladeButtonStyle(color: me?.ready == true ? Palette.ok : Palette.rift, filled: me?.ready == true))
                Text("The host starts the match when everyone is ready.").font(Typo.label(11)).foregroundStyle(Palette.dim)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 250)
    }

    func summary(_ s: MatchSettings) -> String {
        let time = s.roundSeconds == 0 ? "Untimed" : "\(s.roundSeconds / 60):\(String(format: "%02d", s.roundSeconds % 60)) rounds"
        let goals = s.goalsToWin == 0 ? "most goals wins" : "first to \(s.goalsToWin)"
        let series = s.bestOf == 1 ? "single round" : "best of \(s.bestOf)"
        return "\(time) · \(goals) · \(series) · \(s.botDifficulty.label) bots"
    }
}

struct TeamColumn: View {
    @EnvironmentObject var model: AppModel
    var team: Int
    var lobby: LobbyState
    var isHost: Bool

    var body: some View {
        let members = lobby.members(onTeam: team)
        let size = lobby.settings.format.teamSize
        let color = Palette.team(team)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(Palette.teamGlyph(team)) \(TeamInfo.names[team])").font(Typo.title(20)).tracking(3).foregroundStyle(color)
                Spacer()
                Text("\(members.count)/\(size)").font(Typo.mono(12)).foregroundStyle(Palette.dim)
            }
            ForEach(members, id: \.id) { m in
                MemberRow(member: m, color: color, isLocal: m.id == model.localMemberID, canManage: isHost && !m.isHost, team: team)
            }
            ForEach(0..<max(0, size - members.count), id: \.self) { _ in
                HStack {
                    Image(systemName: lobby.settings.fillWithBots ? "cpu" : "person.badge.plus")
                    Text(lobby.settings.fillWithBots ? "Bot (\(lobby.settings.botDifficulty.label))" : "Open slot")
                    Spacer()
                }
                .font(Typo.body(13)).foregroundStyle(Palette.dim.opacity(0.7))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            if lobby.members.first(where: { $0.id == model.localMemberID })?.team != UInt8(team) && members.count < size {
                Button("JOIN \(TeamInfo.names[team])") { model.setTeam(UInt8(team)) }
                    .buttonStyle(BladeButtonStyle(color: color, filled: false, height: 38))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14).fill(color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.4)))
    }
}

struct MemberRow: View {
    @EnvironmentObject var model: AppModel
    var member: LobbyMember
    var color: Color
    var isLocal: Bool
    var canManage: Bool
    var team: Int

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(member.name).font(Typo.body(15)).foregroundStyle(Palette.text).lineLimit(1)
            if member.isHost { Image(systemName: "crown.fill").foregroundStyle(Palette.gold).font(.system(size: 11)) }
            if isLocal { Text("YOU").font(Typo.label(9)).padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(Palette.rift)).foregroundStyle(Palette.ink) }
            Spacer()
            if !member.connected {
                Text("Reconnecting").font(Typo.label(10)).foregroundStyle(Palette.danger)
            } else if !member.isHost {
                Text("\(member.rttMs) ms").font(Typo.mono(10)).foregroundStyle(Palette.dim)
            }
            Image(systemName: member.ready || member.isHost ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(member.ready || member.isHost ? Palette.ok : Palette.dim)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Palette.panelHi))
        .contextMenu {
            if canManage {
                Button("Move to \(TeamInfo.names[1 - team])") { model.moveMember(member.id, to: UInt8(1 - team)) }
                Button("Remove from room", role: .destructive) { model.kick(member.id) }
            }
        }
    }
}
