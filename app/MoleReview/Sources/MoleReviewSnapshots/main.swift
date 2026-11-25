import AppKit
import SwiftUI
import MoleReviewCore
import MoleReviewUI

// `swift run MoleReviewSnapshots <outdir>`: renders each app state with the sample
// plan through ImageRenderer, light and dark. Exits 1 when an image fails or is blank.

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: MoleReviewSnapshots <outdir>\n".utf8)); exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
_ = NSApplication.shared

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")
func loadPlan(_ name: String) -> Plan {
    guard let data = try? Data(contentsOf: fixtures.appendingPathComponent(name)),
          case .plan(let p)? = try? PlanDocument.decode(data) else { print("\(name) is not a plan"); exit(1) }
    return p
}
let plan = loadPlan("plan-sample.json")
let purgePlan = loadPlan("purge-sample.json")
let installerPlan = loadPlan("installer-sample.json")

@MainActor func model(_ phase: Phase, _ command: MoleCommand = .clean, _ setup: (AppModel) -> Void = { _ in }) -> AppModel {
    let m = AppModel()
    m.command = command
    m.phase = phase
    m.fullDiskAccess = .denied
    m.now = plan.createdAt.addingTimeInterval(600)
    m.startedAt = plan.createdAt.addingTimeInterval(540)
    setup(m)
    return m
}

@MainActor func reviewState(_ m: AppModel, search: String = "") {
    var s = ReviewState(plan: plan)
    for item in plan.allItems.filter({ !$0.isCovered && $0.defaultSelected }).enumerated() where item.offset % 5 == 3 {
        s.toggle(item.element.id)
    }
    s.searchText = search
    m.review = s
}

/// Purge: the default selection plus the Rust trim ticked alone; `whole` ticks its
/// target too, so the trim shows as included.
@MainActor func purgeState(_ m: AppModel, whole: Bool = false) {
    var s = ReviewState(plan: purgePlan)
    if let trim = purgePlan.allItems.first(where: { $0.isTrim }) {
        s.toggle(trim.id)
        if whole, let parent = trim.coveredBy { s.toggle(parent) }
    }
    m.review = s
}

@MainActor func installerState(_ m: AppModel) {
    var s = ReviewState(plan: installerPlan)
    if let first = installerPlan.allItems.first(where: { $0.type == "dmg" }) { s.toggle(first.id) }
    m.review = s
}

func lines(_ file: String) -> [String] {
    guard let text = try? String(contentsOf: fixtures.appendingPathComponent(file), encoding: .utf8) else { print("no \(file)"); exit(1) }
    return text.components(separatedBy: "\n").dropLast()
}
let cleanLog = lines("progress-clean.txt")
let cleanScanLog = Array(cleanLog.prefix(18))
let purgeLog = ["○ DRY RUN MODE, No project artifacts will be removed", "", "Purge Project Artifacts", "",
                "➤ ~/projects", "  ○ node_modules · sample-web, 312.4MB", "  ○ target · sample-cli, 1.84GB",
                "  ○ dist · sample-site, 42.1MB", "➤ ~/work", "  ○ .venv · sample-api, 218.0MB", "  ○ build · sample-app, 96.5MB"]
let installerLog = ["○ DRY RUN MODE, No installer files will be removed", "", "➤ Downloads",
                    "  ○ Sample Setup.dmg · 1.2GB", "  ○ Tool Installer.pkg · 84.0MB", "➤ Desktop", "  ○ sample.iso · 3.1GB"]
let applyClean = ["Run id: 2026-11-25-0001", "Clean Your Mac", "", "➤ User essentials", "  ✓ Trash · 341 items, 120.4MB",
                  "➤ App caches", "  ✓ Sample media cache · 2608 items, 273.2MB", "  ✓ Sample helper cache · 602.4MB",
                  "  ◎ Sample locked cache · skipped, changed since review", "➤ Developer tools", "  ✓ npm cache · cleaned",
                  "  ✓ Homebrew cleanup · 118.8MB"]
let applyPurge = ["Run id: 2026-11-25-0002", "➤ ~/projects", "  ✓ node_modules · sample-web, 312.4MB",
                  "  ✓ target · sample-cli, 1.84GB", "➤ ~/work", "  ✓ .venv · sample-api, 218.0MB"]
let applyInstaller = ["Run id: 2026-11-25-0003", "Files to be removed:", "  ✓ Sample Setup.dmg · 1.2GB", "  ✓ Tool Installer.pkg · 84.0MB"]
let session = HistorySession(command: "clean", runId: "r", startedAt: nil, items: 31, sizeText: "1.20GB",
                             removed: 4, trashed: 24, skipped: 3, failed: 0)

