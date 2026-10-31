// RIFT RIVALS — compact little-endian binary serialization.

public struct ByteWriter {
    public var bytes: [UInt8]

    public init(capacity: Int = 256) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    /// Reset while keeping the allocation (used every tick for snapshots).
    public mutating func reset() { bytes.removeAll(keepingCapacity: true) }

    @inlinable public mutating func u8(_ v: UInt8) { bytes.append(v) }
    @inlinable public mutating func i8(_ v: Int8) { bytes.append(UInt8(bitPattern: v)) }
    @inlinable public mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }
    @inlinable public mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    @inlinable public mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    @inlinable public mutating func u32(_ v: UInt32) {
        for s in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(s))) }
    }
    @inlinable public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    @inlinable public mutating func u64(_ v: UInt64) {
        for s in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(s))) }
    }
    @inlinable public mutating func i64(_ v: Int64) { u64(UInt64(bitPattern: v)) }
    /// Fixed-point values are bounded to the arena, so 32 bits are plenty.
    @inlinable public mutating func fx(_ v: Fx) { i32(Int32(clamping: v.raw)) }
    @inlinable public mutating func vec(_ v: FxVec) { fx(v.x); fx(v.y) }
    public mutating func string(_ s: String, maxBytes: Int = 32) {
        var utf8 = Array(s.utf8.prefix(maxBytes))
        // Never cut a multi-byte scalar in half.
        while !utf8.isEmpty, String(decoding: utf8, as: UTF8.self).utf8.count != utf8.count { utf8.removeLast() }
        u8(UInt8(utf8.count))
        bytes.append(contentsOf: utf8)
    }
    public mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    public mutating func blob(_ b: [UInt8]) { u16(UInt16(b.count)); bytes.append(contentsOf: b) }
}

public enum ByteReaderError: Error { case underflow, invalid }

public struct ByteReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public var remaining: Int { bytes.count - offset }

    @inline(__always) mutating func need(_ n: Int) throws {
        if offset + n > bytes.count { throw ByteReaderError.underflow }
    }

    public mutating func u8() throws -> UInt8 { try need(1); defer { offset += 1 }; return bytes[offset] }
    public mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }
    public mutating func bool() throws -> Bool { try u8() != 0 }
    public mutating func u16() throws -> UInt16 {
        try need(2)
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
    public mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    public mutating func u32() throws -> UInt32 {
        try need(4)
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(bytes[offset + k]) << UInt32(8 * k) }
        offset += 4
        return v
    }
    public mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    public mutating func u64() throws -> UInt64 {
        try need(8)
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(bytes[offset + k]) << UInt64(8 * k) }
        offset += 8
        return v
    }
    public mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    public mutating func fx() throws -> Fx { Fx(raw: Int64(try i32())) }
    public mutating func vec() throws -> FxVec { FxVec(x: try fx(), y: try fx()) }
    public mutating func string() throws -> String {
        let n = Int(try u8())
        try need(n)
        defer { offset += n }
        return String(decoding: bytes[offset..<offset + n], as: UTF8.self)
    }
    public mutating func blob() throws -> [UInt8] {
        let n = Int(try u16())
        try need(n)
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }
    public mutating func rest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[offset...])
    }
}

// MARK: - State serialization (snapshots, hashing, migration)

public enum StateCodec {
    public static let version: UInt8 = 1

