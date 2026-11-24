import Foundation
import SwiftUI
import MoleReviewCore

public enum Phase { case idle, scanning, review, applying, result }

/// Everything one tab owns: its plan, selection, run log and result. Tabs never
/// share any of it, so ids and plan ids of one command never reach another.
public struct TabState {
    public var phase = Phase.idle
    public var review: ReviewState?
    public var errorText: String?
    public var log: [String] = []
    public var startedAt = Date()
    public var useTrash = true
    public var showConfirm = false
    public var result: ApplyResult?
    public var focusedRow: String?
    public init() {}
    public var busy: Bool { phase == .scanning || phase == .applying }
}

@MainActor
public final class AppModel: ObservableObject {
    @AppStorage("moleCommand") public var moleCommand = ""
    @Published public var command = MoleCommand.clean
    @Published public var tabs: [MoleCommand: TabState] = Dictionary(uniqueKeysWithValues: MoleCommand.allCases.map { ($0, TabState()) })
    @Published public var now = Date()

    public init() {}

    private var runners: [MoleCommand: MoleRunner] = [:]
    private var ticker: Timer?

    // The shown tab's state, so views read `model.phase` and bind `$model.focusedRow`.
    public var tab: TabState {
        get { tabs[command]! }
        set { tabs[command] = newValue }
    }
    public var phase: Phase { get { tab.phase } set { tab.phase = newValue } }
    public var review: ReviewState? { get { tab.review } set { tab.review = newValue } }
    public var errorText: String? { get { tab.errorText } set { tab.errorText = newValue } }
    public var log: [String] { get { tab.log } set { tab.log = newValue } }
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

    public func scan() {
        guard !busy else { return }
        let cmd = command
        let path = resolvedCommand
        tab.phase = .scanning; tab.errorText = nil; tab.log = []; tab.review = nil; tab.result = nil
        tab.focusedRow = nil; tab.startedAt = Date()
        startTicker()
        let r = MoleRunner(executable: path)
        runners[cmd] = r
        DispatchQueue.global().async { [me = self] in
            let outcome: ScanOutcome
            switch MoleLocator.check(path, runner: r) {
            case .failure(let e): outcome = r.isCancelled ? .cancelled : .failed(e.message)
            case .success:
                let res = r.run(arguments: MoleService.scanArguments(cmd)) { line in
                    Task { @MainActor in me.tabs[cmd]!.log.append(line) }
                }
                outcome = MoleService.interpretScan(res, command: cmd)
            }
            Task { @MainActor [outcome] in me.finishScan(cmd, outcome) }
        }
    }

    private func finishScan(_ cmd: MoleCommand, _ o: ScanOutcome) {
        runners[cmd] = nil
        var t = tabs[cmd]!
        switch o {
        case .plan(let p): t.review = ReviewState(plan: p); t.phase = .review
        case .failed(let m): t.errorText = m; t.phase = .idle
        case .cancelled: t.errorText = "Scan cancelled."; t.phase = .idle
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
            tab.errorText = "Could not write the selection file: \(error.localizedDescription)"; return
        }
        tab.showConfirm = false
        tab.phase = .applying; tab.log = []; tab.errorText = nil; tab.startedAt = Date()
        startTicker()
        let r = MoleRunner(executable: path)
        runners[cmd] = r
        DispatchQueue.global().async { [me = self] in
            let out = MoleService.runApply(cmd, runner: r, planId: planId, selectFile: file.path, trash: trash,
                                           planSkipped: planSkipped) { line in
                Task { @MainActor in me.tabs[cmd]!.log.append(line) }
            }
            try? FileManager.default.removeItem(at: file)
            Task { @MainActor [out] in me.finishApply(cmd, out) }
        }
    }

    private func finishApply(_ cmd: MoleCommand, _ r: ApplyResult) {
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