struct Shot { let name: String; var width: CGFloat = 1000; var height: CGFloat = 680; let make: @MainActor (Bool) -> AnyView }
@MainActor func wrapped<V: View>(_ m: AppModel, dark: Bool, width: CGFloat = 1000, height: CGFloat = 680, _ v: V) -> AnyView {
    AnyView(v.environmentObject(m)
        .environment(\.renderStandIn, true)
        .environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: width, height: height)
        .background(dark ? Color(white: 0.14) : Color(white: 0.94)))
}
@MainActor func dark(_ d: Bool) -> Color { d ? Color(white: 0.14) : Color(white: 0.94) }

@MainActor func feed(_ m: AppModel, _ lines: [String]) { m.tabs[m.command]!.append(lines) }
/// A scan that found nothing (one skipped entry, as a Mac without Full Disk Access shows).
@MainActor func emptyPlan(_ m: AppModel, _ cmd: MoleCommand) {
    let f = ISO8601DateFormatter()
    let json = """
    {"schema":1,"command":"\(cmd.rawValue)","plan_id":"empty1","created_at":"\(f.string(from: plan.createdAt))",
     "expires_at":"\(f.string(from: plan.expiresAt))","free_bytes":25950000000,"total_bytes":0,"total_items":0,
     "sections":[],"skipped":[{"section":"User essentials","name":"Trash","reason":"grant Full Disk Access"}]}
    """
    guard case .plan(let p)? = try? PlanDocument.decode(Data(json.utf8)) else { print("empty plan does not decode"); exit(1) }
    m.review = ReviewState(plan: p)
}
func resultOf(_ cmd: MoleCommand) -> ApplyResult {
    let skipped: [SkippedGroup]
    switch cmd {
    case .clean:
        skipped = [SkippedGroup(reason: "changed since review", names: ["~/Library/Caches/Example"]),
                   SkippedGroup(reason: "needs permanent delete", names: ["npm cache clean", "docker builder prune"]),
                   SkippedGroup(reason: "needs sudo: " + SkippedReport.sudoHint, names: ["System caches"])]
    case .purge: skipped = [SkippedGroup(reason: "in use", names: ["~/work/sample-api/.venv"])]
    case .installer: skipped = []
    }
    return ApplyResult(exitCode: 0, session: HistorySession(command: cmd.rawValue, runId: "r", startedAt: nil,
                       items: cmd == .clean ? 31 : 3, sizeText: cmd == .clean ? "1.20GB" : "2.40GB",
                       removed: cmd == .clean ? 4 : 0, trashed: cmd == .clean ? 24 : 3, skipped: skipped.reduce(0) { $0 + $1.names.count },
                       failed: 0), skipped: skipped, failureNote: nil)
}

/// The same set of states for each command.
func perCommand(_ cmd: MoleCommand, _ prefix: String) -> [Shot] {
    let scanLog = cmd == .clean ? cleanScanLog : cmd == .purge ? purgeLog : installerLog
    let applyLog = cmd == .clean ? applyClean : cmd == .purge ? applyPurge : applyInstaller
    @MainActor func review(_ m: AppModel) {
        switch cmd {
        case .clean: reviewState(m)
        case .purge: purgeState(m)
        case .installer: installerState(m)
        }
    }
    return [
        Shot(name: "\(prefix)-idle") { d in wrapped(model(.idle, cmd), dark: d, ContentView()) },
        Shot(name: "\(prefix)-idle-granted") { d in wrapped(model(.idle, cmd) { $0.fullDiskAccess = .granted }, dark: d, ContentView()) },
        Shot(name: "\(prefix)-scanning") { d in wrapped(model(.scanning, cmd) { feed($0, scanLog) }, dark: d, ContentView()) },
        Shot(name: "\(prefix)-review") { d in wrapped(model(.review, cmd) { review($0) }, dark: d, ContentView()) },
        Shot(name: "\(prefix)-review-log") { d in wrapped(model(.review, cmd) { review($0); feed($0, scanLog) }, dark: d, ContentView()) },
        Shot(name: "\(prefix)-confirm") { d in wrapped(model(.review, cmd) { review($0) }, dark: d, ConfirmSheet().background(dark(d))) },
        Shot(name: "\(prefix)-applying") { d in wrapped(model(.applying, cmd) { feed($0, applyLog) }, dark: d, ContentView()) },
        Shot(name: "\(prefix)-result") { d in
            wrapped(model(.result, cmd) { $0.result = resultOf(cmd); feed($0, applyLog) }, dark: d, ContentView())
        },
        Shot(name: "\(prefix)-empty") { d in wrapped(model(.review, cmd) { emptyPlan($0, cmd) }, dark: d, ContentView()) },
        Shot(name: "\(prefix)-review-min", width: 760, height: 520) { d in
            wrapped(model(.review, cmd) { review($0) }, dark: d, width: 760, height: 520, ContentView())
        },
    ]
}

