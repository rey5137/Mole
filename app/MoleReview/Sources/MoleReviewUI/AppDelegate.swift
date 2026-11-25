import AppKit
import MoleReviewCore

/// Quitting stops Mole: no `mo` the app started outlives it. While a tab applies, the user
/// is asked first; scans and version checks are just cancelled. The app answers
/// `terminateLater` and quits once every run has stopped, or after `stopWaitSeconds`.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public weak var model: AppModel?
    /// Covers the runner's ladder: SIGINT, SIGTERM after 5 s, SIGKILL 1.5 s later, then the pipe drain.
    nonisolated public static let stopWaitSeconds: TimeInterval = 12
    /// The main window's scene id, so Keep Running can open it again after Cmd-W closed it.
    public static let mainWindowID = "main"

    /// Asks before stopping an apply; true is Stop and Quit. Checks replace it (no modal there).
    public var confirmQuit: (MoleCommand) -> Bool = { AppDelegate.quitAlert($0).runModal() == .alertFirstButtonReturn }
    /// Answers a `terminateLater`. Checks replace it so the answer does not end their process.
    public var replyToTerminate: (NSApplication, Bool) -> Void = { $0.reply(toApplicationShouldTerminate: $1) }
    /// Opens a new main window (SwiftUI's `openWindow`, set by the window's view).
    public var openMainWindow: (() -> Void)?
    /// Brings a main window back after Keep Running: closing the last one is what asked to quit.
    public lazy var showMainWindow: () -> Void = { [unowned self] in
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else if let w = NSApp.windows.first(where: { $0.isMiniaturized }) {
            w.deminiaturize(nil)
        } else {
            self.openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasRunningWork else { return .terminateNow }
        if let cmd = model.applyingCommand, !confirmQuit(cmd) {
            showMainWindow()
            return .terminateCancel
        }
        let runners = model.stopAllRuns()
        DispatchQueue.global().async {
            _ = MoleRunner.waitUntilStopped(runners, timeout: Self.stopWaitSeconds)
            Task { @MainActor [self] in self.replyToTerminate(sender, true) }
        }
        return .terminateLater
    }

    /// Exit skips `deinit`, so the admin password is zeroed here.
    public func applicationWillTerminate(_ notification: Notification) {
        model?.terminateAllRuns()
        model?.forgetAdminPassword()
    }

    public static func quitAlert(_ cmd: MoleCommand) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(quitNoun(cmd)) is running. Stop it and quit?"
        alert.informativeText = "Items already cleaned stay cleaned; the rest is left in place."
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Keep Running")
        return alert
    }

    static func quitNoun(_ cmd: MoleCommand) -> String {
        switch cmd {
        case .clean: return "A clean"
        case .purge: return "A purge"
        case .installer: return "An installer cleanup"
        }
    }
}
