import SwiftUI
import MoleReviewCore
import MoleReviewUI

@main
struct MoleReviewApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Mole Review", id: AppDelegate.mainWindowID) {
            MainWindow(delegate: delegate).environmentObject(model)
        }
        .commands {
            CommandMenu("Review") {
                Button("Scan") { model.scan() }.keyboardShortcut("r", modifiers: .command)
                    .disabled(model.busy)
                Button("Toggle Selected Row") { model.toggleFocused() }.keyboardShortcut(.space, modifiers: [])
                    .disabled(model.phase != .review || model.focusedRow == nil)
                Button("\(model.command.action)…") { model.showConfirm = true }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canApply)
            }
        }
        Settings { SettingsView().environmentObject(model) }
    }
}

/// The main window's content; hands the model and a way to reopen this window to the delegate.
private struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate

    var body: some View {
        ContentView()
            .frame(minWidth: 760, minHeight: 520)
            .onAppear {
                delegate.model = model
                let open = openWindow
                delegate.openMainWindow = { open(id: AppDelegate.mainWindowID) }
            }
    }
}
