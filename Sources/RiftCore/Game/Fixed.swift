// RIFT RIVALS — deterministic fixed-point math.
//
// The simulation never touches floating point. Every value that influences
// gameplay is a Q16.16 fixed-point number stored in an Int64, so the same
// inputs produce bit-identical results on every device, CPU and compiler.

/// Q16.16 fixed-point scalar. `raw` holds the value multiplied by 65536.
public struct Fx: Equatable, Comparable, Hashable, Sendable {
    public var raw: Int64

    public static let fractionBits: Int64 = 16
    public static let one = Fx(raw: 1 << 16)
    public static let zero = Fx(raw: 0)
    public static let half = Fx(raw: 1 << 15)

    @inlinable public init(raw: Int64) { self.raw = raw }
    @inlinable public init(_ int: Int) { self.raw = Int64(int) << 16 }

    /// Build a constant from a rational number (numerator / denominator).
    /// Integer-only, so it is deterministic.
    @inlinable public static func ratio(_ num: Int, _ den: Int) -> Fx {
        Fx(raw: (Int64(num) << 16) / Int64(den))
    }

    /// Lossy conversion for rendering only. Never feed this back into the sim.
    @inlinable public var double: Double { Double(raw) / 65536.0 }
    @inlinable public var intValue: Int { Int(raw >> 16) }

    @inlinable public static func + (a: Fx, b: Fx) -> Fx { Fx(raw: a.raw + b.raw) }
    @inlinable public static func - (a: Fx, b: Fx) -> Fx { Fx(raw: a.raw - b.raw) }
    @inlinable public static prefix func - (a: Fx) -> Fx { Fx(raw: -a.raw) }
    @inlinable public static func * (a: Fx, b: Fx) -> Fx { Fx(raw: (a.raw * b.raw) >> 16) }
    @inlinable public static func / (a: Fx, b: Fx) -> Fx {
        if b.raw == 0 { return .zero }
        return Fx(raw: (a.raw << 16) / b.raw)
    }
    @inlinable public static func * (a: Fx, b: Int) -> Fx { Fx(raw: a.raw * Int64(b)) }
    @inlinable public static func / (a: Fx, b: Int) -> Fx { Fx(raw: a.raw / Int64(b)) }
    @inlinable public static func += (a: inout Fx, b: Fx) { a.raw += b.raw }
    @inlinable public static func -= (a: inout Fx, b: Fx) { a.raw -= b.raw }
    @inlinable public static func < (a: Fx, b: Fx) -> Bool { a.raw < b.raw }

    @inlinable public var abs: Fx { Fx(raw: raw < 0 ? -raw : raw) }

    @inlinable public static func min(_ a: Fx, _ b: Fx) -> Fx { a.raw < b.raw ? a : b }
    @inlinable public static func max(_ a: Fx, _ b: Fx) -> Fx { a.raw > b.raw ? a : b }
    @inlinable public func clamped(_ lo: Fx, _ hi: Fx) -> Fx { Fx.max(lo, Fx.min(hi, self)) }
}

/// Deterministic integer square root (floor), Newton iteration on UInt64.
@inlinable public func isqrt(_ value: Int64) -> Int64 {
    if value <= 0 { return 0 }
    let v = UInt64(value)
    var bits: UInt64 = 0
    var tmp = v
    while tmp > 0 { bits += 1; tmp >>= 1 }
    // Initial guess is >= sqrt(v); Newton's method then decreases monotonically.
    var x: UInt64 = 1 << ((bits + 1) / 2)
    while true {
        let y = (x + v / x) >> 1
        if y >= x { break }
        x = y
    }
    return Int64(x)
}

/// Fixed-point 2D vector.
public struct FxVec: Equatable, Hashable, Sendable {
    public var x: Fx
    public var y: Fx

    public static let zero = FxVec(x: .zero, y: .zero)

    @inlinable public init(x: Fx, y: Fx) { self.x = x; self.y = y }
    @inlinable public init(_ x: Int, _ y: Int) { self.x = Fx(x); self.y = Fx(y) }

