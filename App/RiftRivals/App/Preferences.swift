import Foundation
import Combine

/// Persistent player preferences (no account, stored on device only).
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    @Published var playerName: String { didSet { d.set(playerName, forKey: "playerName") } }
    @Published var soundVolume: Double { didSet { d.set(soundVolume, forKey: "soundVolume") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    @Published var screenShake: Bool { didSet { d.set(screenShake, forKey: "screenShake") } }
    @Published var colorblindPalette: Bool { didSet { d.set(colorblindPalette, forKey: "colorblind") } }
    @Published var leftHanded: Bool { didSet { d.set(leftHanded, forKey: "leftHanded") } }
    @Published var showDiagnostics: Bool { didSet { d.set(showDiagnostics, forKey: "diagnostics") } }
    @Published var reduceMotion: Bool { didSet { d.set(reduceMotion, forKey: "reduceMotion") } }
    @Published var largeHUD: Bool { didSet { d.set(largeHUD, forKey: "largeHUD") } }
    @Published var fixedJoystick: Bool { didSet { d.set(fixedJoystick, forKey: "fixedJoystick") } }
    @Published var hasSeenTutorial: Bool { didSet { d.set(hasSeenTutorial, forKey: "seenTutorial") } }
    @Published var lastSettings: Data? { didSet { d.set(lastSettings, forKey: "lastSettings") } }

    /// Random identity used only to recognise this device when it reconnects.
    let deviceToken: UInt64

    private init() {
        let d = UserDefaults.standard
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        playerName = d.string(forKey: "playerName") ?? Preferences.randomName()
        soundVolume = d.object(forKey: "soundVolume") == nil ? 0.8 : d.double(forKey: "soundVolume")
        haptics = bool("haptics", true)
        screenShake = bool("screenShake", true)
        colorblindPalette = bool("colorblind", false)
        leftHanded = bool("leftHanded", false)
        showDiagnostics = bool("diagnostics", false)
        reduceMotion = bool("reduceMotion", false)
        largeHUD = bool("largeHUD", false)
        fixedJoystick = bool("fixedJoystick", false)
        hasSeenTutorial = bool("seenTutorial", false)
        lastSettings = d.data(forKey: "lastSettings")
        if let s = d.string(forKey: "deviceToken"), let v = UInt64(s) {
            deviceToken = v
        } else {
            let v = UInt64.random(in: 1...UInt64.max)
            d.set(String(v), forKey: "deviceToken")
            deviceToken = v
        }
    }

    static func randomName() -> String {
        let a = ["Nova", "Echo", "Vex", "Orbit", "Quill", "Rook", "Sable", "Jinx", "Kite", "Lumen", "Mako", "Pyre"]
        return a.randomElement()! + String(Int.random(in: 10...99))
    }
}
