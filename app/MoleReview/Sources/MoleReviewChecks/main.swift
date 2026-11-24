import Foundation
import MoleReviewCore

// Plain-assert checks (no XCTest on Command Line Tools). Each prints its name; any failure exits 1.
var failures = 0
func check(_ name: String, _ body: () throws -> Bool) {
    do {
        if try body() { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
    } catch {
        print("FAIL \(name): \(error)"); failures += 1
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let fixtures = root.appendingPathComponent("Fixtures")
func fixture(_ n: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(n)) }
func plan(_ n: String) throws -> Plan {
    guard case .plan(let p) = try PlanDocument.decode(fixture(n)) else { throw MoleError("not a plan: \(n)") }
    return p
}
let fake = fixtures.appendingPathComponent("fake-mo.sh").path
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("mole-review-checks-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

check("decode sample plan") {
    let p = try plan("plan-sample.json")
    return p.schema == 1 && !p.sections.isEmpty && p.planId.count > 4 && p.expiresAt > p.createdAt
}
check("decode tricky fixture (quote/backslash/newline/emoji, covered_by, command, null free_bytes, skipped)") {
    let p = try plan("tricky.json")
    let i1 = p.allItems[0]
    return i1.path == "/Users/test/Library/Caches/we\"ird\\na\nme \u{1F42D}" && p.freeBytes == nil
        && p.allItems[2].coveredBy == "i2" && p.allItems[3].isCommand && p.skipped.count == 1
        && p.skipped[0].reason == "needs sudo" && p.sections[0].name == "User \"essentials\""
}
check("fixtures contain only sample or test home paths") {
    let urls = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
    let pattern = try NSRegularExpression(pattern: #"/Users/(?!sample(?:/|$)|test(?:/|$))"#)
    return try urls.allSatisfy { url in
        let text = try String(contentsOf: url, encoding: .utf8)
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil
    }
}
check("opt-in item starts unticked and does not add to totals") {
    let p = try plan("plan-sample.json")
    let s = ReviewState(plan: p)
    guard let item = p.allItems.first(where: { !$0.defaultSelected && !$0.isCovered }) else { return false }
    return !s.isSelected(item) && s.selectedBytes == p.totalBytes && s.selectedItems == p.totalItems
}
check("decode error document") {
    guard case .error(let e) = try PlanDocument.decode(fixture("error.json")) else { return false }
    return e.code == "cancelled" && e.message.contains("cancelled")
}
check("non-JSON stdout is rejected") {
    do { _ = try PlanDocument.decode(Data("hello".utf8)); return false } catch { return true }
}
check("default selection totals equal plan total_bytes/total_items (sample plan)") {
    let p = try plan("plan-sample.json")
    let s = ReviewState(plan: p)
    return s.selectedBytes == p.totalBytes && s.selectedItems == p.totalItems
}
check("default selection totals equal plan totals (tricky); covered rows never add") {
    let p = try plan("tricky.json")
    var s = ReviewState(plan: p)
    guard s.selectedBytes == p.totalBytes, s.selectedItems == p.totalItems else { return false }
    s.toggle("i2")
    return s.selectedBytes == 2000 && s.selectedItems == 4 && !s.isSelected(p.allItems[2])
}
check("section tri-state toggling") {
    let p = try plan("tricky.json")
    var s = ReviewState(plan: p)
    let user = p.sections[0]
    guard s.sectionState(user) == .on else { return false }
    s.toggle("i1")
    guard s.sectionState(user) == .mixed else { return false }
    s.setSection("user", on: false)
    guard s.sectionState(user) == .off, s.selected == ["i4"] else { return false }
    s.setSection("user", on: true)
    return s.sectionState(user) == .on
}
check("search filters by path, keeps covered rows under their folder, sorts by size") {
    let p = try plan("tricky.json")
    var s = ReviewState(plan: p)
    let all = s.rows(in: p.sections[0])
    guard all.map({ $0.item.id }) == ["i1", "i2", "i3"], all[2].indented, !all[1].indented else { return false }
    s.searchText = "INNER"
    let hit = s.rows(in: p.sections[0])
    guard hit.map({ $0.item.id }) == ["i2", "i3"] else { return false }
    s.searchText = "nomatch"
    return s.rows(in: p.sections[0]).isEmpty
}
check("selection file: ids only, newline-terminated, mode 0600") {
    let p = try plan("tricky.json")
    var s = ReviewState(plan: p)
    s.toggle("i1")
    let url = try s.writeSelectionFile(in: scratch)
    let text = try String(contentsOf: url, encoding: .utf8)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    return text == "i2\ni3\ni4\n" && mode == 0o600
}
check("expiry disables Clean") {
    let p = try plan("tricky.json")
    let s = ReviewState(plan: p)
    return s.canClean(now: p.expiresAt.addingTimeInterval(-60)) && !s.canClean(now: p.expiresAt)
        && s.isExpired(now: p.expiresAt.addingTimeInterval(1))
}
check("nothing ticked disables Clean") {
    var s = ReviewState(plan: try plan("tricky.json"))
    s.selectNone()
    return !s.canClean(now: s.plan.createdAt)
}
check("formatting: home abbreviation and countdown") {
    Format.abbreviate("/Users/test/x", home: "/Users/test") == "~/x" && Format.abbreviate("/Users/mex/x", home: "/Users/me") == "/Users/mex/x"
        && Format.countdown(125) == "2:05"
}

func fakeEnv(stdout: String? = nil, stderr: String = "", exit: Int = 0, argv: String? = nil) -> [String: String] {
    var e = ["FAKE_MO_STDERR": stderr, "FAKE_MO_EXIT": String(exit)]
    if let s = stdout { e["FAKE_MO_STDOUT_FILE"] = fixtures.appendingPathComponent(s).path }
    if let a = argv { e["FAKE_MO_ARGV_FILE"] = a }
    return e
}

check("runner separates stdout and stderr, streams stderr lines") {
    var seen: [String] = []
    let r = MoleRunner(executable: fake).run(arguments: MoleService.scanArguments,
                                             extraEnvironment: fakeEnv(stdout: "tricky.json", stderr: "line one\nline two")) { seen.append($0) }
    let doc = try? PlanDocument.decode(r.stdout)
    return r.exitCode == 0 && r.stderrLines == ["line one", "line two"] && seen == r.stderrLines
        && doc != nil && !String(decoding: r.stdout, as: UTF8.self).contains("line one")
}
check("scan interprets plan, error document, and non-JSON with stderr tail") {
    let ok = MoleService.interpretScan(MoleRunner(executable: fake).run(arguments: MoleService.scanArguments, extraEnvironment: fakeEnv(stdout: "tricky.json")))
    guard case .plan = ok else { return false }
    let err = MoleService.interpretScan(MoleRunner(executable: fake).run(arguments: MoleService.scanArguments, extraEnvironment: fakeEnv(stdout: "error.json", exit: 130)))
    guard case .failed(let m) = err, m.hasPrefix("cancelled:") else { return false }
    let junk = MoleService.interpretScan(MoleRunner(executable: fake).run(arguments: MoleService.scanArguments, extraEnvironment: fakeEnv(stderr: "boom happened", exit: 3)))
    guard case .failed(let m2) = junk else { return false }
    return m2.contains("exit 3") && m2.contains("boom happened")
}
check("non-zero exit is surfaced") {
    MoleRunner(executable: fake).run(arguments: ["clean"], extraEnvironment: fakeEnv(exit: 7)).exitCode == 7
}
check("missing executable is a launch error naming the path") {
    let r = MoleRunner(executable: "/nonexistent/mo").run(arguments: [])
    guard let e = r.launchError else { return false }
    if case .failure(let m) = MoleLocator.check("/nonexistent/mo") { return e.contains("/nonexistent/mo") && m.message.contains("/nonexistent/mo") }
    return false
}
check("locator: --version check and candidate order") {
    guard case .success(let v) = MoleLocator.check(fake), v.contains("fake") else { return false }
    let c = MoleLocator.candidates(environment: ["MOLE_PATH": "/a/mo"], repoRoot: "/repo", home: "/h")
    return c == ["/a/mo", "/repo/mole", "/opt/homebrew/bin/mo", "/usr/local/bin/mo", "/h/.local/bin/mo"]
}
check("apply passes exact --apply <id> --select <file> --trash arguments") {
    let argv = scratch.appendingPathComponent("argv1").path
    let args = MoleService.applyArguments(planId: "abc123", selectFile: "/tmp/sel", trash: true)
    _ = MoleRunner(executable: fake).run(arguments: args, extraEnvironment: fakeEnv(argv: argv))
    let got = try String(contentsOfFile: argv, encoding: .utf8)
    let argv2 = scratch.appendingPathComponent("argv2").path
    _ = MoleRunner(executable: fake).run(arguments: MoleService.applyArguments(planId: "abc123", selectFile: "/tmp/sel", trash: false), extraEnvironment: fakeEnv(argv: argv2))
    let got2 = try String(contentsOfFile: argv2, encoding: .utf8)
    return got == "clean\n--apply\nabc123\n--select\n/tmp/sel\n--trash\n"
        && got2 == "clean\n--apply\nabc123\n--select\n/tmp/sel\n"
}
func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }
check("cancel stops the child and its grandchild within 6 s") {
    let pidfile = scratch.appendingPathComponent("grandchild.pid")
    let runner = MoleRunner(executable: fake)
    runner.termGraceSeconds = 2
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) { runner.cancel() }
    let t0 = Date()
    var env = fakeEnv(); env["FAKE_MO_PIDFILE"] = pidfile.path
    let r = runner.run(arguments: ["clean", "--slow"], extraEnvironment: env)
    guard let text = try? String(contentsOf: pidfile, encoding: .utf8),
          let gc = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    usleep(200_000)
    return r.cancelled && Date().timeIntervalSince(t0) < 6 && !alive(gc)
}
check("cancel escalates to SIGTERM when SIGINT is ignored") {
    let script = scratch.appendingPathComponent("stubborn.sh")
    try "#!/bin/bash\ntrap '' INT\nwhile true; do sleep 0.2; done\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let runner = MoleRunner(executable: script.path)
    runner.termGraceSeconds = 1
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { runner.cancel() }
    let t0 = Date()
    let r = runner.run(arguments: [])
    return r.cancelled && Date().timeIntervalSince(t0) < 6
}
func histTime(_ t: String) -> Date {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.date(from: t)!
}
func sess(_ cmd: String, _ a: String, _ b: String?, id: String = "x") -> HistorySession {
    HistorySession(command: cmd, runId: id, startedAt: histTime(a), endedAt: b.map(histTime), items: 1, sizeText: "1.20GB",
                   removed: 1, trashed: 0, skipped: 0, failed: 0)
}
check("history attribution: exactly one real clean inside the apply's window, else nil") {
    let spawn = histTime("2026-11-24 14:50:00").addingTimeInterval(0.4), exit = histTime("2026-11-24 14:50:09").addingTimeInterval(0.2)
    let mine = sess("clean", "2026-11-24 14:50:00", "2026-11-24 14:50:09", id: "mine")
    let dry = sess("clean-dry-run", "2026-11-24 14:50:01", "2026-11-24 14:50:02")
    let before = sess("clean", "2026-11-24 14:40:00", "2026-11-24 14:41:00", id: "old")
    let running = sess("clean", "2026-11-24 14:50:03", nil, id: "unfinished")
    let other = sess("clean", "2026-11-24 14:50:02", "2026-11-24 14:50:05", id: "other")
    return History.attributed([dry, before, running, mine], spawnedAt: spawn, exitedAt: exit)?.runId == "mine"
        && History.attributed([mine, other], spawnedAt: spawn, exitedAt: exit) == nil
        && History.attributed([dry, before], spawnedAt: spawn, exitedAt: exit) == nil
}
check("history size text parses and formats like the rest of the app") {
    History.parseSize("1.20GB") == 1_200_000_000 && History.parseSize("512KB") == 512_000 && History.parseSize("junk") == nil
        && sess("clean", "2026-11-24 14:50:00", nil).sizeBytes.map(Format.bytes) == Format.bytes(1_200_000_000)
}
check("skipped reasons: real row formats, only this run's rows, plus plan skipped[]") {
    let rows = try String(contentsOf: fixtures.appendingPathComponent("oplog-apply.txt"), encoding: .utf8)
        .replacingOccurrences(of: "RUNID", with: "R1")
    let skipped = [SkippedEntry(section: "System", name: "System caches", reason: "needs sudo")]
    let g = SkippedReport.group(operationLog: rows, runId: "R1", planSkipped: skipped)
    let all = g.flatMap { $0.names }
    return g.map({ $0.reason }) == ["changed since review", "holds unticked item", "not in reviewed plan",
                                    "needs permanent delete", "needs sudo: " + SkippedReport.sudoHint]
        && !all.contains("/Users/sample/Library/Caches/NotMine") && !all.contains("/Users/sample/Library/Caches/Preview")
}
func applyEnv(oplog: URL, run: String, history: String = "history.json", rows: String? = "oplog-apply.txt", stderr: String = "") -> [String: String] {
    var env = fakeEnv(stderr: stderr)
    env["FAKE_MO_HISTORY_FILE"] = fixtures.appendingPathComponent(history).path
    env["FAKE_MO_OPLOG"] = oplog.path
    if let r = rows { env["FAKE_MO_OPLOG_ROWS"] = fixtures.appendingPathComponent(r).path }
    env["FAKE_MO_RUN_ID"] = run
    env["FAKE_MO_STATE"] = scratch.appendingPathComponent("state-\(UUID().uuidString)").path
    return env
}
func apply(_ env: [String: String]) -> ApplyResult {
    MoleService.runApply(runner: MoleRunner(executable: fake), planId: "p1", selectFile: "/tmp/s", trash: true,
                         planSkipped: [], extraEnvironment: env)
}
func freshLog(_ initial: String = "[2026-01-01 00:00:00] [clean run=OLD] SKIPPED /old (not in reviewed plan)\n") throws -> URL {
    let u = scratch.appendingPathComponent("operations-\(UUID().uuidString).log")
    try initial.write(to: u, atomically: true, encoding: .utf8)
    return u
}
check("apply end to end: the one session in the window, its log rows only, no notes") {
    let res = apply(applyEnv(oplog: try freshLog(), run: "R2"))
    let names = res.skipped.flatMap { $0.names }
    return res.exitCode == 0 && res.session?.runId == "R2" && res.session?.sizeText == "1.20GB"
        && res.skipped.count == 4 && !names.contains("/old") && res.notes.isEmpty
}
check("apply: another clean in the same window shows a note, no guessed totals, skip reasons from stderr") {
    let res = apply(applyEnv(oplog: try freshLog(), run: "R3", history: "history-ambiguous.json",
                             stderr: "Kept, needs a permanent delete · 2 items: ~/a, npm cache"))
    return res.session == nil && res.notes == [MoleService.ambiguousRunNote]
        && res.skipped.first?.names == ["~/a", "npm cache"]
}
check("apply: missing operations log is reported, with stderr as the fallback") {
    let missing = scratch.appendingPathComponent("gone.log")
    let res = apply(applyEnv(oplog: missing, run: "R4", rows: nil, stderr: "Kept, needs a permanent delete · 1 item: npm cache"))
    return res.session?.runId == "R4" && res.notes.count == 1 && res.notes[0].contains("could not be read")
        && res.skipped.first?.names == ["npm cache"]
}
check("apply: rotated log (no rows for this run) is reported") {
    let res = apply(applyEnv(oplog: try freshLog(), run: "R5", rows: nil))
    return res.session?.runId == "R5" && res.session!.skipped > 0 && res.notes.first?.contains("no rows for this run") == true
}
check("cancel before the process starts is kept: apply never spawns") {
    let argv = scratch.appendingPathComponent("argv-precancel").path
    let runner = MoleRunner(executable: fake)
    runner.cancel()
    let res = MoleService.runApply(runner: runner, planId: "p1", selectFile: "/tmp/s", trash: true, planSkipped: [],
                                   extraEnvironment: fakeEnv(argv: argv))
    return res.failureNote?.contains("Cancelled before cleaning started") == true && res.session == nil
        && !FileManager.default.fileExists(atPath: argv)
}
check("version probe: bounded, cancellable, and validates the output") {
    let hang = scratch.appendingPathComponent("hang.sh")
    try "#!/bin/bash\nexec sleep 30\n".write(to: hang, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hang.path)
    let t0 = Date()
    guard case .failure(let m) = MoleLocator.check(hang.path, timeout: 1), m.message.contains("did not answer"),
          Date().timeIntervalSince(t0) < 6 else { return false }
    guard case .failure(let m2) = MoleLocator.check("/usr/bin/true"), m2.message.contains("does not look like Mole") else { return false }
    let runner = MoleRunner(executable: hang.path)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { runner.cancel() }
    let t1 = Date()
    guard case .failure(let m3) = MoleLocator.check(hang.path, runner: runner, timeout: 20), m3.message == "Cancelled." else { return false }
    return Date().timeIntervalSince(t1) < 8
}
check("selection file is removed when writing fails") {
    let dir = scratch.appendingPathComponent("selfail")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let s = ReviewState(plan: try plan("tricky.json"))
    struct Boom: Error {}
    do { _ = try s.writeSelectionFile(in: dir, write: { _, _ in throw Boom() }); return false } catch {}
    return try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty
}
check("confirm lists the ticked command names") {
    var s = ReviewState(plan: try plan("tricky.json"))
    guard s.selectedCommandNames == ["npm cache"] else { return false }
    s.toggle("i4")
    return s.selectedCommandNames.isEmpty
}

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("all checks passed")