    @inlinable public static func + (a: FxVec, b: FxVec) -> FxVec { FxVec(x: a.x + b.x, y: a.y + b.y) }
    @inlinable public static func - (a: FxVec, b: FxVec) -> FxVec { FxVec(x: a.x - b.x, y: a.y - b.y) }
    @inlinable public static prefix func - (a: FxVec) -> FxVec { FxVec(x: -a.x, y: -a.y) }
    @inlinable public static func * (a: FxVec, s: Fx) -> FxVec { FxVec(x: a.x * s, y: a.y * s) }
    @inlinable public static func / (a: FxVec, s: Int) -> FxVec { FxVec(x: a.x / s, y: a.y / s) }
    @inlinable public static func += (a: inout FxVec, b: FxVec) { a.x += b.x; a.y += b.y }
    @inlinable public static func -= (a: inout FxVec, b: FxVec) { a.x -= b.x; a.y -= b.y }

    @inlinable public func dot(_ o: FxVec) -> Fx { x * o.x + y * o.y }

    /// Squared length in raw Q32.32 units — no precision loss, used for comparisons.
    @inlinable public var lengthSquaredRaw: Int64 { x.raw * x.raw + y.raw * y.raw }
    @inlinable public var length: Fx { Fx(raw: isqrt(lengthSquaredRaw)) }

    /// Returns a unit vector, or zero for a zero vector.
    @inlinable public var normalized: FxVec {
        let len = length
        if len.raw == 0 { return .zero }
        return FxVec(x: Fx(raw: (x.raw << 16) / len.raw), y: Fx(raw: (y.raw << 16) / len.raw))
    }

    /// Clamp the vector's length to `maxLen`.
    @inlinable public func limited(_ maxLen: Fx) -> FxVec {
        let len = length
        if len.raw <= maxLen.raw || len.raw == 0 { return self }
        return FxVec(x: Fx(raw: (x.raw * maxLen.raw) / len.raw), y: Fx(raw: (y.raw * maxLen.raw) / len.raw))
    }

    @inlinable public func lerp(to target: FxVec, t: Fx) -> FxVec { self + (target - self) * t }

    /// Perpendicular (rotated +90°).
    @inlinable public var perp: FxVec { FxVec(x: -y, y: x) }

    @inlinable public static func withinRadius(_ a: FxVec, _ b: FxVec, _ r: Fx) -> Bool {
        (a - b).lengthSquaredRaw <= r.raw * r.raw
    }
}

/// PCG32 — small, fast, fully deterministic random number generator.
/// Its state is part of `GameState` so rollback restores it exactly.
public struct DeterministicRNG: Equatable, Sendable {
    public var state: UInt64
    public var inc: UInt64

    public init(seed: UInt64, stream: UInt64 = 0x5851_F42D_4C95_7F2D) {
        state = 0
        inc = (stream << 1) | 1
        _ = next()
        state = state &+ seed
        _ = next()
    }

    public init(state: UInt64, inc: UInt64) { self.state = state; self.inc = inc }

    public mutating func next() -> UInt32 {
        let old = state
        state = old &* 6364136223846793005 &+ inc
        let xorshifted = UInt32(truncatingIfNeeded: ((old >> 18) ^ old) >> 27)
        let rot = UInt32(truncatingIfNeeded: old >> 59)
        return (xorshifted >> rot) | (xorshifted << ((~rot &+ 1) & 31))
    }

    /// Uniform integer in 0..<bound (bound > 0). Uses rejection sampling.
    public mutating func next(below bound: UInt32) -> UInt32 {
        precondition(bound > 0)
        let threshold = (0 &- bound) % bound
        while true {
            let r = next()
            if r >= threshold { return r % bound }
        }
    }

    /// Uniform integer in lo...hi.
    public mutating func range(_ lo: Int, _ hi: Int) -> Int {
        lo + Int(next(below: UInt32(hi - lo + 1)))
    }
}

/// FNV-1a 64-bit hash for deterministic state checksums.
public struct FNV1a: Sendable {
    public var value: UInt64 = 0xcbf2_9ce4_8422_2325
    public init() {}
    @inlinable public mutating func add(_ byte: UInt8) {
        value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
    }
    public mutating func add<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for b in bytes { add(b) }
    }
    public static func hash(_ bytes: [UInt8]) -> UInt64 {
        var h = FNV1a()
        h.add(bytes)
        return h.value
    }
}
