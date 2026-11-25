import Foundation

/// The admin password, kept in this app's memory only (never UserDefaults, the Keychain,
/// a file or a log) until `clear()` or quit. The bytes are zeroed when cleared. The
/// String a text field hands over cannot be zeroed; callers drop it right after `set`.
/// `MoleRunner` writes the bytes to a pipe for `mo` (`MOLE_SUDO_PASSWORD_FD`).
public final class AdminPassword: CustomStringConvertible {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    public init() {}
    deinit { wipe() }

    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return !bytes.isEmpty }

    /// Longest password kept, in UTF-8 bytes: far past any Mac password, and well inside one
    /// pipe buffer, so writing it never blocks.
    public static let maxBytes = 1024

    /// Keeps `password`; refuses (and keeps nothing) an empty one, one longer than `maxBytes`,
    /// or one holding a line break, since `mo` reads exactly one line.
    @discardableResult
    public func set(_ password: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        wipeLocked()
        guard password.utf8.count <= Self.maxBytes else { return false }
        let new = Array(password.utf8)
        guard !new.isEmpty, !new.contains(0x0A), !new.contains(0x0D) else { return false }
        bytes = new
        return true
    }

    public func clear() { wipe() }

    /// Runs `body` on the bytes without copying them out; nil when none are kept.
    func withBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) -> R) -> R? {
        lock.lock(); defer { lock.unlock() }
        guard !bytes.isEmpty else { return nil }
        return bytes.withUnsafeBufferPointer(body)
    }

    public var description: String { "AdminPassword(\(isSet ? "set" : "empty"))" }

    private func wipe() { lock.lock(); defer { lock.unlock() }; wipeLocked() }
    private func wipeLocked() {
        bytes.withUnsafeMutableBytes { buf in
            if let base = buf.baseAddress { _ = memset_s(base, buf.count, 0, buf.count) }
        }
        bytes.removeAll()
    }
}
