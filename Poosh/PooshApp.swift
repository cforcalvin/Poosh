import SwiftUI

@main
struct PooshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Poosh", systemImage: "p.circle") {
            Button("Open Selected Image") {
                (NSApp.delegate as? AppDelegate)?.openSelectedImage()
            }
            Divider()
            Button("Quit Poosh") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