let shots: [Shot] = perCommand(.clean, "clean") + perCommand(.purge, "purge") + perCommand(.installer, "installer") + [
    Shot(name: "clean-review-search") { d in wrapped(model(.review) { reviewState($0, search: "item3") }, dark: d, ContentView()) },
    Shot(name: "clean-result-ambiguous") { d in
        wrapped(model(.result) {
            $0.result = ApplyResult(exitCode: 0, session: nil, skipped: [
                SkippedGroup(reason: "needs permanent delete", names: ["npm cache clean"])], failureNote: nil,
                notes: [MoleService.ambiguousRunNote])
        }, dark: d, ContentView())
    },
    Shot(name: "clean-result-errors") { d in
        wrapped(model(.result) {
            $0.result = ApplyResult(exitCode: 1, session: HistorySession(command: "clean", runId: "r", startedAt: nil, items: 12,
                                    sizeText: "300MB", removed: 3, trashed: 6, skipped: 1, failed: 2), skipped: [], failureNote: nil)
        }, dark: d, ContentView())
    },
    Shot(name: "error-killed") { d in
        wrapped(model(.idle, .purge) {
            $0.failure = ScanFailure.exited(137, tail: "○ DRY RUN MODE, No project artifacts will be removed\n\nPurge Project Artifacts")
            feed($0, ["○ DRY RUN MODE, No project artifacts will be removed", "", "Purge Project Artifacts"])
        }, dark: d, ContentView())
    },
    Shot(name: "error-killed-details") { d in
        wrapped(model(.idle, .purge), dark: d,
                ErrorCard(failure: ScanFailure.exited(137, tail: "○ DRY RUN MODE, No project artifacts will be removed\n\nPurge Project Artifacts"),
                          retry: {}, detailsOpen: true).padding(20).frame(maxHeight: .infinity, alignment: .top))
    },
    Shot(name: "error-cancelled") { d in
        wrapped(model(.idle) { $0.failure = .cancelled }, dark: d, ContentView())
    },
    Shot(name: "error-mole-not-found") { d in
        wrapped(model(.idle) {
            $0.failure = ScanFailure(MoleError("Mole not found at /opt/homebrew/bin/mo. Set the path in Settings.", kind: .notFound))
        }, dark: d, ContentView())
    },
    Shot(name: "error-other-plan") { d in
        wrapped(model(.idle, .purge) { $0.failure = ScanFailure(.planMismatch, MoleService.planMismatch("clean", .purge)) }, dark: d, ContentView())
    },
    Shot(name: "settings", width: 520, height: 430) { d in
        wrapped(model(.idle), dark: d, width: 520, height: 430, SettingsView())
    },
]

@MainActor func render() -> Int {
    var failed = 0
    for shot in shots {
        for dark in [false, true] {
            let file = "\(shot.name)-\(dark ? "dark" : "light").png"
            let renderer = ImageRenderer(content: shot.make(dark))
            renderer.scale = 1
            renderer.proposedSize = ProposedViewSize(width: shot.width, height: shot.height)
            guard let cg = renderer.cgImage else { print("FAIL \(file): no image"); failed += 1; continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else { print("FAIL \(file): no PNG"); failed += 1; continue }
            // Blank check: every pixel equal to the first.
            var distinct = false
            if let data = rep.bitmapData {
                let n = rep.bytesPerRow * rep.pixelsHigh
                let first = (data[0], data[1], data[2])
                var i = 0
                while i + 2 < n, !distinct { if (data[i], data[i + 1], data[i + 2]) != first { distinct = true }; i += rep.bitsPerPixel / 8 }
            }
            guard distinct else { print("FAIL \(file): blank image"); failed += 1; continue }
            do { try png.write(to: outDir.appendingPathComponent(file)) } catch {
                print("FAIL \(file): cannot write PNG: \(error.localizedDescription)"); failed += 1; continue
            }
            print("ok   \(file) \(cg.width)x\(cg.height)")
        }
    }
    return failed
}

let failed = MainActor.assumeIsolated { render() }
if failed > 0 { print("\(failed) snapshot(s) failed"); exit(1) }
print("all snapshots rendered")
