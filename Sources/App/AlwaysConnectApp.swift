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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "AC"
        // TODO (Phase 1): replace the placeholder title with a status icon
        // (color + shape: green solid = connected, yellow triangle = awaiting
        // approval/connecting, red hollow = disconnected with kill switch on).
        // TODO (Phase 1): attach the popover panel (switch, one-line status,
        // mode, last drop, shortcuts to Rules/Statistics) and wire it to the
        // tunnel manager (NETunnelProviderManager) + shared SessionState.
    }

    func applicationWillTerminate(_ notification: Notification) {
        // NOTE: quitting the App must NOT tear down the tunnel. The tunnel
        // and reconnect loop live in the PacketTunnelProvider, which is
        // managed by the system, not by this process.
    }
}
