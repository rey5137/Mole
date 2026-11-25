import SwiftUI
import AppKit
import MoleReviewCore

// MARK: live progress

/// Scan and apply while they run: what Mole is on now, a running tally, and every line it prints.
struct ProgressPane: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ProgressHeader()
            Divider()
            LiveFeed(height: nil)
        }
    }
}

struct ProgressHeader: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let p = model.tab.progress
        HStack(spacing: 14) {
            Spinner()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.phase == .scanning ? "Scanning…" : model.command.progress).font(.headline)
                Text(p.section ?? "Starting…").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(tally(p)).font(.headline).monospacedDigit()
                Text("Elapsed \(Format.countdown(model.elapsed))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
    private func tally(_ p: ProgressSummary) -> String {
        let items = "\(p.items) \(p.items == 1 ? "item" : "items")"
        return p.bytes > 0 ? "\(items) · \(Format.bytes(p.bytes))" : items
    }
}

/// The log, newest line at the bottom and kept in view. Mole's glyph lines show as section
/// headers and item rows; "Raw" shows the text as printed, and Copy takes all of it.
/// `height` nil fills the space; a number gives the fixed height the Details disclosure uses.
struct LiveFeed: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.renderStandIn) private var standIn
    let height: CGFloat?
    @State private var raw = false

    var body: some View {
        let tab = model.tab
        VStack(spacing: 0) {
            HStack {
                Text(tab.lineCountText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(raw ? "Formatted" : "Raw") { raw.toggle() }.modifier(ButtonLook()).font(.caption)
                Button(tab.rawDropped > 0 ? "Copy last \(tab.rawLog.count)" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab.rawLog.joined(separator: "\n"), forType: .string)
                }.modifier(ButtonLook()).font(.caption)
            }.padding(.horizontal, 16).padding(.vertical, 5)
            Divider()
            Group {
                if standIn {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tab.entries.suffix(16)) { FeedRow(line: $0.line) }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
                } else if raw {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(tab.rawLog.enumerated()), id: \.offset) { i, l in
                                    Text(l.isEmpty ? " " : l).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                                }
                            }.padding(.horizontal, 16).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: tab.rawLog.count) { n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(tab.entries) { FeedRow(line: $0.line).id($0.id) }
                            }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onChange(of: tab.entries.last?.id) { id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }
            }
            .frame(height: height)
        }
    }
}

/// One line of Mole's output: a section header, or an item with an icon, its name, the
/// rest of the line and the size in a fixed right-hand column.
struct FeedRow: View {
    let line: ProgressLine

    var body: some View {
        switch line.kind {
        case .section:
            Text(line.text).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 3)
        case .done: item("checkmark.circle.fill", .green)
        case .item: item("circle", .secondary)
        case .warning: item("exclamationmark.triangle.fill", .orange)
        case .review: item("eye", .secondary)
        case .info: item("gearshape", .secondary)
        case .detail:
            Text(line.text).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .padding(.leading, 42).padding(.trailing, 16).padding(.vertical, 1)
        case .text:
            Text(line.text).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 2)
        case .rule, .blank: EmptyView()
        }
    }

    private func item(_ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            Text(line.title).lineLimit(1).truncationMode(.middle)
            if !line.metaWithoutSize.isEmpty {
                Text(line.metaWithoutSize).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text(line.size.map(Format.bytes) ?? "").monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(.horizontal, 16).padding(.vertical, 2)
    }
}

/// The finished run's log, folded away.
struct DetailsDisclosure: View {
    @EnvironmentObject var model: AppModel
    @State private var open: Bool
    init(open: Bool = false) { _open = State(initialValue: open) }
    var body: some View {
        DisclosureGroup("Details (\(model.tab.lineCountText))", isExpanded: $open) {
            LiveFeed(height: 200)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        }
    }
}

// MARK: errors

/// A failed scan in words: one sentence, the output Mole printed folded under "Show details",
/// and a way forward. Mole's normal progress lines never appear as the headline.
public struct ErrorCard: View {
    let failure: ScanFailure
    var retry: (() -> Void)?
    var dismiss: (() -> Void)?
    @State private var open: Bool
    public init(failure: ScanFailure, retry: (() -> Void)? = nil, dismiss: (() -> Void)? = nil, detailsOpen: Bool = false) {
        self.failure = failure; self.retry = retry; self.dismiss = dismiss
        _open = State(initialValue: detailsOpen)
    }

    private var neutral: Bool { failure.kind == .cancelled }
    private var tint: Color { neutral ? .secondary : .orange }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: neutral ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.summary).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !failure.details.isEmpty {
                    DisclosureGroup("Show details", isExpanded: $open) {
                        Text(failure.details).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                }
                HStack {
                    if let retry { Button("Retry", action: retry).modifier(ButtonLook(prominent: true)) }
                    if failure.kind == .notFound { Button("Open Settings") { openSettings() }.modifier(ButtonLook()) }
                    if let dismiss { Button("Dismiss", action: dismiss).modifier(ButtonLook()) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.35)))
    }
}

