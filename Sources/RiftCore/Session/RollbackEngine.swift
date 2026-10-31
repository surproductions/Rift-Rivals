// RIFT RIVALS — rollback engine.
//
// Holds the authoritative-input timeline and the predicted present:
//
//   * Confirmed inputs (decided by the host, identical on every device) are
//     keyed by tick. A tick's input is applied exactly once per simulation of
//     that tick, so duplicated or late packets can never repeat an action.
//   * Missing remote inputs are predicted (continue moving, no new presses).
//   * When a confirmed input differs from what was used, the engine restores
//     the snapshot of that tick and re-simulates up to the present.
//   * Once every input before tick T is confirmed, the state at T is final;
//     its checksum is published for cross-device verification.

public struct EngineStats: Sendable {
    public var rollbacks: Int = 0
    public var rolledBackTicks: Int = 0
    public var maxRollbackDepth: Int = 0
    public var stalls: Int = 0
    public var predictedTicks: Int = 0
    public var snapshotsApplied: Int = 0
    public var simulatedTicks: Int = 0
    public var lastStepMicros: Double = 0
}

public final class RollbackEngine {
    public let ctx: SimContext
    public let playerCount: Int
    public let historySize: Int
    public var maxPrediction: Int32
    public let hashInterval: Int32 = 30

    public private(set) var state: GameState
    public var currentTick: Int32 { state.tick }
    public private(set) var stats = EngineStats()

    /// Player controlled on this device (nil = spectator / headless host).
    public var localPlayer: Int?

    // Rings indexed by tick % historySize.
    private var snapshots: [[UInt8]]
    private var snapshotTick: [Int32]
    private var confirmedInputs: [[PlayerInput]]
    private var confirmedTag: [[Int32]]
    private var usedInputs: [[PlayerInput]]
    private var usedTag: [[Int32]]
    private var localInputs: [PlayerInput]
    private var localTag: [Int32]

    public private(set) var confirmedThrough: [Int32]
    private let alwaysConfirmed: [Bool]   // bots
    private var rollbackFrom: Int32?

    private var writer = ByteWriter(capacity: 1024)
    private var scratchInputs: [PlayerInput]
    public private(set) var events: [GameEvent] = []

    /// Verified checksums of final states, keyed by tick.
    public private(set) var verifiedHashes: [(tick: Int32, hash: UInt64)] = []
    private var nextHashTick: Int32

    /// Observer for every confirmed input (tests record the host's timeline).
    public var confirmObserver: ((Int, Int32, PlayerInput) -> Void)?

    /// Clock used for performance diagnostics only (never for gameplay).
    public var perfClock: (() -> Double)?

    public init(setup: MatchSetup, historySize: Int = 256, maxPrediction: Int32 = 30) {
        ctx = SimContext(setup: setup)
        playerCount = setup.playerCount
        self.historySize = historySize
        self.maxPrediction = maxPrediction
        state = Simulation.initialState(ctx)
        snapshots = Array(repeating: { var a = [UInt8](); a.reserveCapacity(1024); return a }(), count: historySize)
        snapshotTick = Array(repeating: -1, count: historySize)
        confirmedInputs = Array(repeating: Array(repeating: .neutral, count: historySize), count: playerCount)
        confirmedTag = Array(repeating: Array(repeating: -1, count: historySize), count: playerCount)
        usedInputs = confirmedInputs
        usedTag = confirmedTag
        localInputs = Array(repeating: .neutral, count: historySize)
        localTag = Array(repeating: -1, count: historySize)
        confirmedThrough = Array(repeating: -1, count: playerCount)
        alwaysConfirmed = setup.slots.map { $0.isBot }
        scratchInputs = Array(repeating: .neutral, count: playerCount)
        nextHashTick = hashInterval
        events.reserveCapacity(64)
    }

    @inline(__always) private func slot(_ tick: Int32) -> Int { Int(tick) & (historySize - 1) }

    // MARK: - Inputs

    /// Lowest tick for which every human player's input is confirmed.
    public var confirmedTick: Int32 {
        var m = Int32.max
        for p in 0..<playerCount where !alwaysConfirmed[p] { m = min(m, confirmedThrough[p]) }
        return m == .max ? currentTick - 1 + maxPrediction : m
    }

