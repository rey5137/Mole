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

check("a timeout armed by an earlier run of a runner never stops its next run (version check, then scan)") {
    let r = MoleRunner(executable: "/bin/sleep")
    let first = r.run(arguments: ["0"], timeout: 1)
    let second = r.run(arguments: ["3"])
    return first.exitCode == 0 && second.exitCode == 0 && !second.timedOut
}
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
check("fixtures contain only sample or test home paths (every fixture, purge and installer included)") {
    let urls = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
    let names = Set(urls.map { $0.lastPathComponent })
    guard ["purge-sample.json", "installer-sample.json", "oplog-apply-purge.txt", "oplog-apply-installer.txt"]
        .allSatisfy(names.contains) else { return false }
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
    let r = MoleRunner(executable: fake).run(arguments: MoleService.scanArguments(.clean),
                                             extraEnvironment: fakeEnv(stdout: "tricky.json", stderr: "line one\nline two")) { seen.append($0) }
    let doc = try? PlanDocument.decode(r.stdout)
    return r.exitCode == 0 && r.stderrLines == ["line one", "line two"] && seen == r.stderrLines
        && doc != nil && !String(decoding: r.stdout, as: UTF8.self).contains("line one")
}
check("scan interprets plan, error document, and non-JSON with stderr tail") {
    let ok = MoleService.interpretScan(MoleRunner(executable: fake).run(arguments: MoleService.scanArguments(.clean), extraEnvironment: fakeEnv(stdout: "tricky.json")), command: .clean)
    guard case .plan = ok else { return false }
    let err = MoleService.interpretScan(MoleRunner(executable: fake).run(arguments: MoleService.scanArguments(.clean), extraEnvironment: fakeEnv(stdout: "error.json", exit: 130)), command: .clean)
    guard case .failed(let m) = err, m.hasPrefix("cancelled:") else { return false }
    let junk = MoleService.interpretScan(MoleRunner(executable: fake).run(arguments: MoleService.scanArguments(.clean), extraEnvironment: fakeEnv(stderr: "boom happened", exit: 3)), command: .clean)
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
    let args = MoleService.applyArguments(.clean, planId: "abc123", selectFile: "/tmp/sel", trash: true)
    _ = MoleRunner(executable: fake).run(arguments: args, extraEnvironment: fakeEnv(argv: argv))
    let got = try String(contentsOfFile: argv, encoding: .utf8)
    let argv2 = scratch.appendingPathComponent("argv2").path
    _ = MoleRunner(executable: fake).run(arguments: MoleService.applyArguments(.clean, planId: "abc123", selectFile: "/tmp/sel", trash: false), extraEnvironment: fakeEnv(argv: argv2))
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


// MARK: purge and installer tabs

check("purge fixture decodes: trim row is kind trim, covered by its whole target, never default-selected") {
    let p = try plan("purge-sample.json")
    guard p.command == "purge", let trim = p.allItems.first(where: { $0.isTrim }),
          let whole = p.allItems.first(where: { $0.id == trim.coveredBy }) else { return false }
    let s = ReviewState(plan: p)
    return trim.kind == "trim" && whole.kind == "path" && whole.path == trim.path && !trim.defaultSelected
        && !s.isSelected(trim) && trim.artifact == "target" && trim.age != nil
        && p.allItems.contains(where: { $0.isCloud }) && p.allItems.contains(where: { $0.artifact == "node_modules" })
        && p.allItems.contains(where: { !$0.defaultSelected && !$0.isTrim && $0.age == "<1d" })
}
check("installer fixture decodes with name and type") {
    let p = try plan("installer-sample.json")
    let s = ReviewState(plan: p)
    return p.command == "installer" && p.allItems.count == 3 && p.allItems.allSatisfy { $0.type != nil && $0.name != nil }
        && s.selectedRowCount == 0 && p.allItems.allSatisfy { s.isTickable($0) }
}
check("purge default selection: whole items only, totals match the default-selected rows") {
    let p = try plan("purge-sample.json")
    let s = ReviewState(plan: p)
    let want = p.allItems.filter { $0.defaultSelected && !$0.isCovered }
    return s.selectionIDs() == want.map { $0.id } && s.selectedBytes == want.reduce(0) { $0 + $1.bytes }
}
check("trim ticks on its own: alone sends only the trim; with its whole item only the whole, counted once; unticking the whole restores it") {
    let p = try plan("purge-sample.json")
    var s = ReviewState(plan: p)
    s.selectNone()
    guard let trim = p.allItems.first(where: { $0.kind == "trim" }),
          let whole = p.allItems.first(where: { $0.id == trim.coveredBy }), s.isTickable(trim) else { return false }
    s.toggle(trim.id)
    guard s.selectionIDs() == [trim.id], s.selectedBytes == trim.bytes, s.selectedItems == trim.count,
          s.isSelected(trim), !s.isSelected(whole), s.canClean(now: p.createdAt) else { return false }
    s.toggle(whole.id)
    guard s.selectionIDs() == [whole.id], s.selectedBytes == whole.bytes, s.selectedRowCount == 1,
          s.isSelected(trim), s.isIncludedByParent(trim), !s.isTickable(trim) else { return false }
    s.toggle(trim.id)   // disabled while the whole item is ticked: no effect
    guard s.selectionIDs() == [whole.id] else { return false }
    s.toggle(whole.id)
    guard s.selectionIDs() == [trim.id], s.isSelected(trim), s.selectedBytes == trim.bytes else { return false }
    // A section checkbox ticks whole items, never the trim.
    s.selectNone()
    s.setSection(p.sections[0].id, on: true)
    return s.selectionIDs() == [whole.id] && s.sectionState(p.sections[0]) == .on
}
check("clean covered rows still follow their folder and are sent with it") {
    var s = ReviewState(plan: try plan("tricky.json"))
    let covered = s.plan.allItems[2]
    guard !s.isTickable(covered), s.isSelected(covered), s.selectionIDs() == ["i1", "i2", "i3", "i4"] else { return false }
    s.toggle("i3")   // not tickable: no effect
    s.toggle("i2")
    return !s.isSelected(covered) && s.selectionIDs() == ["i1", "i4"]
}
let unknownKindPlan = """
{"schema": 1, "command": "purge", "plan_id": "u1", "created_at": "2026-11-24T07:00:00Z", "expires_at": "2026-11-24T08:00:00Z",
 "free_bytes": null, "total_bytes": 300, "total_items": 3, "skipped": [], "sections": [{"id": "s", "name": "~/www/x", "bytes": 300, "items": [
  {"id": "i1", "kind": "path", "path": "/Users/sample/www/x/dist", "bytes": 100, "size_known": true, "count": 1, "covered_by": null, "default_selected": true},
  {"id": "i2", "kind": "shrink", "path": "/Users/sample/www/x/build", "bytes": 100, "size_known": true, "count": 1, "covered_by": null, "default_selected": true},
  {"id": "i3", "kind": "command", "name": "npm cache", "command": "npm cache clean", "bytes": 100, "size_known": false, "count": 1, "covered_by": null, "default_selected": true}]}]}
"""
check("an item kind the command does not produce is shown but never ticked, counted or sent") {
    guard case .plan(let p) = try PlanDocument.decode(Data(unknownKindPlan.utf8)) else { return false }
    var s = ReviewState(plan: p)
    let odd = p.allItems.filter { $0.kind != "path" }
    guard s.selectionIDs() == ["i1"], odd.allSatisfy({ !s.isTickable($0) && !s.isSelected($0) }) else { return false }
    s.toggle("i2"); s.toggle("i3")
    s.setSection("s", on: true)
    guard s.selectionIDs() == ["i1"], s.selectedBytes == 100, s.selectedCommandNames.isEmpty,
          s.rows(in: p.sections[0]).count == 3 else { return false }
    let url = try s.writeSelectionFile(in: scratch)
    return try String(contentsOf: url, encoding: .utf8) == "i1\n"
}
check("scan and apply argv per command") {
    var got: [String] = []
    for (cmd, trash) in [(MoleCommand.purge, false), (.installer, true)] {
        let a1 = scratch.appendingPathComponent("argv-scan-\(cmd.rawValue)").path
        _ = MoleRunner(executable: fake).run(arguments: MoleService.scanArguments(cmd), extraEnvironment: fakeEnv(argv: a1))
        let a2 = scratch.appendingPathComponent("argv-apply-\(cmd.rawValue)").path
        _ = MoleRunner(executable: fake).run(arguments: MoleService.applyArguments(cmd, planId: "pid", selectFile: "/tmp/f", trash: trash),
                                             extraEnvironment: fakeEnv(argv: a2))
        got += [try String(contentsOfFile: a1, encoding: .utf8), try String(contentsOfFile: a2, encoding: .utf8)]
    }
    return got == ["purge\n--dry-run\n--json\n", "purge\n--apply\npid\n--select\n/tmp/f\n",
                   "installer\n--dry-run\n--json\n", "installer\n--apply\npid\n--select\n/tmp/f\n--trash\n"]
}
check("a plan made by another command is refused, never loaded") {
    func scan(_ file: String, _ cmd: MoleCommand) -> ScanOutcome {
        MoleService.interpretScan(MoleRunner(executable: fake).run(arguments: MoleService.scanArguments(cmd),
                                                                   extraEnvironment: fakeEnv(stdout: file)), command: cmd)
    }
    guard case .failed(let m) = scan("plan-sample.json", .purge), m.contains("`mo clean`"), m.contains("`mo purge`"),
          case .failed = scan("purge-sample.json", .installer), case .failed = scan("installer-sample.json", .clean),
          case .plan(let p) = scan("purge-sample.json", .purge), p.command == "purge",
          case .plan = scan("installer-sample.json", .installer) else { return false }
    return true
}
func runApply(_ cmd: MoleCommand, _ env: [String: String]) -> ApplyResult {
    MoleService.runApply(cmd, runner: MoleRunner(executable: fake), planId: "p1", selectFile: "/tmp/s", trash: true,
                         planSkipped: [], extraEnvironment: env)
}
check("purge apply result reads the purge session, not a clean or purge-dry-run one in the same window") {
    let res = runApply(.purge, applyEnv(oplog: try freshLog(), run: "RP1", history: "history-purge.json", rows: "oplog-apply-purge.txt"))
    let names = res.skipped.flatMap { $0.names }
    return res.session?.runId == "RP1" && res.session?.command == "purge" && res.session?.sizeText == "905KB"
        && res.skipped.map({ $0.reason }) == ["changed since review", "in use"] && res.notes.isEmpty
        && !names.contains("/Users/sample/www/preview/dist") && !names.contains("/Users/sample/Library/Caches/NotMine")
        && !names.contains("/Users/sample/www/other/dist")
}
check("purge apply with no purge session in the window names purge in its note") {
    let res = runApply(.purge, applyEnv(oplog: try freshLog(), run: "RP2", history: "history.json", rows: nil))
    return res.session == nil && res.notes == [MoleService.ambiguousRunNote(.purge)] && res.notes[0].contains("mo purge")
}
check("installer apply reads its own run by the printed run id, never older or other-command rows") {
    let log = try freshLog("[2026-01-01 00:00:00] [installer] SKIPPED /old (changed since review)\n")
    var env = applyEnv(oplog: log, run: "RI1", history: "history-installer.json", rows: "oplog-apply-installer.txt")
    env["FAKE_MO_PRINT_RUN_ID"] = "1"
    let res = runApply(.installer, env)
    let names = res.skipped.flatMap { $0.names }
    return res.session?.command == "installer" && res.session?.runId == "RI1" && res.session?.trashed == 1
        && res.session?.sizeBytes == 3_000_000 && names == ["/Users/sample/Desktop/Tool Setup.pkg"]
        && res.skipped.map({ $0.reason }) == ["changed since review"] && res.notes.isEmpty
}
check("the printed run id picks its session even when another overlapping session exists") {
    var env = applyEnv(oplog: try freshLog(), run: "R2", history: "history-ambiguous.json")
    env["FAKE_MO_PRINT_RUN_ID"] = "1"
    let res = apply(env)
    return res.session?.runId == "R2" && res.notes.isEmpty
}
check("a printed run id that history does not list is not guessed at") {
    var env = applyEnv(oplog: try freshLog(), run: "R2", history: "history.json")
    env["FAKE_MO_PRINT_RUN_ID"] = "1"
    env["FAKE_MO_HISTORY_FILE"] = fixtures.appendingPathComponent("history-purge.json").path
    let res = apply(env)
    return res.session == nil && res.notes == [MoleService.ambiguousRunNote]
}
check("run id line: parsed from stdout, nothing else counts") {
    func id(_ t: String) -> String? { History.runId(fromOutput: Data(t.utf8)) }
    return id("Run id: 2026-1-2\nmore\n") == "2026-1-2" && id("x\nRun id: abc\n") == "abc"
        && id("") == nil && id("Run id: \n") == nil && id("Run id: a b\n") == nil && id("the Run id: a\n") == nil
}
check("operation rows: exact command only, dry-run and other commands never match") {
    let log = "[2026-11-24 14:50:01] [purge run=A] TRASHED /x (12MB)\n[2026-11-24 14:50:01] [purge-dry-run run=B] SKIPPED /y (z)\n"
        + "[2026-11-24 14:50:01] [purger] SKIPPED /w (z)\n[2026-11-24 14:50:02] [purge] SKIPPED /v/App (copy) (changed since review)\n"
    // log_operation writes `<path> (<detail>)`; details are fixed reasons or sizes with no
    // parentheses, while a path may hold them, so the detail is the last group.
    let rows = OperationRow.parse(log, command: "purge")
    return rows.count == 2 && rows[0].runId == "A" && rows[0].detail == "12MB" && rows[0].subject == "/x"
        && rows[1].runId == nil && rows[1].action == "SKIPPED" && rows[1].subject == "/v/App (copy)"
        && rows[1].detail == "changed since review"
}

check("section box counts a trim as a row: trim alone is mixed; on ticks the whole; off clears the trim too") {
    let p = try plan("purge-sample.json")
    var s = ReviewState(plan: p)
    s.selectNone()
    let rusty = p.sections[0]
    guard let trim = rusty.items.first(where: { $0.isTrim }), s.sectionState(rusty) == .off else { return false }
    s.toggle(trim.id)
    guard s.sectionState(rusty) == .mixed else { return false }
    s.setSection(rusty.id, on: true)
    guard s.sectionState(rusty) == .on, s.isIncludedByParent(trim), s.selectionIDs() == [trim.coveredBy!] else { return false }
    s.setSection(rusty.id, on: false)
    return s.sectionState(rusty) == .off && s.selectionIDs().isEmpty && s.selectedBytes == 0 && !s.isSelected(trim)
}
check("header item counts: purge counts rows (a trim is one row), clean keeps its file counts") {
    let p = try plan("purge-sample.json")
    var s = ReviewState(plan: p)
    s.selectNone()
    let trim = p.allItems.first(where: { $0.isTrim })!
    guard s.itemCounts == (0, 5) else { return false }
    s.toggle(trim.id)
    guard s.itemCounts == (1, 5) else { return false }
    s.toggle(trim.coveredBy!)
    guard s.itemCounts == (1, 5) else { return false }
    s.setSection(p.sections[1].id, on: true)
    let c = ReviewState(plan: try plan("tricky.json"))
    return s.itemCounts == (2, 5) && c.itemCounts == (c.selectedItems, c.plan.totalItems) && c.itemCounts == (7, 7)
}
if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("all checks passed")
