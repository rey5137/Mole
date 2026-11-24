import Foundation

/// One row of a plan section. `kind` is "path" or "command"; covered rows are
/// listed but already counted inside the folder named by `coveredBy`.
public struct PlanItem: Decodable, Equatable {
    public let id: String
    public let kind: String
    public let path: String?
    public let name: String?
    public let command: String?
    public let bytes: Int64
    public let sizeKnown: Bool
    public let count: Int
    public let coveredBy: String?
    public let defaultSelected: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, path, name, command, bytes, count
        case sizeKnown = "size_known"
        case coveredBy = "covered_by"
        case defaultSelected = "default_selected"
    }

    public var isCommand: Bool { kind == "command" }
    public var isCovered: Bool { coveredBy != nil }

    /// Text shown for the row and matched by the search field.
    public var title: String {
        if isCommand { return "Runs: " + (name ?? command ?? id) }
        return path ?? name ?? id
    }
}

public struct PlanSection: Decodable, Equatable {
    public let id: String
    public let name: String
    public let bytes: Int64
    public let items: [PlanItem]
}

public struct SkippedEntry: Decodable, Equatable {
    public let section: String
    public let name: String
    public let reason: String
    public init(section: String, name: String, reason: String) {
        self.section = section; self.name = name; self.reason = reason
    }
}

public struct Plan: Decodable, Equatable {
    public let schema: Int
    public let planId: String
    public let createdAt: Date
    public let expiresAt: Date
    public let freeBytes: Int64?
    public let totalBytes: Int64
    public let totalItems: Int
    public let sections: [PlanSection]
    public let skipped: [SkippedEntry]

    enum CodingKeys: String, CodingKey {
        case schema, sections, skipped
        case planId = "plan_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case freeBytes = "free_bytes"
        case totalBytes = "total_bytes"
        case totalItems = "total_items"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        planId = try c.decode(String.self, forKey: .planId)
        createdAt = try Plan.date(c, .createdAt)
        expiresAt = try Plan.date(c, .expiresAt)
        freeBytes = try c.decodeIfPresent(Int64.self, forKey: .freeBytes)
        totalBytes = try c.decode(Int64.self, forKey: .totalBytes)
        totalItems = try c.decode(Int.self, forKey: .totalItems)
        sections = try c.decode([PlanSection].self, forKey: .sections)
        skipped = try c.decodeIfPresent([SkippedEntry].self, forKey: .skipped) ?? []
    }

    private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date {
        let text = try c.decode(String.self, forKey: key)
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "bad date \(text)")
        }
        return d
    }

    public var allItems: [PlanItem] { sections.flatMap { $0.items } }
}

public struct PlanError: Equatable {
    public let code: String
    public let message: String
}

/// What `mo clean --dry-run --json` printed on stdout.
public enum PlanDocument: Equatable {
    case plan(Plan)
    case error(PlanError)

    public enum DecodeFailure: Error, Equatable { case notJSON, unknownDocument }

    public static func decode(_ data: Data) throws -> PlanDocument {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeFailure.notJSON
        }
        if let err = obj["error"] as? [String: Any] {
            return .error(PlanError(code: err["code"] as? String ?? "unknown",
                                    message: err["message"] as? String ?? ""))
        }
        guard obj["plan_id"] != nil else { throw DecodeFailure.unknownDocument }
        return .plan(try JSONDecoder().decode(Plan.self, from: data))
    }
}

public enum Format {
    public static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// `/Users/me/Library/x` -> `~/Library/x`.
    public static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if !home.isEmpty, home != "/", path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
