import Foundation
import Network

// RIFT RIVALS — local multiplayer transport for iOS.
//
// Discovery: Bonjour (`_riftrivals._udp`) via NWListener / NWBrowser. The room
// code, epoch and match id travel in the TXT record so clients can find a
// migrated host without any server.
// Data: plain UDP datagrams over NWConnection. `includePeerToPeer` lets Apple
// devices use AWDL peer-to-peer Wi-Fi when they are not on the same network.
// Reliability, ordering and duplicate suppression live in RiftCore's PeerLink.

private func makeParameters() -> NWParameters {
    let p = NWParameters.udp
    p.includePeerToPeer = true
    p.serviceClass = .interactiveVoice   // lowest-latency Wi-Fi access category
    p.allowLocalEndpointReuse = true
    return p
}

/// Thread-safe event queue shared by the NW callback queue and the game loop.
final class EventBox {
    private let lock = NSLock()
    private var events: [TransportEvent] = []
    func push(_ e: TransportEvent) { lock.lock(); events.append(e); lock.unlock() }
    func drain(into out: inout [TransportEvent]) {
        lock.lock()
        out.append(contentsOf: events)
        events.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

final class BonjourNetworkProvider: NetworkProvider {
    func makeHost(advert: RoomAdvert) throws -> HostTransport { try BonjourHostTransport(advert: advert) }
    func makeClient(to advert: RoomAdvert) throws -> NetTransport { BonjourClientTransport(serviceName: advert.endpoint) }
    func makeBrowser() -> RoomBrowser { BonjourRoomBrowser() }
}

final class BonjourHostTransport: HostTransport {
    private let queue = DispatchQueue(label: "rift.host", qos: .userInteractive)
    private var listener: NWListener?
    private var connections: [LinkID: NWConnection] = [:]
    private let connLock = NSLock()
    private var nextLink = 1
    private let box = EventBox()
    private var advert: RoomAdvert
    private var stopped = false
    private(set) var lastError: String?

    init(advert: RoomAdvert) throws {
        self.advert = advert
        try startListener()
    }

    private func serviceName(_ a: RoomAdvert) -> String { "RR-\(a.roomCode)-\(a.epoch)" }

    private func makeService(_ a: RoomAdvert) -> NWListener.Service {
        let txt = NWTXTRecord(a.txtRecord)
        return NWListener.Service(name: serviceName(a), type: NetProtocol.bonjourType, domain: nil, txtRecord: txt)
    }

    private func startListener() throws {
        let l = try NWListener(using: makeParameters())
        l.service = makeService(advert)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed(let err):
                self.lastError = err.localizedDescription
                // Typically after returning from the background: restart advertising.
                self.listener?.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, !self.stopped else { return }
                    try? self.startListener()
                }
            default:
                break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        connLock.lock()
        let id = nextLink
        nextLink += 1
        connections[id] = conn
        connLock.unlock()
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.box.push(.connected(id))
            case .failed, .cancelled: self?.box.push(.disconnected(id)); self?.remove(id)
            default: break
            }
        }
        conn.start(queue: queue)
        receive(conn, id: id)
    }

    private func receive(_ conn: NWConnection, id: LinkID) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty { self.box.push(.received(id, [UInt8](d))) }
            if error == nil { self.receive(conn, id: id) }
        }
    }

    private func remove(_ id: LinkID) {
        connLock.lock()
        connections[id] = nil
        connLock.unlock()
    }

    func poll(into events: inout [TransportEvent]) { box.drain(into: &events) }

    func send(_ bytes: [UInt8], to link: LinkID) {
        connLock.lock()
        let c = connections[link]
        connLock.unlock()
        c?.send(content: Data(bytes), completion: .idempotent)
    }

    func closeLink(_ link: LinkID) {
        connLock.lock()
        let c = connections.removeValue(forKey: link)
        connLock.unlock()
        c?.cancel()
    }

    func shutdown() {
        stopped = true
        listener?.cancel()
        connLock.lock()
        let all = connections.values
        connections.removeAll()
        connLock.unlock()
        all.forEach { $0.cancel() }
    }

    func updateAdvert(_ a: RoomAdvert) {
        guard a != advert || listener?.service == nil else { return }
        let nameChanged = serviceName(a) != serviceName(advert)
        advert = a
        queue.async { [weak self] in
            guard let self = self, let l = self.listener else { return }
            if nameChanged {
                l.service = self.makeService(a)
            } else {
                l.service = self.makeService(a)
            }
        }
    }
}

final class BonjourClientTransport: NetTransport {
    private let queue = DispatchQueue(label: "rift.client", qos: .userInteractive)
    private let connection: NWConnection
    private let box = EventBox()

    init(serviceName: String) {
        let endpoint: NWEndpoint
        if serviceName.hasPrefix("ip:") {
            // Manual "ip:host:port" fallback.
            let parts = serviceName.dropFirst(3).split(separator: ":")
            let host = String(parts.first ?? "127.0.0.1")
            let port = NWEndpoint.Port(rawValue: UInt16(parts.last ?? "0") ?? 0) ?? .any
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
        } else {
            endpoint = .service(name: serviceName, type: NetProtocol.bonjourType, domain: "local.", interface: nil)
        }
        connection = NWConnection(to: endpoint, using: makeParameters())
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.box.push(.connected(0))
            case .failed, .cancelled: self?.box.push(.disconnected(0))
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty { self.box.push(.received(0, [UInt8](d))) }
            if error == nil { self.receive() }
        }
    }

    func poll(into events: inout [TransportEvent]) { box.drain(into: &events) }
    func send(_ bytes: [UInt8], to link: LinkID) { connection.send(content: Data(bytes), completion: .idempotent) }
    func closeLink(_ link: LinkID) {}
    func shutdown() { connection.cancel() }
}

final class BonjourRoomBrowser: RoomBrowser {
    private let queue = DispatchQueue(label: "rift.browse", qos: .userInitiated)
    private var browser: NWBrowser?
    private let lock = NSLock()
    private var found: [RoomAdvert] = []
    private(set) var state: String = "idle"

    var rooms: [RoomAdvert] {
        lock.lock(); defer { lock.unlock() }
        return found
    }

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: NetProtocol.bonjourType, domain: nil), using: makeParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var list: [RoomAdvert] = []
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint else { continue }
                guard case let .bonjour(txt) = r.metadata else { continue }
                if let ad = RoomAdvert(txt: txt.dictionary, endpoint: name) { list.append(ad) }
            }
            list.sort { ($0.roomCode, $0.epoch) < ($1.roomCode, $1.epoch) }
            self?.lock.lock()
            self?.found = list
            self?.lock.unlock()
        }
        b.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.state = "ready"
            case .failed(let e): self?.state = "failed: \(e.localizedDescription)"
            case .waiting(let e): self?.state = "waiting: \(e.localizedDescription)"
            default: break
            }
        }
        browser = b
        b.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
