import SwiftUI
import AppKit
import MoleReviewCore

public struct ContentView: View {
    @EnvironmentObject var model: AppModel
    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle: IdleView()
            case .scanning, .applying: ProgressPane()
            case .review: ReviewView()
            case .result: ResultView()
            }
        }
        .sheet(isPresented: $model.showConfirm) { ConfirmSheet() }
    }
}

struct IdleView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Mole Review").font(.largeTitle)
            Text("Scan, tick what to clean, confirm. Nothing is deleted until you confirm.")
                .foregroundStyle(.secondary)
            if let e = model.errorText {
                Text(e).foregroundStyle(.red).textSelection(.enabled).multilineTextAlignment(.center).padding(.horizontal)
            }
            Text("Mole: \(model.resolvedCommand)").font(.caption).foregroundStyle(.secondary)
            Button("Scan") { model.scan() }.keyboardShortcut("r", modifiers: .command).modifier(ButtonLook(prominent: true))
            Spacer()
            LogView()
        }.padding()
    }
}

struct LogView: View {
    @EnvironmentObject var model: AppModel
    @State private var open = false
    var body: some View {
        DisclosureGroup("Details (\(model.log.count) lines)", isExpanded: $open) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
                .onChange(of: model.log.count) { n in if n > 0 { proxy.scrollTo(n - 1) } }
            }
        }
    }
}

struct ProgressPane: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Spinner()
            Text(model.phase == .scanning ? "Scanning…" : "Cleaning…").font(.title2)
            Text("Elapsed \(Format.countdown(model.elapsed))").foregroundStyle(.secondary)
            Button("Cancel") { model.cancel() }.modifier(ButtonLook())
            Spacer()
            LogView()
        }.padding()
    }
}

struct ReviewView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let state = model.review {
            VStack(spacing: 0) {
                HeaderBar(state: state)
                Divider()
                PlainList(selection: $model.focusedRow) {
                    ForEach(state.plan.sections, id: \.id) { section in
                        SectionView(section: section)
                    }
                    if !state.plan.skipped.isEmpty {
                        DisclosureGroup("Skipped (\(state.plan.skipped.count))") {
                            ForEach(Array(state.plan.skipped.enumerated()), id: \.offset) { _, s in
                                Text("\(s.section) · \(s.name): \(s.reason)").font(.callout)
                            }
                        }
                    }
                }
                Divider()
                LogView().padding(.horizontal).padding(.vertical, 4)
            }
            .modifier(SearchField(text: searchBinding))
        }
    }
    private var searchBinding: Binding<String> {
        Binding(get: { model.review?.searchText ?? "" }, set: { model.review?.searchText = $0 })
    }
}

