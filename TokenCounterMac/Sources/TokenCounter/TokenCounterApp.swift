import SwiftUI

enum DashboardScene {
    static let windowID = "dashboard"
}

@main
struct TokenCounterApp: App {
    @State private var store: UsageStore

    init() {
        // Headless modes, before any UI is brought up.
        if CommandLine.arguments.contains(SelfTest.flag) {
            SelfTest.runAndExit()
        }
        if CommandLine.arguments.contains(AuditMode.flag) {
            AuditMode.runAndExit()
        }
        if CommandLine.arguments.contains(DumpCatalogMode.flag) {
            DumpCatalogMode.runAndExit()
        }
        _store = State(initialValue: UsageStore())
    }

    var body: some Scene {
        Window("Claude Code Token Counter", id: DashboardScene.windowID) {
            DashboardView(store: store)
        }
        .defaultSize(width: 1120, height: 840)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Logs") { store.refresh() }
                    .keyboardShortcut("r", modifiers: .command)

                Button("Reload From Scratch") { store.reloadFromScratch() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarContentView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
