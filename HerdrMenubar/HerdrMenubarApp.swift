import SwiftUI

@main
struct HerdrMenubarApp: App {
    var body: some Scene {
        MenuBarExtra {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            // Placeholder until M2 draws the per-state counts.
            Image(systemName: "circle.dashed")
        }
        .menuBarExtraStyle(.menu)
    }
}
