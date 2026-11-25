import Foundation

public enum MoleLocator {
    /// Default places to look, in order. `repoRoot` is the checkout the app
    /// source lives in (its `mole` script), when there is one.
    public static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  repoRoot: String?, home: String = NSHomeDirectory()) -> [String] {
        var out: [String] = []
        if let p = environment["MOLE_PATH"], !p.isEmpty { out.append(p) }
        if let r = repoRoot { out.append(r + "/mole") }
        out += ["/opt/homebrew/bin/mo", "/usr/local/bin/mo", home + "/.local/bin/mo"]
        return out
    }

    public static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs `<path> --version` through `runner` (so Cancel reaches it), stopped after
    /// `timeout`. The output must start with "Mole" (`mole --version` prints
    /// `Mole version X`); any other program that exits 0 is refused.
    public static func check(_ path: String, runner: MoleRunner? = nil, timeout: TimeInterval = 10) -> Result<String, MoleError> {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return .failure(MoleError("Mole not found at \(path). Set the path in Settings."))
        }
        let r = (runner ?? MoleRunner(executable: path)).run(arguments: ["--version"], timeout: timeout)
        if r.cancelled { return .failure(MoleError("Cancelled.")) }
        if r.timedOut { return .failure(MoleError("\(path) --version did not answer within \(Int(timeout)) s. Set the path in Settings.")) }
        guard r.launchError == nil, r.exitCode == 0 else {
            return .failure(MoleError("\(path) --version failed (exit \(r.exitCode)). Set the path in Settings."))
        }
        let line = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        guard line.hasPrefix("Mole") else {
            return .failure(MoleError("\(path) does not look like Mole (--version printed \"\(line.prefix(60))\"). Set the path in Settings."))
        }
        return .success(line)
    }
}

public struct MoleError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

public enum ScanOutcome: Equatable {
    case plan(Plan)
    case failed(String)
    case cancelled
}

public enum MoleService {
    public static func scanArguments(_ command: MoleCommand) -> [String] {
        [command.rawValue, "--dry-run", "--json"]
    }

    public static func applyArguments(_ command: MoleCommand, planId: String, selectFile: String, trash: Bool) -> [String] {
        [command.rawValue, "--apply", planId, "--select", selectFile] + (trash ? ["--trash"] : [])
    }

    /// A plan made by another command is refused: its ids name another command's items.
    public static func interpretScan(_ r: RunResult, command: MoleCommand) -> ScanOutcome {
        if let e = r.launchError { return .failed(e) }
        if r.cancelled { return .cancelled }
        switch try? PlanDocument.decode(r.stdout) {
        case .plan(let p)?:
            guard p.command == command.rawValue else { return .failed(planMismatch(p.command, command)) }
            return .plan(p)
        case .error(let e)?: return .failed("\(e.code): \(e.message)")
        case nil:
            let tail = r.stderrTail
            return .failed("Mole printed no plan (exit \(r.exitCode))." + (tail.isEmpty ? "" : "\n" + tail))
        }
    }

    public static func planMismatch(_ got: String, _ want: MoleCommand) -> String {
        "Mole printed a plan for `mo \(got.isEmpty ? "?" : got)`, not `mo \(want.rawValue)`, so it was not loaded. Nothing was removed."
    }
}

// MARK: history and the apply result

public struct ApplyResult {
    public var exitCode: Int32
    public var session: HistorySession?
    public var skipped: [SkippedGroup]
    public var failureNote: String?
    /// Things the result view must say: an ambiguous run, unavailable skip reasons.
    public var notes: [String]
    public init(exitCode: Int32, session: HistorySession?, skipped: [SkippedGroup], failureNote: String?, notes: [String] = []) {
        self.exitCode = exitCode; self.session = session; self.skipped = skipped
        self.failureNote = failureNote; self.notes = notes
    }
}

extension MoleService {
    public static let ambiguousRunNote = ambiguousRunNote(.clean)
    public static func ambiguousRunNote(_ command: MoleCommand) -> String {
        "Couldn't tell this run apart from another mo \(command.rawValue), so no totals are shown."
    }

