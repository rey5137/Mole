import Foundation

/// Whether the app can read folders macOS keeps behind Full Disk Access. The probe
/// opens a directory that only that grant opens (Safari's data folders) with
/// `opendir`: a refusal comes back as EPERM/EACCES with no prompt, unlike
/// Documents or Desktop, which would ask. Nothing is read from the folder.
public enum FullDiskAccess {
    public enum Status: Equatable { case granted, denied, unknown }

    public static func defaultProbes(home: String = NSHomeDirectory()) -> [String] {
        [home + "/Library/Safari", home + "/Library/Containers/com.apple.Safari"]
    }

    /// `denied` as soon as one probe is refused, `granted` when one opens, `unknown`
    /// when none exists (no Safari data on this Mac).
    public static func status(probes: [String] = defaultProbes()) -> Status {
        var opened = false
        for path in probes {
            guard let dir = opendir(path) else {
                if errno == EPERM || errno == EACCES { return .denied }
                continue
            }
            closedir(dir)
            opened = true
        }
        return opened ? .granted : .unknown
    }

    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    public static let why = "Mole reads caches, the Trash and project folders. Without Full Disk Access macOS asks per folder, or Mole skips them (for example \"Trash · skipped, grant Full Disk Access\")."
}
