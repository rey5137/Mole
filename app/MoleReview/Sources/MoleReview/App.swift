import SwiftUI
import MoleReviewCore
import MoleReviewUI

@main
struct MoleReviewApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Mole Review") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
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