    /// Runs `--apply` (never retried), then reads what happened. `--apply` prints its
    /// own run id (`Run id: <id>`, log.sh `log_operation_print_run_id`), and the history
    /// session is the one of `command` with that `run_id`. An older mo prints none; then
    /// the session is the one real session of `command` (never its `-dry-run` preview,
    /// never another command) that started after the process was spawned and ended
    /// before it exited. None or several shows a note instead of a guess, with skip
    /// reasons from the run's own output. With a session, its `run_id` selects the rows
    /// of the operations log named by `history --json`.
    public static func runApply(_ command: MoleCommand = .clean, runner: MoleRunner, planId: String, selectFile: String,
                                trash: Bool, planSkipped: [SkippedEntry], extraEnvironment: [String: String] = [:],
                                onStderrLine: ((String) -> Void)? = nil) -> ApplyResult {
        let res = runner.run(arguments: applyArguments(command, planId: planId, selectFile: selectFile, trash: trash),
                             extraEnvironment: extraEnvironment, onStderrLine: onStderrLine)
        if res.spawnedAt == nil {
            let why = res.launchError ?? "Cancelled before cleaning started; nothing was cleaned."
            return ApplyResult(exitCode: res.exitCode, session: nil, skipped: [], failureNote: why)
        }
        let hist = MoleRunner(executable: runner.executable).run(arguments: ["history", "--json"],
                                                                  extraEnvironment: extraEnvironment, timeout: 30)
        let spawnedAt = res.spawnedAt!, exitedAt = res.exitedAt ?? Date()
        var notes: [String] = []
        var groups: [SkippedGroup]
        let fromOutput = SkippedReport.group(stderr: res.stderrLines, planSkipped: planSkipped)
        let logPath = History.operationsLogPath(from: hist.stdout)
        let logText = logPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }.map { String(decoding: $0, as: UTF8.self) }
        let all = History.sessions(from: hist.stdout)
        // The run names itself (`Run id: <id>`); an older mo prints nothing, so the window decides.
        // A named run that history does not list is not guessed at.
        let session: HistorySession?
        if let id = History.runId(fromOutput: res.stdout) {
            session = all.first { $0.command == command.rawValue && $0.runId == id }
        } else {
            session = History.attributed(all, command: command.rawValue, spawnedAt: spawnedAt, exitedAt: exitedAt)
        }
        if let session, !session.runId.isEmpty {
            if let logText {
                let rows = SkippedReport.rows(operationLog: logText, command: command.rawValue, runId: session.runId)
                if rows.isEmpty && session.skipped > 0 {
                    notes.append("The operations log has no rows for this run (rotated?), so skip reasons come from the run's output.")
                    groups = fromOutput
                } else {
                    groups = SkippedReport.group(rows: rows, planSkipped: planSkipped)
                }
            } else {
                notes.append("The operations log (\(logPath ?? "path unknown")) could not be read, so skip reasons come from the run's output.")
                groups = fromOutput
            }
        } else {
            if session == nil { notes.append(ambiguousRunNote(command)) }
            groups = fromOutput
        }
        let note = res.launchError ?? (res.cancelled ? "Cancelled; some items may already be cleaned." : nil)
        return ApplyResult(exitCode: res.exitCode, session: session, skipped: groups, failureNote: note, notes: notes)
    }
}

public struct HistorySession: Equatable {
    public let command: String
    public let runId: String
    public let startedAt: Date?
    public let items: Int
    public let sizeText: String
    public let endedAt: Date?
    /// `sizeText` (`1.20GB`) in bytes, so the result uses the same formatter as the rest of the app.
    public var sizeBytes: Int64? { History.parseSize(sizeText) }
    public let removed: Int
    public let trashed: Int
    public let skipped: Int
    public let failed: Int
    public init(command: String, runId: String, startedAt: Date?, endedAt: Date? = nil, items: Int, sizeText: String,
                removed: Int, trashed: Int, skipped: Int, failed: Int) {
        self.command = command; self.runId = runId; self.startedAt = startedAt; self.endedAt = endedAt; self.items = items
        self.sizeText = sizeText; self.removed = removed; self.trashed = trashed; self.skipped = skipped; self.failed = failed
    }
}