    public func isBot(_ p: Int) -> Bool { alwaysConfirmed[p] }

    public func confirmedInput(player p: Int, tick: Int32) -> PlayerInput? {
        let s = slot(tick)
        return confirmedTag[p][s] == tick ? confirmedInputs[p][s] : nil
    }

    public func localInput(tick: Int32) -> PlayerInput? {
        let s = slot(tick)
        return localTag[s] == tick ? localInputs[s] : nil
    }

    /// Record this device's own (not yet confirmed) input for a future tick.
    public func setLocalInput(tick: Int32, _ input: PlayerInput) {
        let s = slot(tick)
        localInputs[s] = input
        localTag[s] = tick
    }

    /// Apply a host-confirmed input. Must be called in tick order per player
    /// (tick == confirmedThrough + 1). Returns false for duplicates / gaps.
    @discardableResult
    public func confirm(player p: Int, tick: Int32, _ input: PlayerInput) -> Bool {
        guard p >= 0 && p < playerCount, !alwaysConfirmed[p] else { return false }
        guard tick == confirmedThrough[p] + 1 else { return false }
        guard tick > currentTick - Int32(historySize) + 2 else { return false }
        let s = slot(tick)
        confirmedInputs[p][s] = input
        confirmedTag[p][s] = tick
        confirmedThrough[p] = tick
        confirmObserver?(p, tick, input)
        // Did we simulate this tick (or later ticks predicted from older data) with something else?
        if tick < currentTick {
            let usedMatches = usedTag[p][s] == tick && usedInputs[p][s] == input
            if !usedMatches { markRollback(from: tick) }
            else {
                // Later ticks were predicted from an older confirmed input; if the
                // continuation changed, those predictions are stale.
                let next = tick + 1
                if next < currentTick {
                    let ns = slot(next)
                    if usedTag[p][ns] == next && confirmedTag[p][ns] != next && usedInputs[p][ns] != predict(player: p, tick: next) {
                        markRollback(from: next)
                    }
                }
            }
        }
        return true
    }

    /// Force-confirm a tick range start (used after a snapshot or migration).
    public func resetConfirmed(player p: Int, through tick: Int32) {
        guard p >= 0 && p < playerCount, !alwaysConfirmed[p] else { return }
        confirmedThrough[p] = tick
    }

    private func markRollback(from tick: Int32) {
        if let r = rollbackFrom { rollbackFrom = min(r, tick) } else { rollbackFrom = tick }
    }

    private func predict(player p: Int, tick: Int32) -> PlayerInput {
        let ct = confirmedThrough[p]
        if ct >= 0, let last = confirmedInput(player: p, tick: min(ct, tick - 1)) { return last.predictedContinuation }
        return .neutral
    }

    private func input(player p: Int, tick: Int32) -> PlayerInput {
        if alwaysConfirmed[p] { return .neutral }
        if let c = confirmedInput(player: p, tick: tick) { return c }
        if p == localPlayer, let l = localInput(tick: tick) { return l }
        return predict(player: p, tick: tick)
    }

    // MARK: - Stepping

    public var predictionDepth: Int32 { max(0, currentTick - (confirmedTick + 1)) }
    public var canAdvance: Bool { currentTick - confirmedTick <= maxPrediction }

    private func saveSnapshot(_ tick: Int32) {
        let s = slot(tick)
        swap(&writer.bytes, &snapshots[s])
        writer.reset()
        StateCodec.write(state, into: &writer)
        swap(&writer.bytes, &snapshots[s])
        snapshotTick[s] = tick
    }

    private func simulateOne() {
        let tick = currentTick
        saveSnapshot(tick)
        let s = slot(tick)
        var predicted = false
        for p in 0..<playerCount {
            let i = input(player: p, tick: tick)
            scratchInputs[p] = i
            usedInputs[p][s] = i
            usedTag[p][s] = tick
            if !alwaysConfirmed[p] && confirmedTag[p][s] != tick { predicted = true }
        }
        if predicted { stats.predictedTicks += 1 }
        Simulation.step(&state, inputs: scratchInputs, ctx: ctx, events: &events)
        stats.simulatedTicks += 1
    }

