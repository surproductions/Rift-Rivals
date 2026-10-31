import AVFoundation
import UIKit

/// Original procedurally synthesized sound design — every effect is generated
/// at launch from oscillators and filtered noise, so there are no third-party
/// samples. Low-latency playback through a pool of AVAudioPlayerNodes.
final class SoundEngine {
    static let shared = SoundEngine()

    enum Sfx: CaseIterable {
        case pulse, perfect, parry, clash, dash, shatter, respawn, bounce, portal, goal, countdown, go, roundOver, uiTap, uiConfirm
    }

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [Sfx: AVAudioPCMBuffer] = [:]
    private let format: AVAudioFormat
    private var started = false
    private var lastPlay: [Sfx: CFTimeInterval] = [:]

    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notify = UINotificationFeedbackGenerator()

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        for _ in 0..<12 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            players.append(p)
        }
        for s in Sfx.allCases { buffers[s] = synth(s) }
    }

    func start() {
        guard !started else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            players.forEach { $0.play() }
            started = true
        } catch {
            started = false
        }
    }

    func resumeIfNeeded() {
        if !engine.isRunning { started = false; start() }
    }

    func play(_ s: Sfx, volume: Float = 1, pitch: Float = 1) {
        let vol = Float(Preferences.shared.soundVolume) * volume
        guard vol > 0.01, let buf = buffers[s] else { return }
        if !started { start() }
        guard started else { return }
        // Rate-limit identical sounds (e.g. many bounces in one frame).
        let now = CACurrentMediaTime()
        if let last = lastPlay[s], now - last < 0.03 { return }
        lastPlay[s] = now
        let p = players[next]
        next = (next + 1) % players.count
        p.volume = min(1, vol)
        p.scheduleBuffer(buf, at: nil, options: [.interrupts], completionHandler: nil)
        if !p.isPlaying { p.play() }
    }

    func haptic(_ kind: Int) {
        guard Preferences.shared.haptics else { return }
        switch kind {
        case 0: impactLight.impactOccurred(intensity: 0.6)
        case 1: impactHeavy.impactOccurred()
        default: notify.notificationOccurred(.success)
        }
    }

    // MARK: - Synthesis

    private func synth(_ s: Sfx) -> AVAudioPCMBuffer {
        let sr: Float = 44_100
        func buffer(_ seconds: Float, _ gen: (Float, Float) -> Float) -> AVAudioPCMBuffer {
            let n = AVAudioFrameCount(seconds * sr)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
            b.frameLength = n
            let ch = b.floatChannelData![0]
            for i in 0..<Int(n) {
                let t = Float(i) / sr
                ch[i] = max(-1, min(1, gen(t, t / seconds)))
            }
            return b
        }
        var seed: UInt32 = 0x1234_5678
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        func env(_ x: Float, attack: Float = 0.01, decay: Float = 4) -> Float {
            x < attack ? x / attack : expf(-(x - attack) * decay)
        }
        let tau = Float.pi * 2
        switch s {
        case .pulse:
            // Deep thump with a rising chirp.
            return buffer(0.22) { t, x in
                let f = 90 + 380 * x
                return 0.7 * sinf(tau * f * t) * env(x, attack: 0.005, decay: 7) + 0.15 * noise() * env(x, attack: 0.001, decay: 30)
            }
        case .perfect:
            return buffer(0.45) { t, x in
                let e = env(x, attack: 0.005, decay: 5)
                return 0.35 * (sinf(tau * 880 * t) + 0.6 * sinf(tau * 1320 * t) + 0.3 * sinf(tau * 1760 * t)) * e
            }
        case .parry:
            return buffer(0.35) { t, x in
                let e = env(x, attack: 0.002, decay: 9)
                return 0.4 * (sinf(tau * 620 * t + 3 * sinf(tau * 1550 * t))) * e
            }
        case .clash:
            return buffer(0.4) { t, x in
                0.5 * noise() * env(x, attack: 0.002, decay: 10) + 0.3 * sinf(tau * 140 * t) * env(x, decay: 6)
            }
        case .dash:
            var lp: Float = 0
            return buffer(0.25) { _, x in
                let k = 0.05 + 0.4 * x
                lp += k * (noise() - lp)
                return 0.9 * lp * sinf(Float.pi * x)
            }
        case .shatter:
            return buffer(0.7) { t, x in
                let crystal = 0.25 * sinf(tau * (2400 - 1600 * x) * t) * env(x, attack: 0.001, decay: 6)
                return 0.55 * noise() * env(x, attack: 0.001, decay: 7) + crystal + 0.4 * sinf(tau * 70 * t) * env(x, decay: 9)
            }
        case .respawn:
            return buffer(0.4) { t, x in 0.3 * sinf(tau * (300 + 500 * x) * t) * sinf(Float.pi * x) }
        case .bounce:
            return buffer(0.07) { t, x in 0.4 * sinf(tau * 520 * t) * env(x, attack: 0.002, decay: 12) }
        case .portal:
            return buffer(0.5) { t, x in
                0.3 * sinf(tau * (200 + 900 * x * x) * t) * sinf(Float.pi * x) + 0.08 * noise() * sinf(Float.pi * x)
            }
        case .goal:
            // Major chord swell with a bright attack.
            return buffer(1.4) { t, x in
                let e = env(x, attack: 0.02, decay: 2.2)
                let chord = sinf(tau * 392 * t) + 0.8 * sinf(tau * 494 * t) + 0.7 * sinf(tau * 587 * t) + 0.4 * sinf(tau * 784 * t)
                return 0.22 * chord * e + 0.2 * noise() * env(x, attack: 0.001, decay: 25)
            }
        case .countdown:
            return buffer(0.16) { t, x in 0.35 * sinf(tau * 660 * t) * env(x, attack: 0.004, decay: 8) }
        case .go:
            return buffer(0.45) { t, x in 0.35 * (sinf(tau * 990 * t) + 0.5 * sinf(tau * 1485 * t)) * env(x, attack: 0.004, decay: 4) }
        case .roundOver:
            return buffer(1.1) { t, x in
                let f: Float = x < 0.33 ? 523 : (x < 0.66 ? 659 : 784)
                return 0.3 * sinf(tau * f * t) * env(x, attack: 0.01, decay: 1.5)
            }
        case .uiTap:
            return buffer(0.05) { t, x in 0.25 * sinf(tau * 1200 * t) * env(x, attack: 0.002, decay: 14) }
        case .uiConfirm:
            return buffer(0.18) { t, x in 0.3 * sinf(tau * (700 + 500 * x) * t) * env(x, attack: 0.003, decay: 5) }
        }
    }
}
