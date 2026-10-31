// RIFT RIVALS — per-peer connection state: packet framing, a small reliable
// ordered channel, duplicate suppression and link quality measurement.

@inline(__always) func seqGreater(_ a: UInt16, _ b: UInt16) -> Bool { Int16(bitPattern: a &- b) > 0 }

/// Honest, user-facing connection label.
public enum ConnectionQuality: UInt8, Sendable {
    case excellent, good, unstable, reconnecting

    public var label: String {
        switch self {
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .unstable: return "Unstable"
        case .reconnecting: return "Reconnecting"
        }
    }
}

public struct LinkStats: Sendable {
    public var srtt: Double = 0          // seconds
    public var rttVar: Double = 0        // jitter estimate, seconds
    public var hasRTT = false
    public var lastReceive: Double = 0
    public var packetsReceived: Int = 0
    public var duplicatesDropped: Int = 0
    public var staleDropped: Int = 0
    public var malformedDropped: Int = 0
    /// Inbound loss estimate over the last 128 sequence numbers (0…1).
    public var inboundLoss: Double = 0
    /// Loss the remote side reported for packets we sent it (0…1).
    public var outboundLoss: Double = 0
    public var remoteRTTms: Int = 0

    mutating func addRTTSample(_ rtt: Double) {
        let r = max(0, rtt)
        if !hasRTT {
            srtt = r; rttVar = r / 2; hasRTT = true
        } else {
            rttVar = 0.75 * rttVar + 0.25 * abs(srtt - r)
            srtt = 0.875 * srtt + 0.125 * r
        }
    }

    public var rttMs: Int { Int((srtt * 1000).rounded()) }
    public var jitterMs: Int { Int((rttVar * 1000).rounded()) }
    public var lossPercent: Double { max(inboundLoss, outboundLoss) * 100 }

    public func quality(now: Double) -> ConnectionQuality {
        if now - lastReceive > 0.75 { return .reconnecting }
        let loss = lossPercent
        if rttMs <= 45 && loss < 1 && jitterMs <= 12 { return .excellent }
        if rttMs <= 110 && loss < 4 && jitterMs <= 30 { return .good }
        return .unstable
    }
}

struct ReliableChannel {
    struct Pending { var seq: UInt16; var type: UInt8; var payload: [UInt8]; var lastSent: Double; var sends: Int }

    var nextSendSeq: UInt16 = 1
    var outgoing: [Pending] = []
    // Receive side.
    var nextExpected: UInt16 = 1
    var buffered: [UInt16: (UInt8, [UInt8])] = [:]

    var receiveAck: UInt16 { nextExpected &- 1 }

    mutating func enqueue(type: UInt8, payload: [UInt8]) {
        outgoing.append(Pending(seq: nextSendSeq, type: type, payload: payload, lastSent: -1, sends: 0))
        nextSendSeq &+= 1
    }

    mutating func handleAck(_ ack: UInt16) {
        outgoing.removeAll { !seqGreater($0.seq, ack) }
    }

    /// Accept a reliable message; returns in-order deliverable messages.
    mutating func receive(seq: UInt16, type: UInt8, payload: [UInt8], into out: inout [(UInt8, [UInt8])]) -> Bool {
        if !seqGreater(seq, receiveAck) { return false } // duplicate / already delivered
        if seq == nextExpected {
            out.append((type, payload))
            nextExpected &+= 1
            while let next = buffered.removeValue(forKey: nextExpected) {
                out.append(next)
                nextExpected &+= 1
            }
        } else if buffered[seq] == nil && buffered.count < 256 {
            buffered[seq] = (type, payload)
        } else {
            return false
        }
        return true
    }
}

/// One remote peer as seen from this device.
public final class PeerLink {
    public let link: LinkID
    public var stats = LinkStats()
    var reliable = ReliableChannel()
    var sendSeq: UInt16 = 0
    var highestRecvSeq: UInt16 = 0
    var recvWindow: UInt64 = 0      // bit k set = (highestRecvSeq - k) received
    var anyReceived = false
    var pingSeq: UInt16 = 0
    var lastPingSent: Double = -10
    var lastSend: Double = -10
    let sessionID: UInt32
    var epoch: UInt16

    public init(link: LinkID, sessionID: UInt32, epoch: UInt16, now: Double) {
        self.link = link
        self.sessionID = sessionID
        self.epoch = epoch
        stats.lastReceive = now
    }

    public func sendReliable(_ m: NetMessage) {
        reliable.enqueue(type: m.type.rawValue, payload: MessageCodec.payload(m))
    }

    public var hasPendingReliable: Bool { !reliable.outgoing.isEmpty }

