// riftsim — RIFT RIVALS network test matrix.
//
// Runs complete host/client sessions over the simulated network under a range
// of latency, jitter, loss, duplication and reordering conditions plus
// failure scenarios, and prints a Markdown report.
//
//   swift run -c release riftsim [--quick] [--out FILE]

import RiftCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

struct Row {
    var scenario: String
    var players: String
    var conditions: String
    var report: TestbedReport
    var seconds: Double
    var humans: Int
    var extra: String
    var pass: Bool
}

let args = CommandLine.arguments
let quick = args.contains("--quick")
let outPath: String? = args.firstIndex(of: "--out").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
let matchSeconds = quick ? 10.0 : 30.0
var rows: [Row] = []

func settings(_ f: MatchFormat) -> MatchSettings {
    MatchSettings(format: f, roundSeconds: 300, goalsToWin: 0, bestOf: 1, arena: .pillarDrift)
}

func lateText(_ tb: NetTestbed) -> String {
    var compared = 0, replaced = 0
    for n in tb.nodes.dropFirst() {
        let m = tb.inputMismatches(node: n)
        compared += m.compared; replaced += m.replaced
    }
    guard compared > 0 else { return "-" }
    let pct: Double = Double(replaced) * 100 / Double(compared)
    return String(format1: pct) + "%"
}

func steady(_ name: String, humans: Int, format: MatchFormat, _ c: LinkConditions) {
    let tb = NetTestbed(TestbedConfig(humans: humans, settings: settings(format), conditions: c, seed: UInt64(rows.count + 3)))
    guard tb.connectAndStart() else {
        rows.append(Row(scenario: name, players: "\(humans) humans", conditions: c.label, report: TestbedReport(), seconds: 0,
                        humans: humans, extra: "lobby failed", pass: false))
        return
    }
    tb.run(seconds: matchSeconds)
    let r = tb.verify()
    rows.append(Row(scenario: name, players: "\(format.label) (\(humans) humans)", conditions: c.label, report: r,
                    seconds: matchSeconds, humans: humans, extra: "late inputs replaced: \(lateText(tb))",
                    pass: r.consistent && r.maxSimultaneousHostsPerEpoch == 1))
    print("  \(name) [\(c.label)] \(r)")
    fflush(stdout)
}

print("RIFT RIVALS network matrix (\(quick ? "quick" : "full"), \(Int(matchSeconds)) s per run)")

// Same Wi-Fi, all formats.
for (h, f) in [(2, MatchFormat.duel), (4, .duo), (6, .trio), (8, .squad)] {
    steady("Same Wi-Fi \(f.label)", humans: h, format: f, LinkConditions(latency: 0.004, jitter: 0.002, loss: 0.002))
}
// Latency sweep.
for ms in [10, 30, 50, 100, 200] {
    let c = LinkConditions(latency: Double(ms) / 1000, jitter: Double(ms) / 1000 * 0.1 + 0.001)
    steady("Latency \(ms) ms", humans: 2, format: .duel, c)
    steady("Latency \(ms) ms", humans: 8, format: .squad, c)
}
// Loss sweep.
for loss in [0.01, 0.03, 0.05] {
    steady("Packet loss \(Int(loss * 100))%", humans: 4, format: .duo, LinkConditions(latency: 0.02, jitter: 0.004, loss: loss))
}
steady("Jitter + reordering", humans: 4, format: .duo, LinkConditions(latency: 0.03, jitter: 0.025, loss: 0.01, reorder: 0.15))
steady("Duplication storm", humans: 4, format: .duo, LinkConditions(latency: 0.02, jitter: 0.005, duplicate: 0.3))
steady("Worst case", humans: 8, format: .squad, LinkConditions(latency: 0.1, jitter: 0.03, loss: 0.05, duplicate: 0.05, reorder: 0.1))

// Failure scenarios.
func failure(_ name: String, humans: Int, format: MatchFormat, _ body: (NetTestbed) -> (TestbedReport, String, Bool)) {
    let tb = NetTestbed(TestbedConfig(humans: humans, settings: settings(format), conditions: LinkConditions(latency: 0.015, jitter: 0.003, loss: 0.01)))
    guard tb.connectAndStart() else { return }
    let (r, extra, ok) = body(tb)
    rows.append(Row(scenario: name, players: "\(format.label) (\(humans) humans)", conditions: "15ms ±3ms 1% loss", report: r,
                    seconds: 0, humans: humans, extra: extra, pass: ok))
    print("  \(name) \(r) \(extra)")
    fflush(stdout)
}