    /// Resolve any pending rollback by restoring and re-simulating.
    public func resolveRollback() {
        guard let from = rollbackFrom else { return }
        rollbackFrom = nil
        let target = currentTick
        guard from < target else { return }
        let s = slot(from)
        guard snapshotTick[s] == from else { return } // too old; a snapshot correction will follow
        var r = ByteReader(snapshots[s])
        do { try StateCodec.read(&r, into: &state) } catch { return }
        let depth = Int(target - from)
        stats.rollbacks += 1
        stats.rolledBackTicks += depth
        stats.maxRollbackDepth = max(stats.maxRollbackDepth, depth)
        while currentTick < target { simulateOne() }
        computeHashes()
    }

    /// Advance one tick if prediction limits allow. Returns false on stall.
    @discardableResult
    public func advance() -> Bool {
        resolveRollback()
        guard canAdvance else { stats.stalls += 1; return false }
        let t0 = perfClock?()
        simulateOne()
        if let t0 = t0, let now = perfClock?() { stats.lastStepMicros = (now - t0) * 1_000_000 }
        computeHashes()
        return true
    }

    /// Take queued presentation events (de-duplicate by tick on the consumer side).
    public func drainEvents(into out: inout [GameEvent]) {
        out.append(contentsOf: events)
        events.removeAll(keepingCapacity: true)
    }

    // MARK: - Verification

    private func computeHashes() {
        guard rollbackFrom == nil else { return }
        let ct = confirmedTick
        while nextHashTick <= ct + 1 && nextHashTick < currentTick {
            let s = slot(nextHashTick)
            if snapshotTick[s] == nextHashTick {
                let h = FNV1a.hash(snapshots[s])
                verifiedHashes.append((nextHashTick, h))
                if verifiedHashes.count > 64 { verifiedHashes.removeFirst(verifiedHashes.count - 64) }
            }
            nextHashTick += hashInterval
        }
    }

    public func verifiedHash(at tick: Int32) -> UInt64? {
        verifiedHashes.last { $0.tick == tick }?.hash
    }

    public var latestVerified: (tick: Int32, hash: UInt64)? { verifiedHashes.last }

    /// Serialized final state at a verified tick (for corrective snapshots).
    public func snapshotBytes(at tick: Int32) -> [UInt8]? {
        let s = slot(tick)
        return snapshotTick[s] == tick ? snapshots[s] : nil
    }

    /// Replace history with an authoritative snapshot at `tick` and re-simulate
    /// to the present (or jump forward if we are behind).
    /// - Parameter rewind: drop predicted ticks beyond the snapshot (rejoin / migration),
    ///   instead of re-simulating back up to the present.
    public func applyAuthoritativeSnapshot(tick: Int32, bytes: [UInt8], rewind: Bool = false) throws {
        var newState = GameState()
        var r = ByteReader(bytes)
        try StateCodec.read(&r, into: &newState)
        guard newState.tick == tick, newState.players.count == playerCount else { throw ByteReaderError.invalid }
        stats.snapshotsApplied += 1
        let target = rewind ? tick : max(currentTick, tick)
        state = newState
        rollbackFrom = nil
        // Hashes at or after the snapshot tick are recomputed.
        verifiedHashes.removeAll { $0.tick >= tick }
        nextHashTick = ((tick + hashInterval - 1) / hashInterval) * hashInterval
        if nextHashTick < hashInterval { nextHashTick = hashInterval }
        // Inputs before the snapshot tick are no longer needed.
        for p in 0..<playerCount where !alwaysConfirmed[p] && confirmedThrough[p] < tick - 1 {
            confirmedThrough[p] = tick - 1
        }
        while currentTick < target && canAdvance { simulateOne() }
        computeHashes()
    }

    /// Discard predicted ticks and move the present back to `tick`
    /// (host migration: the new host restarts from its last final state).
    public func rewind(to tick: Int32) {
        guard tick < currentTick else { return }
        let s = slot(tick)
        guard snapshotTick[s] == tick else { return }
        var r = ByteReader(snapshots[s])
        try? StateCodec.read(&r, into: &state)
        rollbackFrom = nil
        verifiedHashes.removeAll { $0.tick > tick }
        nextHashTick = ((tick + hashInterval) / hashInterval) * hashInterval
    }

    /// Deliberately corrupt the state — used only by desync-recovery tests.
    public func debugCorruptState() {
        if !state.players.isEmpty { state.players[0].pos.x.raw += 12345 }
    }
}
