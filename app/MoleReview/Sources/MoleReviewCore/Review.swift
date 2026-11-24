import Foundation

public enum TriState: Equatable { case on, off, mixed }

/// One row as the list shows it: covered rows follow their folder, indented.
public struct ReviewRow: Equatable {
    public let item: PlanItem
    public let indented: Bool
}

/// Selection, totals, search and sort for one plan. Pure value logic so the
/// checks can drive it without a UI.
public struct ReviewState {
    public let plan: Plan
    public private(set) var selected: Set<String>
    public var searchText = ""

    public init(plan: Plan) {
        self.plan = plan
        selected = Set(plan.allItems.filter { !$0.isCovered && $0.defaultSelected }.map { $0.id })
    }

    // MARK: selection

    private func items(of section: PlanSection) -> [PlanItem] { section.items.filter { !$0.isCovered } }

    public func isSelected(_ item: PlanItem) -> Bool {
        if let parent = item.coveredBy { return selected.contains(parent) }
        return selected.contains(item.id)
    }

    public mutating func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    public mutating func setSection(_ sectionId: String, on: Bool) {
        guard let s = plan.sections.first(where: { $0.id == sectionId }) else { return }
        for item in items(of: s) {
            if on { selected.insert(item.id) } else { selected.remove(item.id) }
        }
    }

    public func sectionState(_ section: PlanSection) -> TriState {
        let own = items(of: section)
        let n = own.filter { selected.contains($0.id) }.count
        if n == 0 { return .off }
        return n == own.count ? .on : .mixed
    }

    public mutating func selectNone() { selected.removeAll() }

    // MARK: totals (covered rows never add)

    public var selectedBytes: Int64 {
        plan.allItems.filter { !$0.isCovered && selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }
    /// Command items add no files, matching the CLI's `total_items`.
    public var selectedItems: Int {
        plan.allItems.filter { !$0.isCovered && !$0.isCommand && selected.contains($0.id) }.reduce(0) { $0 + $1.count }
    }
    public var selectedRowCount: Int { plan.allItems.filter { !$0.isCovered && selected.contains($0.id) }.count }

    public func selectedBytes(in section: PlanSection) -> Int64 {
        items(of: section).filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    public var selectedCommandCount: Int { selectedCommandNames.count }

    /// Names of the ticked command items, as the confirm sheet lists them.
    public var selectedCommandNames: [String] {
        plan.allItems.filter { $0.isCommand && selected.contains($0.id) }.map { $0.name ?? $0.command ?? $0.id }
    }

    // MARK: expiry

    public func isExpired(now: Date = Date()) -> Bool { now >= plan.expiresAt }
    public func remaining(now: Date = Date()) -> TimeInterval { plan.expiresAt.timeIntervalSince(now) }

    /// Clean is available only for an unexpired plan with something ticked.
    public func canClean(now: Date = Date()) -> Bool { !isExpired(now: now) && !selected.isEmpty }

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

    /// Ids to hand to `--select`: ticked rows plus the covered rows under them.
    public func selectionIDs() -> [String] {
        var out: [String] = []
        for item in plan.allItems {
            if item.isCovered {
                if selected.contains(item.coveredBy!) { out.append(item.id) }
            } else if selected.contains(item.id) {
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