failure("Client drops 5 s, reconnects", humans: 4, format: .duo) { tb in
    tb.run(seconds: 5); tb.setOffline(tb.nodes[3], true); tb.run(seconds: 5); tb.setOffline(tb.nodes[3], false); tb.run(seconds: 8)
    let r = tb.verify()
    return (r, "snapshots applied: \(r.snapshotsApplied)", r.consistent && r.snapshotsApplied > 0 && r.hostCount == 1)
}
failure("Host vanishes (migration)", humans: 4, format: .duo) { tb in
    tb.run(seconds: 6)
    let before = tb.nodes[1].controller.engine?.confirmedTick ?? 0
    tb.setOffline(tb.host, true)
    tb.run(seconds: 15)
    let survivors = Array(tb.nodes.dropFirst())
    let r = tb.verify(nodes: survivors, groundTruth: false, sinceTick: before)
    let newHost = survivors.first { $0.isHostMode }
    let progressed = (survivors[0].controller.engine?.confirmedTick ?? 0) - before
    return (r, "new host: \(newHost?.name ?? "none") epoch \(newHost?.hostEpoch ?? 0), +\(progressed) ticks after loss",
            r.consistent && survivors.filter { $0.isHostMode }.count == 1 && progressed > 300 && tb.maxHostsSameEpoch == 1)
}
failure("Host backgrounded 1.2 s", humans: 3, format: .duo) { tb in
    tb.run(seconds: 5); tb.suspend(tb.host, true); tb.run(seconds: 1.2); tb.suspend(tb.host, false); tb.run(seconds: 6)
    let r = tb.verify()
    return (r, "no migration needed", r.consistent && tb.host.isHostMode)
}
failure("Host backgrounded 9 s", humans: 3, format: .duo) { tb in
    tb.run(seconds: 5); tb.suspend(tb.host, true); tb.run(seconds: 9); tb.suspend(tb.host, false); tb.run(seconds: 10)
    let r = tb.verify(groundTruth: false)
    return (r, r.transitions.joined(separator: "; "), r.consistent && r.hostCount == 1 && tb.maxHostsSameEpoch == 1)
}
failure("Client backgrounded 6 s", humans: 2, format: .duel) { tb in
    tb.run(seconds: 5); tb.suspend(tb.nodes[1], true); tb.run(seconds: 6); tb.suspend(tb.nodes[1], false); tb.run(seconds: 8)
    let r = tb.verify()
    return (r, "snapshots applied: \(r.snapshotsApplied)", r.consistent && r.hostCount == 1)
}
failure("Injected desync", humans: 2, format: .duel) { tb in
    tb.run(seconds: 5)
    if case .client(let c) = tb.nodes[1].controller.mode { c.debugCorrupt() }
    tb.run(seconds: 6)
    let log = tb.host.controller.diagnostics.desyncLog
    let since = (tb.nodes[1].controller.engine?.currentTick ?? 0) - 240
    let r = tb.verify(sinceTick: since)
    let first = log.first.map { "detected at tick \($0.firstMismatchTick) (last good \($0.lastMatchingTick))" } ?? "NOT detected"
    return (r, first + ", repaired by snapshot", r.consistent && !log.isEmpty && r.snapshotsApplied > 0)
}

// Report.
var md = "# RIFT RIVALS — Network Test Results\n\n"
md += "Generated by `swift run -c release riftsim\(quick ? " --quick" : "")`. Every run is a complete host/client session "
md += "(real `HostSession`/`ClientSession` code) over the deterministic simulated network. Devices run at 60, 90 and 120 FPS "
md += "with independent, drifting monotonic clocks (±300 ppm, unrelated offsets). Latency is one-way; RTT is roughly double plus frame alignment.\n\n"
md += "*Checkpoints* are 0.5 s state hashes compared across **all** devices; *Truth* replays the host's confirmed input log on a fresh "
md += "simulation and compares the result to the live match.\n\n"
md += "| Scenario | Players | Conditions | Checkpoints | Mismatches | Truth | Avg RTT | Rollbacks / device / s | Max rollback | Notes | Result |\n"
md += "|---|---|---|---|---|---|---|---|---|---|---|\n"
for r in rows {
    var rb = "-"
    if r.seconds > 0 {
        let perSecond: Double = Double(r.report.rollbacks) / Double(r.humans) / (r.seconds + 0.5)
        rb = String(format1: perSecond)
    }
    let truth = r.report.groundTruthChecked ? (r.report.groundTruthMatches ? "match" : "FAIL") : "n/a"
    let result: String = r.pass ? "PASS" : "FAIL"
    let cols: [String] = [r.scenario, r.players, r.conditions, String(r.report.checkpointsCompared),
                          String(r.report.checkpointMismatches), truth, "\(r.report.avgRTTms) ms", rb,
                          "\(r.report.maxRollbackDepth) t", r.extra, result]
    md += "| " + cols.joined(separator: " | ") + " |\n"
}
let passed = rows.filter { $0.pass }.count
md += "\n**\(passed) / \(rows.count) scenarios passed.**\n\n"
md += "These are simulated conditions, not guarantees of real-world performance. Real Wi-Fi adds variable airtime contention, "
md += "power-save latency spikes and AWDL channel hopping that a simulator does not reproduce.\n"
print("")
print(md)
if let path = outPath, let f = fopen(path, "w") {
    fputs(md, f)
    fclose(f)
    print("wrote \(path)")
}
exit(passed == rows.count ? 0 : 1)
