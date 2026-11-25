import Foundation

/// One line of Mole's own progress output (`mo clean` and friends print to stderr
/// under `--json`, to stdout under `--apply`), read for display only. Unknown lines
/// are kept as `.text`; nothing here decides what is removed.
public struct ProgressLine: Equatable {
    public enum Kind: Equatable {
        /// `➤ App caches`, or purge's `━━━ name ━━━`.
        case section
        /// `✓ Trash · emptied`.
        case done
        /// `○ Chrome cache · 1.07GB dry`.
        case item
        /// `◎ Project caches · skipped 1 slow/incomplete root scan`, and Mole's error face.
        case warning
        /// `⊙ Docker storage · …`: shown for review, never cleaned by itself.
        case review
        /// `⚙ Apple Silicon | Free space: 79.92GB`.
        case info
        /// An indented sub-line under an item.
        case detail
        /// Any other unindented text (titles, summaries).
        case text
        /// `=====` separator.
        case rule
        case blank
    }

    public let kind: Kind
    /// The line without its glyph.
    public let text: String
    /// The line exactly as printed (colour codes removed).
    public let raw: String
    /// First size on a `.item` or `.done` line (`273.2MB`), in bytes.
    public let size: Int64?

    /// A line that stands for one thing Mole looked at or did.
    public var countsAsItem: Bool {
        guard kind == .item || kind == .done else { return false }
        let t = text.lowercased()
        return !(t.hasPrefix("nothing to clean") || t.hasPrefix("no ") && t.contains(" to clean"))
    }

    /// `Chrome cache` of `Chrome cache · 1.07GB dry`.
    public var title: String { text.components(separatedBy: " · ").first ?? text }
    /// `1.07GB dry`: what follows the first ` · `, empty when there is none.
    public var meta: String {
        guard let r = text.range(of: " · ") else { return "" }
        return String(text[r.upperBound...])
    }

    /// `meta` without the size token that the size column already shows: `9 items, 20KB`
    /// becomes `9 items`, `602.4MB dry` becomes empty, `would free 118.8MB` becomes `would free`.
    public var metaWithoutSize: String {
        guard size != nil else { return meta }
        let ns = meta as NSString
        guard let m = ProgressLine.sizeToken.firstMatch(in: meta, range: NSRange(location: 0, length: ns.length)) else { return meta }
        var t = ns.replacingCharacters(in: m.range, with: "")
        t = t.replacingOccurrences(of: "  ", with: " ")
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
        if t == "dry" { return "" }
        if t.hasSuffix(" dry") { t = String(t.dropLast(4)).trimmingCharacters(in: CharacterSet(charactersIn: ", ")) }
        return t
    }

    private static let glyphs: [Character: Kind] = [
        "➤": .section, "✓": .done, "○": .item, "●": .item, "•": .item, "◎": .warning, "☻": .warning,
        "⊙": .review, "⚙": .info,
    ]
    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")
    private static let sizeToken = try! NSRegularExpression(pattern: #"(?<![\w.])(\d+(?:\.\d+)?)\s?(TB|GB|MB|KB|B)(?![A-Za-z])"#)

    public static func parse(_ line: String) -> ProgressLine {
        let ns = line as NSString
        let stripped = ansi.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        let raw = String(stripped.reversed().drop(while: { $0.isWhitespace }).reversed())
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return ProgressLine(kind: .blank, text: "", raw: raw, size: nil) }
        let indented = raw.first == " " || raw.first == "\t"
        if let first = trimmed.first, var kind = glyphs[first] {
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            // `○ DRY RUN MODE, No project artifacts will be removed` is a banner, not an item.
            if kind == .item, rest.lowercased().hasPrefix("dry run mode") { kind = .info }
            let size = (kind == .item || kind == .done) ? firstSize(in: rest) : nil
            return ProgressLine(kind: kind, text: rest, raw: raw, size: size)
        }
        if trimmed.hasPrefix("━━━"), trimmed.hasSuffix("━━━"), trimmed.count > 6 {
            let name = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "━ "))
            return ProgressLine(kind: .section, text: name, raw: raw, size: nil)
        }
        if trimmed.count >= 3, trimmed.allSatisfy({ "=-━─".contains($0) }) {
            return ProgressLine(kind: .rule, text: "", raw: raw, size: nil)
        }
        if indented || trimmed.hasPrefix("↳") {
            return ProgressLine(kind: .detail, text: trimmed.hasPrefix("↳") ? trimmed.dropFirst().trimmingCharacters(in: .whitespaces) : trimmed,
                                raw: raw, size: nil)
        }
        return ProgressLine(kind: .text, text: trimmed, raw: raw, size: nil)
    }

    /// `1.07GB` -> bytes (decimal units, as Mole prints them).
    static func firstSize(in text: String) -> Int64? {
        let ns = text as NSString
        guard let m = sizeToken.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return History.parseSize(ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2)))
    }
}

/// What the progress header shows: the current section, how many things Mole has
/// reported and the sizes on those lines added up. Fed one line at a time.
public struct ProgressSummary: Equatable {
    public private(set) var section: String?
    public private(set) var items = 0
    public private(set) var bytes: Int64 = 0
    public private(set) var lines = 0
    public init() {}

    public mutating func add(_ line: ProgressLine) {
        lines += 1
        if line.kind == .section { section = line.text }
        if line.countsAsItem {
            items += 1
            bytes += line.size ?? 0
        }
    }
}

/// Hands lines produced on reader threads to the UI in batches: `notify` fires at most
/// once per `interval` while lines are waiting, and `drain()` (called on the main actor)
/// returns everything gathered so far, in order. A flood of lines costs a few UI updates,
/// not one per line.
public final class LineBatcher {
    private let lock = NSLock()
    private var pending: [String] = []
    private var armed = false
    private let interval: TimeInterval
    private let notify: () -> Void

    public init(interval: TimeInterval = 0.08, notify: @escaping () -> Void) {
        self.interval = interval; self.notify = notify
    }

    public func add(_ line: String) {
        lock.lock()
        pending.append(line)
        let arm = !armed
        armed = true
        lock.unlock()
        if arm { DispatchQueue.global().asyncAfter(deadline: .now() + interval) { [notify] in notify() } }
    }

    public func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = pending
        pending = []
        armed = false
        return out
    }
}
