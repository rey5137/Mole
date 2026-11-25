import Foundation
import SwiftUI
import AppKit
import MoleReviewCore

public enum Phase { case idle, scanning, review, applying, result }

/// One line of the live feed as the list draws it; `id` counts up for the whole run, so
/// rows keep their identity when the oldest lines are dropped.
public struct LogEntry: Identifiable, Equatable {
    public let id: Int
    public let line: ProgressLine
}

/// Everything one tab owns: its plan, selection, run log and result. Tabs never
/// share any of it, so ids and plan ids of one command never reach another.
public struct TabState {
    public var phase = Phase.idle
    public var review: ReviewState?
    public var failure: ScanFailure?
    /// What the feed shows (no blank or separator lines), and the same text as printed.
    public var entries: [LogEntry] = []
    public var rawLog: [String] = []
    public var progress = ProgressSummary()
    /// Lines trimmed off the front of `rawLog`.
    public private(set) var rawDropped = 0
    private var nextEntry = 0
    public var startedAt = Date()
    public var useTrash = true
    public var showConfirm = false
    public var result: ApplyResult?
    public var focusedRow: String?
    public init() {}
    public var busy: Bool { phase == .scanning || phase == .applying }

    /// Past this many lines the oldest go; `progress` has counted them all.
    public static let keepLines = 5000

    /// "40001 lines", or "last 5000 of 40001 lines" once the oldest were trimmed.
    public var lineCountText: String {
        rawDropped > 0 ? "last \(rawLog.count) of \(progress.lines) lines" : "\(progress.lines) lines"
    }

    public mutating func resetFeed() {
        entries = []; rawLog = []; rawDropped = 0; progress = ProgressSummary(); nextEntry = 0
    }

    public mutating func append(_ batch: [String]) {
        for text in batch {
            let line = ProgressLine.parse(text)
            progress.add(line)
            rawLog.append(line.raw)
            if line.kind != .blank && line.kind != .rule {
                entries.append(LogEntry(id: nextEntry, line: line))
                nextEntry += 1
            }
        }
        if entries.count > Self.keepLines + 1000 { entries.removeFirst(entries.count - Self.keepLines) }
        if rawLog.count > Self.keepLines + 1000 {
            let drop = rawLog.count - Self.keepLines
            rawLog.removeFirst(drop)
            rawDropped += drop
        }
    }
}

@MainActor
public final class AppModel: ObservableObject {
    @AppStorage("moleCommand") public var moleCommand = ""
    @Published public var command = MoleCommand.clean
    @Published public var tabs: [MoleCommand: TabState] = Dictionary(uniqueKeysWithValues: MoleCommand.allCases.map { ($0, TabState()) })
    @Published public var now = Date()
    @Published public var fullDiskAccess = FullDiskAccess.Status.unknown

