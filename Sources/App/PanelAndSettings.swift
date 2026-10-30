import SwiftUI

/// Placeholder popover panel controller.
/// TODO (Phase 1): implement the panel — big switch, one-line status,
/// current split mode, last drop, shortcuts to Rules and Statistics.
/// The panel is lazily loaded and released on close to keep the App's
/// footprint minimal; all tunnel state arrives via XPC push, never polling.
final class PanelController: NSObject {
    // TODO (Phase 1)
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