    /// Build a packet with all due reliable messages and the given unreliable ones.
    public func buildPacket(now: Double, unreliable: [NetMessage]) -> [UInt8]? {
        var w = ByteWriter(capacity: 256)
        w.u16(NetProtocol.magic); w.u8(NetProtocol.version); w.u8(0)
        w.u32(sessionID); w.u16(epoch)
        sendSeq &+= 1
        w.u16(sendSeq)
        w.u16(reliable.receiveAck)

        // Reliable section first (it must never starve), resent after ~1.5 RTT.
        let resendAfter = min(0.25, max(0.05, stats.hasRTT ? stats.srtt * 1.5 + stats.rttVar * 2 : 0.1))
        var budget = NetProtocol.maxPacketBytes - 16
        let countIndex = w.bytes.count
        w.u8(0)
        var relCount: UInt8 = 0
        for k in reliable.outgoing.indices where relCount < 32 {
            let item = reliable.outgoing[k]
            guard item.lastSent < 0 || now - item.lastSent >= resendAfter else { continue }
            let size = 5 + item.payload.count
            if size > budget { break }
            w.u16(item.seq); w.u8(item.type); w.u16(UInt16(item.payload.count)); w.raw(item.payload)
            reliable.outgoing[k].lastSent = now
            reliable.outgoing[k].sends += 1
            budget -= size
            relCount += 1
        }
        w.bytes[countIndex] = relCount
        // Unreliable messages fill the remaining space; anything that does not
        // fit is dropped (inputs are redundant and resent next tick anyway).
        let uCountIndex = w.bytes.count
        w.u8(0)
        var uCount: UInt8 = 0
        for m in unreliable {
            let p = MessageCodec.payload(m)
            let size = 3 + p.count
            if size > budget { continue }
            w.u8(m.type.rawValue); w.u16(UInt16(p.count)); w.raw(p)
            budget -= size
            uCount += 1
        }
        w.bytes[uCountIndex] = uCount
        lastSend = now
        return w.bytes
    }

    public func makePing(now: Double) -> NetMessage {
        pingSeq &+= 1
        lastPingSent = now
        return .ping(PingMsg(seq: pingSeq, sendTime: now, lossPermille: UInt16(min(1000, stats.inboundLoss * 1000)),
                             rttMs: UInt16(clamping: stats.rttMs)))
    }

    public enum ParseResult { case ok, wrongSession, malformed, duplicate }

    /// Parse a datagram. Appends decoded messages (reliable ones in order) to `out`.
    public func parse(_ bytes: [UInt8], now: Double, acceptEpoch: (UInt16) -> Bool, out: inout [NetMessage]) -> ParseResult {
        var r = ByteReader(bytes)
        do {
            guard try r.u16() == NetProtocol.magic, try r.u8() == NetProtocol.version else { stats.malformedDropped += 1; return .malformed }
            _ = try r.u8()
            let sid = try r.u32()
            let ep = try r.u16()
            guard sid == sessionID, acceptEpoch(ep) else { return .wrongSession }
            let seq = try r.u16()
            let ack = try r.u16()

            // Duplicate suppression and loss accounting on the packet sequence.
            if !anyReceived {
                anyReceived = true
                highestRecvSeq = seq
                recvWindow = 1
            } else if seqGreater(seq, highestRecvSeq) {
                let shift = Int(seq &- highestRecvSeq)
                recvWindow = shift >= 64 ? 1 : (recvWindow << UInt64(shift)) | 1
                highestRecvSeq = seq
            } else {
                let back = Int(highestRecvSeq &- seq)
                if back >= 64 { stats.staleDropped += 1; return .duplicate }
                let bit: UInt64 = 1 << UInt64(back)
                if recvWindow & bit != 0 { stats.duplicatesDropped += 1; return .duplicate }
                recvWindow |= bit
            }
            let received = recvWindow.nonzeroBitCount
            let span = min(64, max(1, Int(highestRecvSeq) + 1))
            stats.inboundLoss = 0.9 * stats.inboundLoss + 0.1 * max(0, 1 - Double(received) / Double(min(64, span)))
            stats.packetsReceived += 1
            stats.lastReceive = now
            reliable.handleAck(ack)

            let relCount = Int(try r.u8())
            var delivered: [(UInt8, [UInt8])] = []
            for _ in 0..<relCount {
                let rseq = try r.u16(), type = try r.u8(), len = Int(try r.u16())
                guard r.remaining >= len else { throw ByteReaderError.underflow }
                var payload: [UInt8] = []
                payload.reserveCapacity(len)
                for _ in 0..<len { payload.append(try r.u8()) }
                _ = reliable.receive(seq: rseq, type: type, payload: payload, into: &delivered)
            }
            for (t, p) in delivered { out.append(try MessageCodec.decode(type: t, p)) }
            let unrelCount = Int(try r.u8())
            for _ in 0..<unrelCount {
                let type = try r.u8(), len = Int(try r.u16())
                guard r.remaining >= len else { throw ByteReaderError.underflow }
                var payload: [UInt8] = []
                payload.reserveCapacity(len)
                for _ in 0..<len { payload.append(try r.u8()) }
                if let m = try? MessageCodec.decode(type: type, payload) { out.append(m) }
            }
            return .ok
        } catch {
            stats.malformedDropped += 1
            return .malformed
        }
    }

    /// Peek the session id / epoch of a datagram without consuming it.
    public static func peekHeader(_ bytes: [UInt8]) -> (sessionID: UInt32, epoch: UInt16)? {
        var r = ByteReader(bytes)
        guard (try? r.u16()) == NetProtocol.magic, (try? r.u8()) == NetProtocol.version, (try? r.u8()) != nil,
              let sid = try? r.u32(), let ep = try? r.u16() else { return nil }
        return (sid, ep)
    }

    /// Records an RTT sample from a pong echo.
    func handlePong(_ p: PongMsg, now: Double) {
        stats.addRTTSample(now - p.echoTime)
        stats.outboundLoss = Double(p.lossPermille) / 1000
    }
}
