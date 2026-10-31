import SwiftUI
import UIKit

/// RIFT RIVALS visual identity: deep ink background, two team colours that
/// stay distinguishable for common colour-vision deficiencies, and a pale
/// "rift" accent used for neutral energy.
enum Palette {
    static let ink = Color(hex: 0x070A14)
    static let ink2 = Color(hex: 0x0E1426)
    static let panel = Color(hex: 0x131B33)
    static let panelHi = Color(hex: 0x1C2747)
    static let line = Color(hex: 0x2A3762)
    static let text = Color(hex: 0xEEF2FF)
    static let dim = Color(hex: 0x8C97BF)
    static let rift = Color(hex: 0xD9D2FF)
    static let gold = Color(hex: 0xFFD166)
    static let danger = Color(hex: 0xFF4D6D)
    static let ok = Color(hex: 0x5CF2A0)

    static func team(_ t: Int) -> Color { Color(teamUIColor(t)) }

    static func teamUIColor(_ t: Int) -> UIColor {
        let cb = Preferences.shared.colorblindPalette
        if t == 0 { return cb ? UIColor(hex: 0xFF9F1C) : UIColor(hex: 0xFF5A3C) }
        if t == 1 { return cb ? UIColor(hex: 0x3A86FF) : UIColor(hex: 0x22E1C3) }
        return UIColor(hex: 0xD9D2FF)
    }

    static func teamGlyph(_ t: Int) -> String { t == 0 ? "▲" : "◆" }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

enum Typo {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black, design: .rounded) }
    static func title(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .heavy, design: .rounded) }
    static func body(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func mono(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
    static func label(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .bold, design: .rounded) }
}

/// Slanted "blade" shape used for primary buttons and tabs.
struct BladeShape: Shape {
    var slant: CGFloat = 14
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + slant, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - slant, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct BladeButtonStyle: ButtonStyle {
    var color: Color = Palette.rift
    var filled = true
    var height: CGFloat = 50

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.title(17))
            .tracking(1.5)
            .foregroundStyle(filled ? Palette.ink : color)
            .frame(maxWidth: .infinity, minHeight: height)
            .padding(.horizontal, 18)
            .background(
                ZStack {
                    if filled {
                        BladeShape().fill(LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    } else {
                        BladeShape().fill(Palette.panel.opacity(0.85))
                        BladeShape().stroke(color.opacity(0.8), lineWidth: 1.5)
                    }
                }
                .shadow(color: color.opacity(filled ? 0.45 : 0.15), radius: configuration.isPressed ? 4 : 12)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(BladeShape())
    }
}

struct Panel<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = title {
                Text(t.uppercased()).font(Typo.label(11)).tracking(2).foregroundStyle(Palette.dim)
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.line, lineWidth: 1))
    }
}

/// The game logo: two team-coloured halves split by a bright diagonal rift.
struct RiftLogo: View {
    var size: CGFloat = 54
    var body: some View {
        ZStack {
            Text("RIFT RIVALS")
                .font(Typo.display(size))
                .tracking(size * 0.06)
                .foregroundStyle(LinearGradient(colors: [Palette.team(0), Palette.rift, Palette.team(1)],
                                                startPoint: .leading, endPoint: .trailing))
                .shadow(color: Palette.rift.opacity(0.35), radius: 18)
            // The rift: a thin bright slash across the word mark.
            Rectangle()
                .fill(LinearGradient(colors: [.clear, .white, .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: 3, height: size * 1.5)
                .rotationEffect(.degrees(22))
                .blendMode(.plusLighter)
                .opacity(0.9)
        }
        .accessibilityLabel("Rift Rivals")
    }
}

/// Animated backdrop: slow drifting rift lines over the ink gradient.
struct RiftBackdrop: View {
    @ObservedObject var prefs = Preferences.shared
    var body: some View {
        TimelineView(.animation(minimumInterval: prefs.reduceMotion ? 1 : 1 / 30, paused: prefs.reduceMotion)) { ctx in
            Canvas { g, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                g.fill(Path(CGRect(origin: .zero, size: size)),
                       with: .linearGradient(Gradient(colors: [Palette.ink2, Palette.ink]), startPoint: .zero,
                                             endPoint: CGPoint(x: size.width, y: size.height)))
                // Grid.
                var grid = Path()
                let step: CGFloat = 46
                var x: CGFloat = 0
                while x < size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                var y: CGFloat = 0
                while y < size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                g.stroke(grid, with: .color(Palette.line.opacity(0.25)), lineWidth: 0.5)
                // Drifting rifts.
                for k in 0..<5 {
                    let phase = t * (0.05 + Double(k) * 0.013) + Double(k) * 1.7
                    let cx = size.width * CGFloat(0.5 + 0.45 * sin(phase))
                    var p = Path()
                    p.move(to: CGPoint(x: cx - 120, y: -20))
                    p.addCurve(to: CGPoint(x: cx + 160, y: size.height + 20),
                               control1: CGPoint(x: cx + 80 * CGFloat(cos(phase * 1.3)), y: size.height * 0.3),
                               control2: CGPoint(x: cx - 60, y: size.height * 0.7))
                    let color: Color = k % 2 == 0 ? Palette.team(0) : Palette.team(1)
                    g.stroke(p, with: .color(color.opacity(0.10)), lineWidth: 22)
                    g.stroke(p, with: .color(color.opacity(0.35)), lineWidth: 1.2)
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct QualityDot: View {
    var quality: String
    var body: some View {
        let c: Color = {
            switch quality {
            case "Excellent": return Palette.ok
            case "Good": return Color(hex: 0xB8F25C)
            case "Unstable": return Palette.gold
            default: return Palette.danger
            }
        }()
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7).shadow(color: c, radius: 3)
            Text(quality).font(Typo.label(10)).foregroundStyle(c)
        }
    }
}
