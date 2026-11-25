import SwiftUI
import AppKit
import MoleReviewCore

public struct ContentView: View {
    @EnvironmentObject var model: AppModel
    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider()
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

/// The window's top bar: the Clean / Purge / Installer switch (each tab keeps its own
/// plan, selection and result) and the actions of the shown state.
struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.renderStandIn) private var standIn
    private func label(_ c: MoleCommand) -> String {
        model.tabs[c]?.busy == true ? c.title + " •" : c.title
    }
    var body: some View {
        HStack(spacing: 12) {
            if standIn {
                HStack(spacing: 2) {
                    ForEach(MoleCommand.allCases) { c in
                        Text(label(c)).padding(.horizontal, 14).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(c == model.command ? Color.gray.opacity(0.45) : Color.clear))
                    }
                }.padding(2).background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.2)))
            } else {
                Picker("Command", selection: $model.command) {
                    ForEach(MoleCommand.allCases) { c in Text(label(c)).tag(c) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Spacer()
            switch model.phase {
            case .idle:
                Button("Scan") { model.scan() }.modifier(ButtonLook(prominent: true))
            case .scanning, .applying:
                Button("Cancel") { model.cancel() }.modifier(ButtonLook())
            case .review:
                Button("Rescan") { model.scan() }.modifier(ButtonLook())
                Button("\(model.command.action) selected…") { model.showConfirm = true }
                    .modifier(ButtonLook(prominent: true))
                    .disabled(!model.canApply)
            case .result:
                Button("Scan again") { model.scan() }.modifier(ButtonLook(prominent: true))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }
}

extension MoleCommand {
    var blurb: String {
        switch self {
        case .clean: return "Caches, logs and leftovers Mole knows are safe to remove. Nothing is removed until you confirm."
        case .purge: return "Build folders (node_modules, target, dist…) in your project paths. Nothing is removed until you confirm."
        case .installer: return "Installer files (.dmg, .pkg, .iso…) in Downloads and similar folders. Nothing is removed until you confirm."
        }
    }
    /// The empty-scan headline, in the tab's own words.
    public var emptyTitle: String {
        switch self {
        case .clean: return "Nothing to clean"
        case .purge: return "No build folders found"
        case .installer: return "No installer files found"
        }
    }
    var symbol: String {
        switch self {
        case .clean: return "sparkles"
        case .purge: return "folder.badge.minus"
        case .installer: return "shippingbox"
        }
    }
}

struct IdleView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: model.command.symbol).font(.title).foregroundStyle(Color.accentColor).frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.command.title).font(.title2.weight(.semibold))
                    Text(model.command.blurb).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let f = model.failure { ErrorCard(failure: f, retry: { model.scan() }) }
            if model.fullDiskAccess != .granted { FullDiskAccessCard() }
            if model.failure == nil {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Scan to see what can be removed").font(.headline)
                    Text("The scan only looks; you review and tick the items next.").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            if !model.rawLogIsEmpty { DetailsDisclosure() }
        }.padding(20)
    }
}

struct ReviewView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let state = model.review {
            VStack(spacing: 0) {
                if let f = model.failure {
                    ErrorCard(failure: f, retry: nil, dismiss: { model.failure = nil }).padding([.horizontal, .top], 14)
                }
                if state.plan.allItems.isEmpty {
                    EmptyPlanView(state: state)
                } else {
                    SummaryBar(state: state)
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
                }
                if !model.rawLogIsEmpty {
                    Divider()
                    DetailsDisclosure().padding(.horizontal, 14).padding(.vertical, 6)
                }
            }
            .modifier(SearchField(text: searchBinding))
        }
    }
    private var searchBinding: Binding<String> {
        Binding(get: { model.review?.searchText ?? "" }, set: { model.review?.searchText = $0 })
    }
}

