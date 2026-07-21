import SwiftUI

struct UpdateStatusPanelView: View {
    @EnvironmentObject var status: UpdateStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("settings.updateSource.statusPanel",
                            status.currentSource,
                            formatted(status.lastCheck),
                            status.lastSwitchReason ?? "—"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}