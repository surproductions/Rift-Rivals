// RIFT RIVALS — deterministic in-memory network for automated tests.
//
// Models one-way latency, jitter, random loss, duplication and reordering,
// plus nodes that go offline (Wi-Fi drop, app backgrounded). Uses virtual
// time and a seeded RNG, so every test run is exactly reproducible.

public struct LinkConditions: Sendable, Equatable {
    public var latency: Double      // one-way, seconds
    public var jitter: Double       // +/- seconds, uniform
    public var loss: Double         // 0…1
    public var duplicate: Double    // 0…1
    public var reorder: Double      // 0…1 chance of an extra delay that reorders

    public init(latency: Double = 0.005, jitter: Double = 0, loss: Double = 0, duplicate: Double = 0, reorder: Double = 0) {
        self.latency = latency
        self.jitter = jitter
        self.loss = loss
        self.duplicate = duplicate
        self.reorder = reorder
    }

    public static let lan = LinkConditions(latency: 0.004, jitter: 0.001)

    public var label: String {
        var parts = ["\(Int((latency * 1000).rounded()))ms"]
        if jitter > 0 { parts.append("±\(Int((jitter * 1000).rounded()))ms") }
        if loss > 0 { parts.append("\(String(format1: loss * 100))% loss") }
        if duplicate > 0 { parts.append("\(Int(duplicate * 100))% dup") }
        if reorder > 0 { parts.append("\(Int(reorder * 100))% reorder") }
        return parts.joined(separator: " ")
    }
}

public final class SimulatedNetwork {
    struct Datagram {
        var deliverAt: Double
        var order: Int
        var from: Int
        var to: Int
        var bytes: [UInt8]
    }

    public private(set) var now: Double = 0
    public var conditions: LinkConditions
    /// Per-node overrides (applies to packets sent to or from that node).
    public var nodeConditions: [String: LinkConditions] = [:]
    public var offlineNodes: Set<String> = []
    private var rng: DeterministicRNG
    private var inFlight: [Datagram] = []
    private var order = 0
    private var nextEndpoint = 1
    fileprivate var endpoints: [Int: SimEndpoint] = [:]
    fileprivate var adverts: [Int: RoomAdvert] = [:]

    public private(set) var sent = 0
    public private(set) var dropped = 0
    public private(set) var duplicated = 0
    public private(set) var bytesSent = 0

    public init(conditions: LinkConditions = .lan, seed: UInt64 = 1) {
        self.conditions = conditions
        self.rng = DeterministicRNG(seed: seed, stream: 77)
    }

    public func provider(node: String) -> NetworkProvider { SimNetworkProvider(network: self, node: node) }

    private func random() -> Double { Double(rng.next()) / Double(UInt32.max) }

    fileprivate func register(_ e: SimEndpoint) -> Int {
        let id = nextEndpoint
        nextEndpoint += 1
        endpoints[id] = e
        return id
    }

    fileprivate func unregister(_ id: Int) {
        endpoints[id] = nil
        adverts[id] = nil
    }

    fileprivate func enqueue(from: Int, to: Int, bytes: [UInt8]) {
        sent += 1
        bytesSent += bytes.count
        guard let src = endpoints[from] else { return }
        let dstNode = endpoints[to]?.node
        let c = nodeConditions[src.node] ?? dstNode.flatMap { nodeConditions[$0] } ?? conditions
        if offlineNodes.contains(src.node) || (dstNode.map { offlineNodes.contains($0) } ?? false) { dropped += 1; return }
        if random() < c.loss { dropped += 1; return }
        let copies = random() < c.duplicate ? 2 : 1
        if copies == 2 { duplicated += 1 }
        for _ in 0..<copies {
            var delay = c.latency + (random() * 2 - 1) * c.jitter
            if random() < c.reorder { delay += c.jitter * 2 + 0.012 }
            order += 1
            inFlight.append(Datagram(deliverAt: now + max(0, delay), order: order, from: from, to: to, bytes: bytes))
        }
    }