    public static func write(_ s: GameState, into w: inout ByteWriter) {
        w.u8(version)
        w.i32(s.tick)
        w.u8(s.phase.rawValue)
        w.i32(s.phaseTimer)
        w.u8(s.scores.0); w.u8(s.scores.1)
        w.u8(s.roundWins.0); w.u8(s.roundWins.1)
        w.u8(s.round)
        w.i32(s.timeRemaining)
        w.bool(s.overtime)
        w.i8(s.lastGoalTeam); w.i8(s.lastGoalScorer); w.i8(s.lastRoundWinner); w.i8(s.matchWinner)
        w.u64(s.rng.state); w.u64(s.rng.inc)
        w.u8(UInt8(s.players.count))
        for p in s.players {
            w.vec(p.pos); w.vec(p.vel); w.vec(p.facing)
            w.u8(p.team); w.bool(p.isBot)
            w.i16(p.pulseCooldown); w.i16(p.dashCooldown); w.i16(p.dashTicks); w.i16(p.staggerTicks)
            w.i16(p.shatteredTicks); w.i16(p.shieldTicks)
            w.i8(p.bufferedPulse); w.i8(p.bufferedDash); w.u8(p.prevButtons)
            w.i16(p.portalCooldown); w.i32(p.lastPulseTick)
            w.vec(p.botTarget); w.i16(p.botThinkTimer); w.bool(p.botWantsPulse)
            w.u16(p.goals); w.u16(p.assists); w.u16(p.shatters); w.u16(p.timesShattered)
            w.u16(p.pulses); w.u16(p.parries)
        }
        w.u8(UInt8(s.shards.count))
        for sh in s.shards {
            w.vec(sh.pos); w.vec(sh.vel)
            w.i8(sh.owner); w.u8(sh.heat); w.i16(sh.heatTimer)
            w.i8(sh.lastToucher); w.i8(sh.prevToucher); w.i16(sh.portalCooldown); w.bool(sh.active)
        }
    }

    public static func encode(_ s: GameState) -> [UInt8] {
        var w = ByteWriter(capacity: 1024)
        write(s, into: &w)
        return w.bytes
    }

    /// Decode into an existing state, reusing its arrays (allocation-free when sizes match).
    public static func read(_ r: inout ByteReader, into s: inout GameState) throws {
        guard try r.u8() == version else { throw ByteReaderError.invalid }
        s.tick = try r.i32()
        guard let phase = MatchPhase(rawValue: try r.u8()) else { throw ByteReaderError.invalid }
        s.phase = phase
        s.phaseTimer = try r.i32()
        s.scores = (try r.u8(), try r.u8())
        s.roundWins = (try r.u8(), try r.u8())
        s.round = try r.u8()
        s.timeRemaining = try r.i32()
        s.overtime = try r.bool()
        s.lastGoalTeam = try r.i8(); s.lastGoalScorer = try r.i8(); s.lastRoundWinner = try r.i8(); s.matchWinner = try r.i8()
        s.rng = DeterministicRNG(state: try r.u64(), inc: try r.u64())
        let pc = Int(try r.u8())
        guard pc <= 8 else { throw ByteReaderError.invalid }
        if s.players.count != pc { s.players = Array(repeating: PlayerState(), count: pc) }
        for i in 0..<pc {
            var p = PlayerState()
            p.pos = try r.vec(); p.vel = try r.vec(); p.facing = try r.vec()
            p.team = try r.u8(); p.isBot = try r.bool()
            p.pulseCooldown = try r.i16(); p.dashCooldown = try r.i16(); p.dashTicks = try r.i16(); p.staggerTicks = try r.i16()
            p.shatteredTicks = try r.i16(); p.shieldTicks = try r.i16()
            p.bufferedPulse = try r.i8(); p.bufferedDash = try r.i8(); p.prevButtons = try r.u8()
            p.portalCooldown = try r.i16(); p.lastPulseTick = try r.i32()
            p.botTarget = try r.vec(); p.botThinkTimer = try r.i16(); p.botWantsPulse = try r.bool()
            p.goals = try r.u16(); p.assists = try r.u16(); p.shatters = try r.u16(); p.timesShattered = try r.u16()
            p.pulses = try r.u16(); p.parries = try r.u16()
            s.players[i] = p
        }
        let sc = Int(try r.u8())
        guard sc <= 4 else { throw ByteReaderError.invalid }
        if s.shards.count != sc { s.shards = Array(repeating: ShardState(), count: sc) }
        for i in 0..<sc {
            var sh = ShardState()
            sh.pos = try r.vec(); sh.vel = try r.vec()
            sh.owner = try r.i8(); sh.heat = try r.u8(); sh.heatTimer = try r.i16()
            sh.lastToucher = try r.i8(); sh.prevToucher = try r.i8(); sh.portalCooldown = try r.i16(); sh.active = try r.bool()
            s.shards[i] = sh
        }
    }

    public static func decode(_ bytes: [UInt8]) throws -> GameState {
        var s = GameState()
        var r = ByteReader(bytes)
        try read(&r, into: &s)
        return s
    }

    public static func hash(_ s: GameState) -> UInt64 { FNV1a.hash(encode(s)) }
}