    public init() {
        fullDiskAccess = FullDiskAccess.status()
        // The grant is made in System Settings: look again whenever the app comes back to the front.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshFullDiskAccess() }
        }
    }

    public func refreshFullDiskAccess() { fullDiskAccess = FullDiskAccess.status() }

    private var runners: [MoleCommand: MoleRunner] = [:]
    private var batchers: [MoleCommand: LineBatcher] = [:]
    private var ticker: Timer?

    // The shown tab's state, so views read `model.phase` and bind `$model.focusedRow`.
    public var tab: TabState {
        get { tabs[command]! }
        set { tabs[command] = newValue }
    }
    public var phase: Phase { get { tab.phase } set { tab.phase = newValue } }
    public var review: ReviewState? { get { tab.review } set { tab.review = newValue } }
    public var failure: ScanFailure? { get { tab.failure } set { tab.failure = newValue } }
    public var startedAt: Date { get { tab.startedAt } set { tab.startedAt = newValue } }
    public var useTrash: Bool { get { tab.useTrash } set { tab.useTrash = newValue } }
    public var showConfirm: Bool { get { tab.showConfirm } set { tab.showConfirm = newValue } }
    public var result: ApplyResult? { get { tab.result } set { tab.result = newValue } }
    public var focusedRow: String? { get { tab.focusedRow } set { tab.focusedRow = newValue } }

    static let repoRoot: String? = {
        // .../app/MoleReview/Sources/MoleReview/AppModel.swift -> repo root
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("mole").path) ? url.path : nil
    }()

    public var resolvedCommand: String {
        if !moleCommand.trimmingCharacters(in: .whitespaces).isEmpty { return moleCommand }
        return MoleLocator.firstExecutable(MoleLocator.candidates(repoRoot: Self.repoRoot))
            ?? MoleLocator.candidates(repoRoot: Self.repoRoot).first ?? "/opt/homebrew/bin/mo"
    }

    public var busy: Bool { tab.busy }
    public var rawLogIsEmpty: Bool { tab.rawLog.isEmpty }
    /// Mole runs one cleanup at a time: while any tab applies, no tab can.
    public var applyingCommand: MoleCommand? { MoleCommand.allCases.first { tabs[$0]!.phase == .applying } }
    public var canApply: Bool {
        phase == .review && applyingCommand == nil && review?.canClean(now: now) == true
    }
    public var elapsed: TimeInterval { now.timeIntervalSince(startedAt) }

    private func startTicker() {
        now = Date()
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [me = self] _ in
            Task { @MainActor in me.now = Date() }
        }
    }
    /// The ticker keeps running while any tab is busy or in review, so the expiry
    /// countdown and the apply gate stay current.
    private func stopTicker() {
        now = Date()
        guard !tabs.values.contains(where: { $0.busy || $0.phase == .review }) else { return }
        ticker?.invalidate(); ticker = nil
    }

    /// Lines from the reader threads reach the tab in batches (see `LineBatcher`).
    private func makeBatcher(_ cmd: MoleCommand) -> LineBatcher {
        let b = LineBatcher { [me = self] in Task { @MainActor in me.flush(cmd) } }
        batchers[cmd] = b
        return b
    }

    private func flush(_ cmd: MoleCommand) {
        guard let lines = batchers[cmd]?.drain(), !lines.isEmpty else { return }
        tabs[cmd]!.append(lines)
    }

    public func scan() {
        guard !busy else { return }
        let cmd = command
        let path = resolvedCommand
        tab.phase = .scanning; tab.failure = nil; tab.resetFeed(); tab.review = nil; tab.result = nil
        tab.focusedRow = nil; tab.startedAt = Date()
        startTicker()
        let r = MoleRunner(executable: path)
        runners[cmd] = r
        let batcher = makeBatcher(cmd)
        DispatchQueue.global().async { [me = self] in
            let outcome: ScanOutcome
            switch MoleLocator.check(path, runner: r) {
            case .failure(let e): outcome = r.isCancelled ? .cancelled : .failed(ScanFailure(e))
            case .success:
                // A scan's stdout is the JSON plan; its progress text is on stderr.
                let res = r.run(arguments: MoleService.scanArguments(cmd), onStderrLine: { batcher.add($0) })
                outcome = MoleService.interpretScan(res, command: cmd)
            }
            Task { @MainActor [outcome] in me.finishScan(cmd, outcome) }
        }
    }

    private func finishScan(_ cmd: MoleCommand, _ o: ScanOutcome) {
        flush(cmd)
        batchers[cmd] = nil
        runners[cmd] = nil
        var t = tabs[cmd]!
        switch o {
        case .plan(let p): t.review = ReviewState(plan: p); t.phase = .review
        case .failed(let f): t.failure = f; t.phase = .idle
        case .cancelled: t.failure = .cancelled; t.phase = .idle
        }
        tabs[cmd] = t
        stopTicker()
    }

    public func cancel() { runners[command]?.cancel() }

    public func apply() {
        now = Date()   // expiry is checked against the clock, never a stale tick
        guard canApply, var state = review, state.plan.command == command.rawValue else { return }
        let cmd = command
        let path = resolvedCommand
        let trash = useTrash
        let planSkipped = state.plan.skipped
        let planId = state.plan.planId
        state.searchText = ""
        let file: URL
        do { file = try state.writeSelectionFile() } catch {
            tab.failure = ScanFailure(.other, "Could not write the selection file. Nothing was removed.",
                                      details: error.localizedDescription)
            tab.showConfirm = false
            return
        }
        tab.showConfirm = false
        tab.phase = .applying; tab.resetFeed(); tab.failure = nil; tab.startedAt = Date()
        startTicker()
        let r = MoleRunner(executable: path)
        runners[cmd] = r
        let batcher = makeBatcher(cmd)
        DispatchQueue.global().async { [me = self] in
            // An apply prints its progress on stdout (and any error on stderr); both feed the log.
            let out = MoleService.runApply(cmd, runner: r, planId: planId, selectFile: file.path, trash: trash,
                                           planSkipped: planSkipped, onStderrLine: { batcher.add($0) },
                                           onStdoutLine: { batcher.add($0) })
            try? FileManager.default.removeItem(at: file)
            Task { @MainActor [out] in me.finishApply(cmd, out) }
        }
    }

    private func finishApply(_ cmd: MoleCommand, _ r: ApplyResult) {
        flush(cmd)
        batchers[cmd] = nil
        runners[cmd] = nil
        tabs[cmd]!.result = r; tabs[cmd]!.phase = .result
        stopTicker()
    }

    public func toggleFocused() {
        guard let id = focusedRow, let item = review?.plan.allItems.first(where: { $0.id == id }),
              review?.isTickable(item) == true else { return }
        review?.toggle(id)
    }
}
