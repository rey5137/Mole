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
guard case .plan(let plan) = try PlanDocument.decode(Data(contentsOf: fixtures.appendingPathComponent("plan-sample.json"))) else {
    print("plan-sample.json is not a plan"); exit(1)
}

@MainActor func model(_ phase: Phase, _ setup: (AppModel) -> Void = { _ in }) -> AppModel {
    let m = AppModel()
    m.phase = phase
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

let sampleLog = ["Scanning user caches…", "Scanning browsers…", "Sizing ~/Library/Caches (1,204 items)", "Scanning developer tools…"]
let session = HistorySession(command: "clean", runId: "r", startedAt: nil, items: 31, sizeText: "1.20GB",
                             removed: 4, trashed: 24, skipped: 3, failed: 0)

struct Shot { let name: String; let make: @MainActor (Bool) -> AnyView }
@MainActor func wrapped<V: View>(_ m: AppModel, dark: Bool, _ v: V) -> AnyView {
    AnyView(v.environmentObject(m)
        .environment(\.renderStandIn, true)
        .environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: 1000, height: 680)
        .background(dark ? Color(white: 0.14) : Color(white: 0.94)))
}

let shots: [Shot] = [
    Shot(name: "idle") { d in wrapped(model(.idle), dark: d, ContentView()) },
    Shot(name: "scanning") { d in wrapped(model(.scanning) { $0.log = sampleLog }, dark: d, ContentView()) },
    Shot(name: "review") { d in wrapped(model(.review) { reviewState($0) }, dark: d, ContentView()) },
    Shot(name: "review-search") { d in wrapped(model(.review) { reviewState($0, search: "item3") }, dark: d, ContentView()) },
    Shot(name: "confirm") { d in wrapped(model(.review) { reviewState($0) }, dark: d, ConfirmSheet().background(dark(d))) },
    Shot(name: "result") { d in
        wrapped(model(.result) {
            $0.result = ApplyResult(exitCode: 0, session: session, skipped: [
                SkippedGroup(reason: "changed since review", names: ["~/Library/Caches/Example"]),
                SkippedGroup(reason: "needs permanent delete", names: ["npm cache clean", "docker builder prune"]),
                SkippedGroup(reason: "needs sudo: " + SkippedReport.sudoHint, names: ["System caches"]),
            ], failureNote: nil)
            $0.log = ["Cleaning user caches…", "Done."]
        }, dark: d, ContentView())
    },
    Shot(name: "result-ambiguous") { d in
        wrapped(model(.result) {
            $0.result = ApplyResult(exitCode: 0, session: nil, skipped: [
                SkippedGroup(reason: "needs permanent delete", names: ["npm cache clean"])], failureNote: nil,
                notes: [MoleService.ambiguousRunNote])
        }, dark: d, ContentView())
    },
    Shot(name: "scan-error") { d in
        wrapped(model(.idle) { $0.errorText = "cancelled: The preview was cancelled before it finished; no plan was saved." },
                dark: d, ContentView())
    },
    Shot(name: "mole-not-found") { d in
        wrapped(model(.idle) { $0.errorText = "Mole not found at /opt/homebrew/bin/mo. Set the path in Settings." },
                dark: d, ContentView())
    },
]
@MainActor func dark(_ d: Bool) -> Color { d ? Color(white: 0.14) : Color(white: 0.94) }

@MainActor func render() -> Int {
    var failed = 0
    for shot in shots {
        for dark in [false, true] {
            let file = "\(shot.name)-\(dark ? "dark" : "light").png"
            let renderer = ImageRenderer(content: shot.make(dark))
            renderer.scale = 1
            renderer.proposedSize = ProposedViewSize(width: 1000, height: 680)
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