    /// Advance virtual time, delivering every datagram that is due.
    public func advance(to time: Double) {
        now = time
        guard !inFlight.isEmpty else { return }
        var due: [Datagram] = []
        var keep: [Datagram] = []
        keep.reserveCapacity(inFlight.count)
        for d in inFlight { if d.deliverAt <= time { due.append(d) } else { keep.append(d) } }
        inFlight = keep
        due.sort { ($0.deliverAt, $0.order) < ($1.deliverAt, $1.order) }
        for d in due {
            guard let dst = endpoints[d.to] else { continue }
            if offlineNodes.contains(dst.node) { dropped += 1; continue }
            dst.deliver(from: d.from, bytes: d.bytes)
        }
    }

    fileprivate func visibleAdverts() -> [RoomAdvert] {
        adverts.compactMap { (id, ad) in
            guard let e = endpoints[id], !offlineNodes.contains(e.node) else { return nil }
            return ad
        }.sorted { ($0.roomCode, $0.epoch) < ($1.roomCode, $1.epoch) }
    }
}

fileprivate class SimEndpoint {
    let node: String
    unowned let network: SimulatedNetwork
    var id = 0
    var queue: [TransportEvent] = []
    var closed = false

    init(node: String, network: SimulatedNetwork) {
        self.node = node
        self.network = network
    }

    func deliver(from: Int, bytes: [UInt8]) {}
}

fileprivate final class SimHost: SimEndpoint, HostTransport {
    var known: Set<Int> = []

    override func deliver(from: Int, bytes: [UInt8]) {
        if !known.contains(from) { known.insert(from); queue.append(.connected(from)) }
        queue.append(.received(from, bytes))
    }

    func poll(into events: inout [TransportEvent]) {
        events.append(contentsOf: queue)
        queue.removeAll(keepingCapacity: true)
    }

    func send(_ bytes: [UInt8], to link: LinkID) {
        guard !closed else { return }
        network.enqueue(from: id, to: link, bytes: bytes)
    }

    func closeLink(_ link: LinkID) { known.remove(link) }

    func shutdown() {
        closed = true
        network.unregister(id)
    }

    func updateAdvert(_ advert: RoomAdvert) {
        guard !closed else { return }
        var a = advert
        a.endpoint = String(id)
        network.adverts[id] = a
    }
}

fileprivate final class SimClient: SimEndpoint, NetTransport {
    let host: Int

    init(node: String, network: SimulatedNetwork, host: Int) {
        self.host = host
        super.init(node: node, network: network)
    }

    override func deliver(from: Int, bytes: [UInt8]) {
        guard from == host else { return }
        queue.append(.received(0, bytes))
    }

    func poll(into events: inout [TransportEvent]) {
        events.append(contentsOf: queue)
        queue.removeAll(keepingCapacity: true)
    }

    func send(_ bytes: [UInt8], to link: LinkID) {
        guard !closed else { return }
        network.enqueue(from: id, to: host, bytes: bytes)
    }

    func closeLink(_ link: LinkID) {}

    func shutdown() {
        closed = true
        network.unregister(id)
    }
}

fileprivate final class SimBrowser: RoomBrowser {
    unowned let network: SimulatedNetwork
    let node: String
    var running = false
    init(network: SimulatedNetwork, node: String) { self.network = network; self.node = node }
    var rooms: [RoomAdvert] {
        guard running, !network.offlineNodes.contains(node) else { return [] }
        return network.visibleAdverts()
    }
    func start() { running = true }
    func stop() { running = false }
}

fileprivate final class SimNetworkProvider: NetworkProvider {
    unowned let network: SimulatedNetwork
    let node: String

    init(network: SimulatedNetwork, node: String) {
        self.network = network
        self.node = node
    }

    func makeHost(advert: RoomAdvert) throws -> HostTransport {
        let h = SimHost(node: node, network: network)
        h.id = network.register(h)
        h.updateAdvert(advert)
        return h
    }

    func makeClient(to advert: RoomAdvert) throws -> NetTransport {
        guard let hostID = Int(advert.endpoint), network.endpoints[hostID] != nil else {
            throw NetworkError.unavailable("No such host")
        }
        let c = SimClient(node: node, network: network, host: hostID)
        c.id = network.register(c)
        return c
    }

    func makeBrowser() -> RoomBrowser { SimBrowser(network: network, node: node) }
}