struct HeaderBar: View {
    @EnvironmentObject var model: AppModel
    let state: ReviewState
    var body: some View {
        let expired = state.isExpired(now: model.now)
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading) {
                Text("\(Format.bytes(state.selectedBytes)) of \(Format.bytes(state.plan.totalBytes)) selected").font(.headline)
                Text("\(state.selectedItems) of \(state.plan.totalItems) items" +
                     (state.plan.freeBytes.map { " · \(Format.bytes($0)) free" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if expired {
                Text("Plan expired").foregroundStyle(.red)
                Button("Scan again") { model.scan() }.modifier(ButtonLook())
            } else {
                Text("Expires in \(Format.countdown(state.remaining(now: model.now)))").font(.caption).foregroundStyle(.secondary)
                Button("Scan again") { model.scan() }.modifier(ButtonLook())
                Button("Clean…") { model.showConfirm = true }
                    .modifier(ButtonLook(prominent: true))
                    .disabled(!state.canClean(now: model.now))
            }
        }.padding()
    }
}

struct SectionView: View {
    @EnvironmentObject var model: AppModel
    let section: PlanSection
    @State private var open = true

    var body: some View {
        if let state = model.review {
            let rows = state.rows(in: section)
            if state.searchText.isEmpty || !rows.isEmpty {
                DisclosureGroup(isExpanded: $open) {
                    ForEach(rows, id: \.item.id) { row in ItemRow(row: row) }
                } label: {
                    HStack {
                        TriCheckbox(state: state.sectionState(section)) {
                            model.review?.setSection(section.id, on: state.sectionState(section) != .on)
                        }
                        Text(section.name).font(.headline)
                        Spacer()
                        Text(Format.bytes(section.bytes)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct TriCheckbox: View {
    let state: TriState
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
        }.buttonStyle(.plain)
    }
}

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let row: ReviewRow

    var body: some View {
        let item = row.item
        let on = model.review?.isSelected(item) ?? false
        HStack {
            if row.indented { Spacer().frame(width: 24) }
            if item.isCovered {
                Image(systemName: on ? "checkmark.square" : "square").foregroundStyle(.secondary)
            } else {
                Button { model.review?.toggle(item.id) } label: {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                }.buttonStyle(.plain)
            }
            VStack(alignment: .leading) {
                Text(item.isCommand ? item.title : Format.abbreviate(item.title))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(item.isCovered ? .secondary : .primary)
                if item.isCovered { Text("covered by the folder above, not counted").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            if item.count > 1 { Text("\(item.count) items").font(.caption).foregroundStyle(.secondary) }
            Text(item.isCommand ? "command" : (item.sizeKnown ? Format.bytes(item.bytes) : "size unknown"))
                .font(.callout).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .tag(item.id)
        .contextMenu {
            if let p = item.path {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                Button("Copy path") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p, forType: .string)
                }
            }
        }
    }
}

public struct ConfirmSheet: View {
    @EnvironmentObject var model: AppModel
    public init() {}
    public var body: some View {
        let s = model.review
        let bytes = Format.bytes(s?.selectedBytes ?? 0)
        let cmds = s?.selectedCommandCount ?? 0
        VStack(alignment: .leading, spacing: 12) {
            Text("Clean \(s?.selectedRowCount ?? 0) items?").font(.title2)
            Text("\(s?.selectedItems ?? 0) files, \(bytes) in total")
            CheckToggle("Move to Trash (recoverable)", isOn: $model.useTrash)
            if cmds > 0 {
                let names = (s?.selectedCommandNames ?? []).joined(separator: ", ")
                Text(model.useTrash
                     ? "Runs: \(names). These commands can only delete permanently, so they will be skipped under Trash, as will any root-owned or system-only items."
                     : "Runs: \(names). These commands do their own cleanup and cannot be undone.")
                    .font(.callout).foregroundStyle(.orange)
            } else if model.useTrash {
                Text("Root-owned or system-only items are skipped under Trash and listed afterwards.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !model.useTrash {
                Text("Files will be deleted permanently.").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.showConfirm = false }.keyboardShortcut(.cancelAction).modifier(ButtonLook())
                Button(model.useTrash ? "Move \(bytes) to Trash" : "Delete \(bytes) permanently", role: .destructive) { model.apply() }
                    .keyboardShortcut(.defaultAction).modifier(ButtonLook(prominent: true, destructive: true))
                    .disabled(!(s?.canClean(now: model.now) ?? false))
            }
        }.padding(20).frame(width: 460)
    }
}

struct ResultView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let r = model.result
        VStack(alignment: .leading, spacing: 12) {
            Text(r?.exitCode == 0 ? "Done" : "Finished with errors (exit \(r?.exitCode ?? -1))").font(.title)
            if let n = r?.failureNote { Text(n).foregroundStyle(.red) }
            if let s = r?.session {
                Text("\(s.sizeBytes.map(Format.bytes) ?? s.sizeText) over \(s.items) items: \(s.removed) removed, \(s.trashed) moved to Trash, \(s.skipped) skipped, \(s.failed) failed")
            } else if (r?.notes ?? []).isEmpty {
                Text("No history session matched this run; see Details.").foregroundStyle(.secondary)
            }
            ForEach(r?.notes ?? [], id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
            if let groups = r?.skipped, !groups.isEmpty {
                Text("Skipped").font(.headline)
                PlainList(selection: nil) {
                    ForEach(groups, id: \.reason) { g in
                        DisclosureGroup("\(g.reason) (\(g.names.count))") {
                            ForEach(Array(g.names.enumerated()), id: \.offset) { _, n in Text(n).font(.callout).textSelection(.enabled) }
                        }
                    }
                }
            } else { Spacer() }
            LogView()
            HStack { Spacer(); Button("Scan again") { model.scan() }.modifier(ButtonLook(prominent: true)) }
        }.padding()
    }
}

public struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    public init() {}
    public var body: some View {
        Form {
            TextField("Mole command", text: model.$moleCommand, prompt: Text(model.resolvedCommand))
            Text("Leave empty to use $MOLE_PATH, the checkout's mole, or mo in Homebrew or ~/.local/bin.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding().frame(width: 480)
    }
}

// MARK: stand-ins for the snapshot renderer
//
// ImageRenderer draws a "no entry" placeholder for AppKit-backed controls
// (List, bordered Buttons, Toggle, ProgressView) and has no toolbar for
// .searchable. `renderStandIn` is false in the app, where every helper below
// emits the original control; only MoleReviewSnapshots turns it on.

private struct StandInKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    public var renderStandIn: Bool {
        get { self[StandInKey.self] }
        set { self[StandInKey.self] = newValue }
    }
}

struct ButtonLook: ViewModifier {
    var prominent = false
    var destructive = false
    @Environment(\.renderStandIn) private var standIn
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        if standIn {
            content.buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .foregroundColor(prominent ? .white : .primary)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(prominent ? (destructive ? Color.red : Color.accentColor) : Color.gray.opacity(0.25)))
                .opacity(enabled ? 1 : 0.4)
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content
        }
    }
}

struct Spinner: View {
    @Environment(\.renderStandIn) private var standIn
    var body: some View {
        if standIn {
            Circle().trim(from: 0, to: 0.75).stroke(Color.secondary, lineWidth: 3).frame(width: 24, height: 24)
        } else {
            ProgressView()
        }
    }
}

struct PlainList<Content: View>: View {
    let selection: Binding<String?>?
    @ViewBuilder let content: Content
    @Environment(\.renderStandIn) private var standIn
    init(selection: Binding<String?>?, @ViewBuilder content: () -> Content) {
        self.selection = selection; self.content = content()
    }
    var body: some View {
        if standIn {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) { content }.padding(.horizontal, 12).padding(.vertical, 8)
                }
                .clipped()
        } else if let selection {
            List(selection: selection) { content }
        } else {
            List { content }
        }
    }
}

struct SearchField: ViewModifier {
    @Binding var text: String
    @Environment(\.renderStandIn) private var standIn
    func body(content: Content) -> some View {
        if standIn {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(text.isEmpty ? "Filter by path" : text).foregroundStyle(text.isEmpty ? .secondary : .primary)
                    Spacer()
                }
                .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.2)))
                .padding(.horizontal, 12).padding(.vertical, 6)
                content
            }
        } else {
            content.searchable(text: $text, prompt: "Filter by path")
        }
    }
}

struct CheckToggle: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.renderStandIn) private var standIn
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }
    var body: some View {
        if standIn {
            HStack { Image(systemName: isOn ? "checkmark.square.fill" : "square"); Text(title) }
        } else {
            Toggle(title, isOn: $isOn)
        }
    }
}
