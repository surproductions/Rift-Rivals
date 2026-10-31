// RIFT RIVALS — shared session helpers: fixed-step clock, diagnostics,
// local input sources, room codes.

/// Converts variable display frame times into a whole number of fixed 60 Hz
/// simulation ticks. Rendering at 60, 90 or 120 FPS therefore executes the
/// exact same simulation; only the interpolation alpha differs.
public struct FixedStepClock: Sendable {
    public static let dt = 1.0 / Double(Tuning.tickRate)
    public private(set) var accumulator: Double = 0
    private var last: Double?

    public init() {}

    public mutating func reset(now: Double) {
        last = now
        accumulator = 0
    }

    /// Returns the number of ticks due. `rate` lets time sync gently speed up
    /// or slow down a client (e.g. 0.97…1.03).
    public mutating func ticksDue(now: Double, rate: Double = 1, maxSteps: Int = 6) -> Int {
        guard let l = last else { last = now; return 0 }
        var delta = now - l
        last = now
        if delta < 0 { delta = 0 }
        if delta > 0.25 { delta = 0.25 } // hitch / background: never spiral
        accumulator += delta * rate
        var n = 0
        while accumulator >= FixedStepClock.dt && n < maxSteps {
            accumulator -= FixedStepClock.dt
            n += 1
        }
        if n == maxSteps && accumulator > FixedStepClock.dt { accumulator = FixedStepClock.dt }
        return n
    }

    /// Give back a tick that could not be simulated (stall) without letting debt pile up.
    public mutating func refund(_ ticks: Int) {
        accumulator = min(accumulator + Double(ticks) * FixedStepClock.dt, FixedStepClock.dt * 2)
    }

    public var alpha: Double { min(1, max(0, accumulator / FixedStepClock.dt)) }
    public var fraction: Double { accumulator / FixedStepClock.dt }
}

/// Supplies this device's input once per simulated tick.
public protocol LocalInputSource: AnyObject {
    func sampleInput(forTick tick: Int32) -> PlayerInput
}

/// Fixed input (tests / idle).
public final class ConstantInputSource: LocalInputSource {
    public var input: PlayerInput
    public init(_ input: PlayerInput = .neutral) { self.input = input }
    public func sampleInput(forTick tick: Int32) -> PlayerInput { input }
}

public struct DesyncRecord: Sendable, Equatable {
    public var memberID: UInt8
    public var lastMatchingTick: Int32
    public var firstMismatchTick: Int32
    public var localHash: UInt64
    public var remoteHash: UInt64
}

/// Everything shown by the optional network diagnostics overlay.
public struct NetDiagnostics: Sendable {
    public var isHost = false
    public var hostName = ""
    public var epoch: UInt16 = 0
    public var tick: Int32 = 0
    public var confirmedTick: Int32 = 0
    public var hostTickEstimate: Double = 0
    public var rttMs = 0
    public var jitterMs = 0
    public var lossPercent: Double = 0
    public var inputDelay = 0
    public var predictionDepth = 0
    public var rollbacks = 0
    public var rolledBackTicks = 0
    public var maxRollbackDepth = 0
    public var stalls = 0
    public var lastHashTick: Int32 = -1
    public var lastHash: UInt64 = 0
    public var hashChecks = 0
    public var hashMismatches = 0
    public var snapshotsApplied = 0
    public var stepMicros: Double = 0
    public var lateInputs = 0
    public var suspiciousInputs = 0
    public var duplicatePackets = 0
    public var quality: ConnectionQuality = .excellent
    public var desyncLog: [DesyncRecord] = []

    public init() {}

    public var lines: [String] {
        [
            "TICK \(tick)  CONF \(confirmedTick)  EPOCH \(epoch)",
            "HOST \(hostName)\(isHost ? " (you)" : "")",
            "RTT \(rttMs)ms  JIT \(jitterMs)ms  LOSS \(String(format1: lossPercent))%",
            "DELAY \(inputDelay)t  PRED \(predictionDepth)t  STALL \(stalls)",
            "ROLLBACK \(rollbacks) (\(rolledBackTicks)t, max \(maxRollbackDepth))",
            "HASH @\(lastHashTick) \(String(lastHash, radix: 16).suffix(8))  ok \(hashChecks) bad \(hashMismatches)",
            "SNAP \(snapshotsApplied)  LATE \(lateInputs)  SUS \(suspiciousInputs)  DUP \(duplicatePackets)",
            "SIM \(String(format1: stepMicros))µs/tick  NET \(quality.label)",
        ]
    }
}

extension String {
    public init(format1 v: Double) {
        let scaled = Int((v * 10).rounded())
        self = "\(scaled / 10).\(abs(scaled % 10))"
    }
}

public enum RoomCode {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    public static func make(rng: inout DeterministicRNG) -> String {
        String((0..<4).map { _ in alphabet[Int(rng.next(below: UInt32(alphabet.count)))] })
    }

    public static func sessionID(for code: String) -> UInt32 {
        var h = FNV1a()
        h.add(Array(code.uppercased().utf8))
        return UInt32(truncatingIfNeeded: h.value ^ (h.value >> 32))
    }

    public static func normalize(_ s: String) -> String {
        String(s.uppercased().filter { alphabet.contains($0) }.prefix(4))
    }
}

public enum NameRules {
    public static func sanitize(_ s: String) -> String {
        let trimmed = s.trimmingCharactersInSet()
        let cut = String(trimmed.prefix(14))
        return cut.isEmpty ? "Runner" : cut
    }
}

extension String {
    func trimmingCharactersInSet() -> String {
        var scalars = Substring(self)
        while let f = scalars.first, f.isWhitespace || f.isNewline { scalars.removeFirst() }
        while let l = scalars.last, l.isWhitespace || l.isNewline { scalars.removeLast() }
        return String(scalars.filter { !$0.isNewline })
    }
}
