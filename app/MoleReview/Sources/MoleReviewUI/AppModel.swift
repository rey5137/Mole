import Foundation
import SwiftUI
import MoleReviewCore

public enum Phase { case idle, scanning, review, applying, result }

@MainActor
public final class AppModel: ObservableObject {
    @AppStorage("moleCommand") public var moleCommand = ""
    @Published public var phase = Phase.idle
    @Published public var review: ReviewState?
    @Published public var errorText: String?
    @Published public var log: [String] = []
    @Published public var startedAt = Date()
    @Published public var now = Date()
    @Published public var useTrash = true
    @Published public var showConfirm = false
    @Published public var result: ApplyResult?
    @Published public var focusedRow: String?

    public init() {}

    private var runner: MoleRunner?
    private var ticker: Timer?

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

    public var busy: Bool { phase == .scanning || phase == .applying }
    public var elapsed: TimeInterval { now.timeIntervalSince(startedAt) }

    private func startTicker() {
        startedAt = Date(); now = startedAt
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [me = self] _ in
            Task { @MainActor in me.now = Date() }
        }
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil; now = Date() }

    public func scan() {
        guard !busy else { return }
        let path = resolvedCommand
        phase = .scanning; errorText = nil; log = []; review = nil; result = nil
        startTicker()
        let r = MoleRunner(executable: path)
        runner = r
        DispatchQueue.global().async { [me = self] in
            let outcome: ScanOutcome
            switch MoleLocator.check(path, runner: r) {
            case .failure(let e): outcome = r.isCancelled ? .cancelled : .failed(e.message)
            case .success:
                let res = r.run(arguments: MoleService.scanArguments) { line in
                    Task { @MainActor in me.log.append(line) }
                }
                outcome = MoleService.interpretScan(res)
            }
            Task { @MainActor [outcome] in me.finishScan(outcome) }
        }
    }

    private func finishScan(_ o: ScanOutcome) {
        stopTicker(); runner = nil
        switch o {
        case .plan(let p): review = ReviewState(plan: p); phase = .review
        case .failed(let m): errorText = m; phase = .idle
        case .cancelled: errorText = "Scan cancelled."; phase = .idle
        }
    }

    public func cancel() { runner?.cancel() }

    public func apply() {
        guard var state = review, state.canClean(now: Date()), phase == .review else { return }
        let path = resolvedCommand
        let trash = useTrash
        let planSkipped = state.plan.skipped
        let planId = state.plan.planId
        state.searchText = ""
        let file: URL
        do { file = try state.writeSelectionFile() } catch {
            errorText = "Could not write the selection file: \(error.localizedDescription)"; return
        }
        showConfirm = false
        phase = .applying; log = []; errorText = nil
        startTicker()
        let r = MoleRunner(executable: path)
        runner = r
        DispatchQueue.global().async { [me = self] in
            let out = MoleService.runApply(runner: r, planId: planId, selectFile: file.path, trash: trash,
                                           planSkipped: planSkipped) { line in
                Task { @MainActor in me.log.append(line) }
            }
            try? FileManager.default.removeItem(at: file)
            Task { @MainActor [out] in me.finishApply(out) }
        }
    }

    private func finishApply(_ r: ApplyResult) {
        stopTicker(); runner = nil
        result = r; phase = .result
    }

    public func toggleFocused() {
        guard let id = focusedRow, review?.plan.allItems.first(where: { $0.id == id })?.isCovered == false else { return }
        review?.toggle(id)
    }
}
