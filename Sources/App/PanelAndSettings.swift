import SwiftUI

/// Menu-bar popover: big switch, one-line status, mode, server, and the
/// last error. All tunnel state arrives via Helper XPC pushes (see
/// HelperClient); nothing here polls.
/// Disconnect goes through an inline confirm row (UI-DESIGN.md §四):
/// flipping the switch off never drops the tunnel immediately.
/// The panel is lazily created and released on close to keep the App's
/// footprint minimal.
struct PanelView: View {
    @ObservedObject var manager: HelperClient
    var profile: Profile
    var onStart: () -> Void
    var onStop: () -> Void
    @State private var showConfirmDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "VPN",
                isOn: Binding(
                    get: { manager.switchIsOn },
                    set: { on in
                        if on {
                            showConfirmDisconnect = false
                            onStart()
                        } else {
                            showConfirmDisconnect = true
                        }
                    }
                )
            )
            .toggleStyle(.switch)
            Text(statusLine)
                .font(.callout)
            if !manager.detail.isEmpty {
                Text(manager.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("模式：\(profile.defaultMode == .secure ? "全部走 VPN" : "仅名单走 VPN") · 服务器：\(profile.server)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if showConfirmDisconnect {
                HStack {
                    Text("确认断开 VPN？")
                        .font(.callout)
                    Spacer()
                    Button("确认断开") {
                        showConfirmDisconnect = false
                        onStop()
                    }
                    Button("取消") {
                        showConfirmDisconnect = false
                    }
                }
            }
            if let error = manager.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !manager.helperAvailable {
                Text("Helper 未运行")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(width: 300)
    }

    private var statusLine: String {
        switch manager.state {
        case .disconnected: return "已断开"
        case .connecting: return "连接中…"
        case .authenticating: return "认证中…"
        case .awaitingApproval: return "等批准：请在手机上点批准"
        case .connected: return "已连接 · \(profile.server)"
        case .reconnecting: return "重连中…"
        }
    }
}

final class PanelController: NSObject {
    private var popover: NSPopover?
    private let manager: HelperClient
    private let profile: Profile

    init(manager: HelperClient, profile: Profile) {
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
            onStop: { [weak self] in self?.manager.disconnect() }
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
        manager.connect(
            server: profile.server, group: profile.group,
            username: username, password: password)
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
