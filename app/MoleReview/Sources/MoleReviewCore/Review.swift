import Foundation

public enum TriState: Equatable { case on, off, mixed }

/// One row as the list shows it: covered rows follow their folder, indented.
public struct ReviewRow: Equatable {
    public let item: PlanItem
    public let indented: Bool
}

/// Selection, totals, search and sort for one plan. Pure value logic so the
/// checks can drive it without a UI.
///
/// `selected` holds the rows ticked on their own. A covered row of clean follows
/// its folder's tick and is sent with it, never counted. A purge trim row
/// (covered by its whole `target` item) is ticked on its own instead: while its
/// whole item is ticked it shows as included, adds nothing and is not sent, and
/// unticking the whole item brings its own tick back. A kind the plan's command
/// does not produce is shown but never ticked, counted or sent.
public struct ReviewState {
    public let plan: Plan
    public private(set) var selected: Set<String>
    public var searchText = ""
    private let kinds: Set<String>

    public init(plan: Plan) {
        self.plan = plan
        let kinds = MoleCommand(rawValue: plan.command)?.kinds ?? []
        self.kinds = kinds
        selected = Set(plan.allItems.filter { !$0.isCovered && !$0.isTrim && $0.defaultSelected && kinds.contains($0.kind) }
            .map { $0.id })
    }

    // MARK: selection

    public func isSupported(_ item: PlanItem) -> Bool { kinds.contains(item.kind) }

    /// Rows the section checkbox ticks: whole items, never covered or trim rows.
    private func items(of section: PlanSection) -> [PlanItem] { section.items.filter { !$0.isCovered && isSupported($0) } }

    /// A trim whose whole item is ticked: shown as included, disabled, not sent.
    public func isIncludedByParent(_ item: PlanItem) -> Bool {
        item.isTrim && item.coveredBy.map { selected.contains($0) } == true
    }

    /// Whether the row's own checkbox can be clicked.
    public func isTickable(_ item: PlanItem) -> Bool {
        isSupported(item) && !item.followsParent && !isIncludedByParent(item)
    }

    public func isSelected(_ item: PlanItem) -> Bool {
        guard isSupported(item) else { return false }
        if item.followsParent, let parent = item.coveredBy { return selected.contains(parent) }
        return selected.contains(item.id) || isIncludedByParent(item)
    }

    /// Rows that remove something of their own and count in the totals.
    private func counts(_ item: PlanItem) -> Bool {
        isSupported(item) && !item.followsParent && selected.contains(item.id) && !isIncludedByParent(item)
    }

    public mutating func toggle(_ id: String) {
        guard let item = plan.allItems.first(where: { $0.id == id }), isTickable(item) else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Rows of the section with a checkbox of their own: whole items and trims.
    private func rowsWithBox(of section: PlanSection) -> [PlanItem] {
        section.items.filter { isSupported($0) && !$0.followsParent }
    }

    /// On ticks the whole items (their trims then show as included); off clears
    /// the whole items and the trims' own ticks, so nothing of the section is sent.
    public mutating func setSection(_ sectionId: String, on: Bool) {
        guard let s = plan.sections.first(where: { $0.id == sectionId }) else { return }
        for item in on ? items(of: s) : rowsWithBox(of: s) {
            if on { selected.insert(item.id) } else { selected.remove(item.id) }
        }
    }

    /// A trim counts as a row: only a trim ticked makes its section mixed.
    public func sectionState(_ section: PlanSection) -> TriState {
        let own = rowsWithBox(of: section)
        let n = own.filter { isSelected($0) }.count
        if n == 0 { return .off }
        return n == own.count ? .on : .mixed
    }

    public mutating func selectNone() { selected.removeAll() }

    // MARK: totals (covered rows and included trims never add)

    public var selectedBytes: Int64 {
        plan.allItems.filter(counts).reduce(0) { $0 + $1.bytes }
    }
    /// Command items add no files, matching the CLI's `total_items`.
    public var selectedItems: Int {
        plan.allItems.filter { counts($0) && !$0.isCommand }.reduce(0) { $0 + $1.count }
    }
    public var selectedRowCount: Int { plan.allItems.filter(counts).count }

    /// The header's "N of M items". Clean counts files (its `total_items`); purge and
    /// installer count rows with a checkbox, a trim as one row (never its entries):
    /// N rows that will be sent, M whole items plus trims.
    public var itemCounts: (selected: Int, total: Int) {
        if plan.command == MoleCommand.clean.rawValue { return (selectedItems, plan.totalItems) }
        return (selectedRowCount, plan.allItems.filter { isSupported($0) && !$0.followsParent }.count)
    }

    public func selectedBytes(in section: PlanSection) -> Int64 {
        section.items.filter(counts).reduce(0) { $0 + $1.bytes }
    }

    public var selectedCommandCount: Int { selectedCommandNames.count }

    /// Names of the ticked command items, as the confirm sheet lists them.
    public var selectedCommandNames: [String] {
        plan.allItems.filter { $0.isCommand && counts($0) }.map { $0.name ?? $0.command ?? $0.id }
    }

    /// Ticked rows in a cloud-synced folder, for the confirm sheet's warning.
    public var selectedCloudCount: Int { plan.allItems.filter { counts($0) && $0.isCloud }.count }

    // MARK: expiry

    public func isExpired(now: Date = Date()) -> Bool { now >= plan.expiresAt }
    public func remaining(now: Date = Date()) -> TimeInterval { plan.expiresAt.timeIntervalSince(now) }

    /// Apply is available only for an unexpired plan with something ticked.
    public func canClean(now: Date = Date()) -> Bool { !isExpired(now: now) && selectedRowCount > 0 }

    // MARK: rows

    public func rows(in section: PlanSection) -> [ReviewRow] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ i: PlanItem) -> Bool {
            query.isEmpty || i.title.lowercased().contains(query) || (i.command ?? "").lowercased().contains(query)
        }
        let ids = Set(section.items.map { $0.id })
        // A covered row whose folder is not in this section stands alone.
        let roots = section.items.filter { $0.coveredBy == nil || !ids.contains($0.coveredBy!) }
            .sorted { $0.bytes > $1.bytes }
        var out: [ReviewRow] = []
        for root in roots {
            let kids = section.items.filter { $0.coveredBy == root.id }
            let shownKids = kids.filter(matches)
            guard matches(root) || !shownKids.isEmpty else { continue }
            out.append(ReviewRow(item: root, indented: root.isCovered))
            for k in (matches(root) ? kids : shownKids) { out.append(ReviewRow(item: k, indented: true)) }
        }
        return out
    }

    // MARK: selection file

    /// Ids to hand to `--select`: ticked rows plus the covered rows under them;
    /// a trim only when its whole item is not ticked; never an unsupported kind.
    public func selectionIDs() -> [String] {
        var out: [String] = []
        for item in plan.allItems where isSupported(item) {
            if item.followsParent {
                if selected.contains(item.coveredBy!) { out.append(item.id) }
            } else if counts(item) {
                out.append(item.id)
            }
        }
        return out
    }

    /// Writes the ids, one per line, to a new 0600 file in `directory`. A failure while
    /// writing or closing removes the file again. `write` is a seam for the failure check.
    public func writeSelectionFile(in directory: URL = FileManager.default.temporaryDirectory,
                                   write: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }) throws -> URL {
        let url = directory.appendingPathComponent("mole-review-\(UUID().uuidString).select")
        let body = selectionIDs().map { $0 + "\n" }.joined()
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try write(handle, Data(body.utf8))
            try handle.close()
        } catch {
            try? handle.close()
            unlink(url.path)
            throw error
        }
        return url
    }
}