func openSettings() {
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}

// MARK: Full Disk Access

func openFullDiskAccessSettings() {
    if let url = URL(string: FullDiskAccess.settingsURL) { NSWorkspace.shared.open(url) }
}

extension FullDiskAccess.Status {
    var label: String {
        switch self {
        case .granted: return "On"
        case .denied: return "Off"
        case .unknown: return "Can't tell"
        }
    }
}

/// Shown on the idle screen until the grant is detected.
struct FullDiskAccessCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.fullDiskAccess == .denied ? "Full Disk Access is off" : "Full Disk Access").font(.headline)
                Text(FullDiskAccess.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Grant Full Disk Access…") { openFullDiskAccessSettings() }.modifier(ButtonLook())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: result

struct ResultView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let r = model.result
        let ok = r?.exitCode == 0 && (r?.session?.failed ?? 0) == 0
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 34)).foregroundStyle(ok ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline(r)).font(.title2.weight(.semibold))
                    if let sub = subline(r) { Text(sub).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            if let n = r?.failureNote { Text(n).foregroundStyle(.red) }
            if let s = r?.session {
                HStack(spacing: 10) {
                    Stat(value: s.removed, label: "removed")
                    Stat(value: s.trashed, label: "moved to Trash")
                    Stat(value: s.skipped, label: "skipped")
                    Stat(value: s.failed, label: "failed", alert: s.failed > 0)
                }
            } else if (r?.notes ?? []).isEmpty {
                Text("No history session matched this run; see Details.").foregroundStyle(.secondary)
            }
            ForEach(r?.notes ?? [], id: \.self) { Label($0, systemImage: "info.circle").font(.callout).foregroundStyle(.orange) }
            if let groups = r?.skipped, !groups.isEmpty {
                Text("Skipped, \(groups.reduce(0) { $0 + $1.names.count }) items").font(.headline)
                PlainList(selection: nil) {
                    ForEach(groups, id: \.reason) { g in
                        DisclosureGroup("\(g.reason) (\(g.names.count))") {
                            ForEach(Array(g.names.enumerated()), id: \.offset) { _, n in Text(n).font(.callout).textSelection(.enabled) }
                        }
                    }
                }
            } else { Spacer() }
            if !model.rawLogIsEmpty { DetailsDisclosure() }
        }.padding(20)
    }

    private func headline(_ r: ApplyResult?) -> String {
        guard let r else { return "Done" }
        if r.exitCode != 0 { return "Finished with errors (exit \(r.exitCode))" }
        guard let s = r.session else { return "Done" }
        if let b = s.sizeBytes { return "\(Format.bytes(b)) cleaned" }
        return s.sizeText.isEmpty ? "Done" : "\(s.sizeText) cleaned"
    }

    private func subline(_ r: ApplyResult?) -> String? {
        guard let s = r?.session else { return nil }
        var parts = ["\(s.items) items"]
        if s.trashed > 0 { parts.append("in the Trash until you empty it") }
        return parts.joined(separator: ", ")
    }
}

struct Stat: View {
    let value: Int
    let label: String
    var alert = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(alert ? Color.red : Color.primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(minWidth: 110, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: settings

public struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.renderStandIn) private var standIn
    public init() {}

    private var commandNote: String {
        "Using \(model.resolvedCommand). Leave empty to use $MOLE_PATH, the checkout's mole, or mo in Homebrew or ~/.local/bin."
    }
    private let accessNote = "Turn on Mole Review in System Settings, then reopen the app."

    public var body: some View {
        if standIn {
            // ImageRenderer draws a placeholder for Form; the same content in plain stacks.
            VStack(alignment: .leading, spacing: 10) {
                Text("Mole").font(.headline)
                Text(model.resolvedCommand).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.2)))
                Text(commandNote).font(.caption).foregroundStyle(.secondary)
                Text("Full Disk Access").font(.headline).padding(.top, 8)
                HStack {
                    Text("Status: \(model.fullDiskAccess.label)")
                    Spacer()
                    Text("Grant Full Disk Access…").modifier(ButtonLook())
                }
                Text(FullDiskAccess.why).font(.caption).foregroundStyle(.secondary)
                Text(accessNote).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(20).frame(width: 520)
        } else {
            Form {
                Section("Mole") {
                    TextField("Command", text: model.$moleCommand, prompt: Text(model.resolvedCommand))
                    Text(commandNote).font(.caption).foregroundStyle(.secondary)
                }
                Section("Full Disk Access") {
                    HStack {
                        Text("Status: \(model.fullDiskAccess.label)")
                        Spacer()
                        Button("Grant Full Disk Access…") { openFullDiskAccessSettings() }
                    }
                    Text(FullDiskAccess.why).font(.caption).foregroundStyle(.secondary)
                    Text(accessNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 520)
            .onAppear { model.refreshFullDiskAccess() }
        }
    }
}
