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
            CommandMenu("Clean") {
                Button("Scan") { model.scan() }.keyboardShortcut("r", modifiers: .command)
                    .disabled(model.busy)
                Button("Toggle Selected Row") { model.toggleFocused() }.keyboardShortcut(.space, modifiers: [])
                    .disabled(model.phase != .review || model.focusedRow == nil)
                Button("Clean…") { model.showConfirm = true }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(!(model.phase == .review && model.review?.canClean(now: model.now) == true))
            }
        }
        Settings { SettingsView().environmentObject(model) }
    }
}