/// A scan that found nothing: say so, offer a rescan, and still list what was skipped.
struct EmptyPlanView: View {
    @EnvironmentObject var model: AppModel
    let state: ReviewState
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.green)
            Text(model.command.emptyTitle).font(.title3.weight(.semibold))
            Text("Mole found nothing to remove in \(model.command.title). Nothing was changed.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Rescan") { model.scan() }.modifier(ButtonLook())
            if !state.plan.skipped.isEmpty {
                Text("\(state.plan.skipped.count) skipped: " + state.plan.skipped.prefix(3).map { "\($0.name) (\($0.reason))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Totals and the plan's expiry. The actions live in the top bar.
struct SummaryBar: View {
    @EnvironmentObject var model: AppModel
    let state: ReviewState
    var body: some View {
        let expired = state.isExpired(now: model.now)
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Format.bytes(state.selectedBytes)) of \(Format.bytes(state.plan.totalBytes)) selected").font(.headline)
                Text("\(state.itemCounts.selected) of \(state.itemCounts.total) items" +
                     (state.plan.freeBytes.map { " · \(Format.bytes($0)) free" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if expired {
                Label("Plan expired, rescan to continue", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
            } else {
                if let other = model.applyingCommand, other != model.command {
                    Text("Waiting for mo \(other.rawValue) to finish").font(.caption).foregroundStyle(.orange)
                }
                Text("Expires in \(Format.countdown(state.remaining(now: model.now)))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// Width of the size column in the list, so sizes line up from the section header down.
private let sizeColumn: CGFloat = 92
private let countColumn: CGFloat = 70

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
                        Text({ let n = section.items.filter { !$0.followsParent && state.isSupported($0) }.count; return "\(n) \(n == 1 ? "row" : "rows")" }()).font(.caption).foregroundStyle(.tertiary)
                            .frame(width: countColumn, alignment: .trailing)
                        Text(Format.bytes(section.bytes)).font(.callout.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: sizeColumn, alignment: .trailing)
                    }.frame(minHeight: 30)
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
    @State private var hovering = false

    var body: some View {
        let item = row.item
        let state = model.review
        let on = state?.isSelected(item) ?? false
        let supported = state?.isSupported(item) ?? false
        HStack {
            if row.indented { Spacer().frame(width: 24) }
            if state?.isTickable(item) == true {
                Button { model.review?.toggle(item.id) } label: {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                }.buttonStyle(.plain)
            } else {
                Image(systemName: on ? "checkmark.square" : "square").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(primary(item))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(item.followsParent || !supported ? .secondary : .primary)
                ForEach(notes(item, state: state), id: \.text) { n in
                    Text(n.text).font(.caption2).foregroundStyle(n.warn ? Color.orange : Color.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(item.count > 1 ? "\(item.count) items" : "").font(.caption).foregroundStyle(.secondary)
                .frame(width: countColumn, alignment: .trailing)
            Text(item.isCommand ? "command" : (item.sizeKnown ? Format.bytes(item.bytes) : "size unknown"))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: sizeColumn, alignment: .trailing)
        }
        .frame(minHeight: 34)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.07) : Color.clear))
        .onHover { hovering = $0 }
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

    private func primary(_ item: PlanItem) -> String {
        if item.isTrim { return PlanItem.trimLabel }
        if let name = item.name, item.type != nil { return name }
        return item.isCommand ? item.title : Format.abbreviate(item.title)
    }

    private struct Note { let text: String; var warn = false }

    private func notes(_ item: PlanItem, state: ReviewState?) -> [Note] {
        var out: [Note] = []
        if state?.isSupported(item) == false {
            out.append(Note(text: "\(item.kind) item: not supported by this app version", warn: true))
            return out
        }
        if item.followsParent { out.append(Note(text: "covered by the folder above, not counted")) }
        if item.isTrim {
            out.append(Note(text: state?.isIncludedByParent(item) == true
                            ? "included: the whole folder above is ticked"
                            : "keeps the folder; \(Format.abbreviate(item.title))"))
        } else if let artifact = item.artifact {
            out.append(Note(text: [artifact, item.age.map { "last used \($0)" }].compactMap { $0 }.joined(separator: " · ")))
        }
        if let type = item.type {
            out.append(Note(text: type.uppercased() + " · " + Format.abbreviate((item.path ?? "") as String)))
        }
        if item.isCloud && !item.isTrim {
            out.append(Note(text: "In a cloud-synced folder: removing it also removes it from the cloud copy", warn: true))
        }
        return out
    }
}

public struct ConfirmSheet: View {
    @EnvironmentObject var model: AppModel
    public init() {}
    public var body: some View {
        let s = model.review
        let bytes = Format.bytes(s?.selectedBytes ?? 0)
        let cmds = s?.selectedCommandCount ?? 0
        let cloud = s?.selectedCloudCount ?? 0
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.command.action) \(s?.selectedRowCount ?? 0) items?").font(.title2)
            Text(model.command == .clean ? "\(s?.selectedItems ?? 0) files, \(bytes) in total" : "\(bytes) in total")
            CheckToggle("Move to Trash (recoverable)", isOn: $model.useTrash)
            if cloud > 0 {
                Text("\(cloud) of them \(cloud == 1 ? "is" : "are") in a cloud-synced folder; removing \(cloud == 1 ? "it" : "them") also removes \(cloud == 1 ? "it" : "them") from the cloud copy.")
                    .font(.callout).foregroundStyle(.orange)
            }
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
                    .disabled(!model.canApply)
            }
        }.padding(20).frame(width: 460)
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