public enum History {
    static func parseTime(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }

    public static func sessions(from data: Data) -> [HistorySession] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["sessions"] as? [[String: Any]] else { return [] }
        return list.map { s in
            let a = s["actions"] as? [String: Any] ?? [:]
            return HistorySession(
                command: s["command"] as? String ?? "",
                runId: s["run_id"] as? String ?? "",
                startedAt: (s["started_at"] as? String).flatMap(parseTime),
                endedAt: (s["ended_at"] as? String).flatMap(parseTime),
                items: s["items"] as? Int ?? 0, sizeText: s["size"] as? String ?? "",
                removed: a["removed"] as? Int ?? 0, trashed: a["trashed"] as? Int ?? 0,
                skipped: a["skipped"] as? Int ?? 0, failed: a["failed"] as? Int ?? 0)
        }
    }

    /// `logs.operations` of `mo history --json`: where operation rows are written
    /// (history.sh `history_render_json`).
    public static func operationsLogPath(from data: Data) -> String? {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["logs"] as? [String: Any])?["operations"] as? String
    }

    /// The one real session of `command` that started after `spawnedAt` and ended before
    /// `exitedAt` (history times have whole-second resolution, so the window is widened
    /// to whole seconds). The command must match exactly: a session field is
    /// `<command>` for a real run and `<command>-dry-run` for a preview (log.sh
    /// `operation_log_command`). Nil when none or more than one qualifies.
    public static func attributed(_ sessions: [HistorySession], command: String = "clean",
                                  spawnedAt: Date, exitedAt: Date) -> HistorySession? {
        let hits = sessions.filter { s in
            guard s.command == command, let a = s.startedAt, let b = s.endedAt else { return false }
            return inWindow(a, spawnedAt: spawnedAt, exitedAt: exitedAt) && inWindow(b, spawnedAt: spawnedAt, exitedAt: exitedAt)
        }
        return hits.count == 1 ? hits[0] : nil
    }

    public static func inWindow(_ t: Date, spawnedAt: Date, exitedAt: Date) -> Bool {
        let s = t.timeIntervalSince1970
        return s >= spawnedAt.timeIntervalSince1970.rounded(.down) && s <= exitedAt.timeIntervalSince1970.rounded(.up)
    }

    /// The id of the `Run id: <id>` line a reviewed `--apply` prints on stdout; nil when
    /// there is none (an older mo, or MO_NO_OPLOG=1).
    public static func runId(fromOutput data: Data) -> String? {
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Run id: ") {
                let id = t.dropFirst("Run id: ".count)
                if !id.isEmpty, !id.contains(where: { $0.isWhitespace }) { return String(id) }
            }
        }
        return nil
    }

    /// `1.20GB`, `512KB`, `3B` (history.sh's size text; decimal units like ByteCountFormatter's file style).
    public static func parseSize(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^[0-9]+(\.[0-9]+)?"#, options: .regularExpression), let v = Double(t[r]) else { return nil }
        let unit = t[r.upperBound...].trimmingCharacters(in: .whitespaces).uppercased()
        let mult: [String: Double] = ["B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12]
        guard let m = mult[unit] else { return nil }
        return Int64(v * m)
    }
}

/// One row of the operations log written by `command` (exactly; never its
/// `-dry-run` preview): `[<timestamp>] [<command>( run=<id>)?] <ACTION> <rest>`,
/// where `rest` ends in ` (<detail>)` when the row has one.
public struct OperationRow: Equatable {
    public let time: Date
    public let runId: String?
    public let action: String
    public let subject: String
    public let detail: String?

    /// SKIPPED rows as (reason, name).
    public var skipped: (reason: String, name: String)? { detail.map { ($0, subject) } }

