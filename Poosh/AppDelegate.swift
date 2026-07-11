import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.poosh.Poosh", category: "App")

    private var hotKeyService: HotKeyService?
    private var spaceOverrideService: SpaceOverrideService?
    private let panelController = PanelController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hotKey = HotKeyService()
        hotKey.onHotKey = { [weak self] in
            self?.handleHotKey()
        }
        hotKeyService = hotKey

        let spaceOverride = SpaceOverrideService()
        spaceOverride.onSpace = { [weak self] in
            self?.handleSpaceOverride()
        }
        spaceOverrideService = spaceOverride

        DispatchQueue.main.async {
            hotKey.register()
            spaceOverride.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyService?.unregister()
        spaceOverrideService?.stop()
    }

    @objc func openSelectedImage() {
        handleHotKey()
    }

    private func handleSpaceOverride() {
        if panelController.isPresented {
            panelController.dismiss(saving: true)
        } else {
            handleHotKey()
        }
    }

    private func handleHotKey() {
        Self.logger.info("Hotkey received")

        switch FinderService.selectedFileURL() {
        case .success(let url):
            guard ImageFormatValidator.isSupportedImage(url: url) else {
                Self.logger.error("Unsupported or unreadable image at \(url.path, privacy: .public)")
                presentAlert(
                    title: "Unsupported File",
                    message: "The selected file is not a supported image (.jpg, .jpeg, .png, .heic, .webp)."
                )
                return
            }

            panelController.present(url: url)

        case .failure(let error):
            Self.logger.error("\(error.localizedDescription, privacy: .public)")
            presentAlert(title: "Could Not Open Image", message: error.localizedDescription, error: error)
        }
    }

    private func presentAlert(title: String, message: String, error: FinderService.SelectionError? = nil) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if case .automationDenied = error {
            alert.addButton(withTitle: "Open Settings")
        }
        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
