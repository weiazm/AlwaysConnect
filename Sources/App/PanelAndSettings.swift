import SwiftUI

/// Menu-bar popover: big switch, one-line status, mode, server, and the
/// last tunnel error. All tunnel state arrives via NEVPNStatusDidChange
/// (see TunnelManager); nothing here polls.
/// The panel is lazily created and released on close to keep the App's
/// footprint minimal.
struct PanelView: View {
    @ObservedObject var manager: TunnelManager
    var profile: Profile
    var onStart: () -> Void
    var onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "VPN",
                isOn: Binding(
                    get: {
                        manager.status == .connected
                            || manager.status == .connecting
                            || manager.status == .reasserting
                    },
                    set: { on in on ? onStart() : onStop() }
                )
            )
            .toggleStyle(.switch)
            Text(statusLine)
                .font(.callout)
            Text("模式：\(profile.defaultMode == .secure ? "全部走 VPN" : "仅名单走 VPN") · 服务器：\(profile.server)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = manager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private var statusLine: String {
        switch manager.status {
        case .invalid: return "未配置"
        case .disconnected: return "已断开"
        case .connecting: return "连接中…"
        case .connected: return "已连接 · \(profile.server)"
        case .reasserting: return "重连中…"
        case .disconnecting: return "断开中…"
        @unknown default: return "未知状态"
        }
    }
}

final class PanelController: NSObject {
    private var popover: NSPopover?
    private let manager: TunnelManager
    private let profile: Profile

    init(manager: TunnelManager, profile: Profile) {
        self.manager = manager
        self.profile = profile
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let view = PanelView(
            manager: manager,
            profile: profile,
            onStart: { [weak self] in self?.startTapped() },
            onStop: { [weak self] in self?.manager.stop() }
        )
        let pop = NSPopover()
        pop.contentViewController = NSHostingController(rootView: view)
        pop.behavior = .transient
        self.popover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func startTapped() {
        // Credentials come from the Keychain; without them the panel
        // cannot start. Collecting them is the Settings UI's job
        // (Phase 2); until then a missing password simply leaves the
        // switch off, and the status line says why via lastError.
        guard let username = ProfileStore.loadUsername(), !username.isEmpty,
              let password = KeychainStore.read(server: profile.server, username: username)
        else { return }
        manager.loadOrCreate(profile: profile, username: username, password: password) { [weak self] error in
            guard let self, error == nil else { return }
            self.manager.start { _ in }
        }
    }
}

/// Placeholder settings view.
/// TODO (Phase 2/3): General / Credentials / Network / Diagnostics panes.
struct SettingsView: View {
    var body: some View {
        Text("AlwaysConnect Settings — TODO (Phase 2/3)")
            .padding()
            .frame(width: 480, height: 320)
    }
}