    public static func parse(_ log: String, command: String) -> [OperationRow] {
        let cmd = NSRegularExpression.escapedPattern(for: command)
        let row = try! NSRegularExpression(pattern: #"^\[([^\]]*)\] \["# + cmd + #"(?: run=([^\]\s]+))?\] ([A-Z_]+) (.+)$"#)
        let tail = try! NSRegularExpression(pattern: #"^(.+) \(([^()]*)\)$"#)
        var out: [OperationRow] = []
        for line in log.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let m = row.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let time = History.parseTime(ns.substring(with: m.range(at: 1))) else { continue }
            let id = m.range(at: 2).location == NSNotFound ? nil : ns.substring(with: m.range(at: 2))
            let rest = ns.substring(with: m.range(at: 4)) as NSString
            var subject = rest as String, detail: String?
            if let t = tail.firstMatch(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
                subject = rest.substring(with: t.range(at: 1)); detail = rest.substring(with: t.range(at: 2))
            }
            out.append(OperationRow(time: time, runId: id, action: ns.substring(with: m.range(at: 3)),
                                    subject: subject, detail: detail))
        }
        return out
    }
}

public struct SkippedGroup: Equatable {
    public let reason: String
    public let names: [String]
    public init(reason: String, names: [String]) { self.reason = reason; self.names = names }
}

public enum SkippedReport {
    public static let sudoHint = "run `mo clean` in Terminal for system caches"

    /// Skip reasons of one apply run, from its operation-log rows. Row grammar,
    /// log.sh:336-340 (`log_operation`) with the command field from
    /// log.sh:303-310 (`operation_log_command`):
    ///   `[<timestamp>] [<command> run=<run id>] SKIPPED <path or name> (<reason>)`
    /// A dry run writes `<command>-dry-run run=<id>` and is never counted, nor is
    /// another command's row. Reasons come from file_ops.sh:1654/1661/1674/1678/1688
    /// ("not in reviewed plan", "changed since review", "holds unticked item"), :1705
    /// and :1733 (same refusals, logged SKIPPED), :1777 ("needs permanent delete"
    /// under --trash) and :1791 ("already in Trash"). `runId` (the matched history
    /// session's `run_id`) keeps other runs' rows out; without one, every real
    /// `command` row in `operationLog` counts, so pass only the rows appended since
    /// the apply started.
    public static func group(operationLog: String, command: String = "clean", runId: String? = nil,
                             planSkipped: [SkippedEntry]) -> [SkippedGroup] {
        group(rows: rows(operationLog: operationLog, command: command, runId: runId), planSkipped: planSkipped)
    }

    public static func rows(operationLog: String, command: String = "clean", runId: String?) -> [(reason: String, name: String)] {
        OperationRow.parse(operationLog, command: command).compactMap { r in
            guard r.action == "SKIPPED", let s = r.skipped else { return nil }
            if let want = runId, !want.isEmpty, r.runId != want { return nil }
            return s
        }
    }

    /// Fallback when the log is unusable: the run's own summary line, bin/clean.sh:2263,
    /// `Kept, needs a permanent delete · N items: a, b, c, +K more` (names from
    /// `format_clean_summary_list`, clean.sh:2297-2309: at most three, `~` for home).
    public static func group(stderr lines: [String], planSkipped: [SkippedEntry]) -> [SkippedGroup] {
        var rows: [(reason: String, name: String)] = []
        for line in lines {
            guard let r = line.range(of: "Kept, needs a permanent delete"),
                  let colon = line[r.upperBound...].range(of: ": ") else { continue }
            for n in line[colon.upperBound...].components(separatedBy: ", ") { rows.append(("needs permanent delete", n)) }
        }
        return group(rows: rows, planSkipped: planSkipped)
    }

    public static func group(rows: [(reason: String, name: String)], planSkipped: [SkippedEntry]) -> [SkippedGroup] {
        var order: [String] = []
        var map: [String: [String]] = [:]
        func add(_ reason: String, _ name: String) {
            if map[reason] == nil { order.append(reason) }
            map[reason, default: []].append(name)
        }
        for r in rows { add(r.reason, r.name) }
        for s in planSkipped { add(s.reason == "needs sudo" ? "needs sudo: " + sudoHint : s.reason, s.name) }
        return order.map { SkippedGroup(reason: $0, names: map[$0]!) }
    }
}
