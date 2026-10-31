import SwiftUI

/// Menu-bar-only app (LSUIElement): no Dock icon.
/// The menu bar panel is the primary interface; the main window remains as
/// the second entry point for Settings and rule editing (per Apple HIG,
/// a menu bar extra must not be the sole route to a feature).
@main
struct AlwaysConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Settings window: opened from the menu bar panel.
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let profile = ProfileStore.loadProfile()
        panelController = PanelController(manager: HelperClient.shared, profile: profile)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "AC"
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(togglePanel(_:))
        // TODO (Phase 1): replace the placeholder title with a status icon
        // (color + shape: green solid = connected, yellow triangle = awaiting
        // approval/connecting, red hollow = disconnected with kill switch on),
        // driven by HelperClient.shared.state.
        // Auto-connect on launch when credentials are stored.
        if profile.autoConnectOnLaunch,
           let username = ProfileStore.loadUsername(), !username.isEmpty,
           let password = KeychainStore.read(server: profile.server, username: username) {
            HelperClient.shared.connect(
                server: profile.server, group: profile.group,
                username: username, password: password)
        }
    }

    @objc private func togglePanel(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        panelController?.toggle(relativeTo: button)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // NOTE: quitting the App must NOT tear down the tunnel. The
        // tunnel and reconnect loop live in the Helper daemon, which
        // is independent of this process.
    }
}
