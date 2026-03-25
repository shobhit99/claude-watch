import SwiftUI

// MARK: - StatusDashboard

/// Read-only status dashboard showing task summary, files changed, time elapsed, and connection quality.
struct StatusDashboard: View {
    @EnvironmentObject private var session: WatchViewState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: Task Summary
                statusSection(title: "Task") {
                    if session.sessionState.activity == .idle {
                        Text("No active task")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.Text.secondary)
                    } else {
                        Text(taskSummary)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(Theme.Text.primary)
                            .lineLimit(2)
                    }
                }

                // MARK: Stats
                statusSection(title: "Stats") {
                    HStack(spacing: 16) {
                        statItem(
                            icon: "doc.text",
                            value: "\(session.sessionState.filesChanged)",
                            label: "Files"
                        )

                        statItem(
                            icon: "clock",
                            value: formattedElapsed,
                            label: "Time"
                        )

                        statItem(
                            icon: "plus.forwardslash.minus",
                            value: "\(session.sessionState.linesAdded)",
                            label: "Lines"
                        )
                    }
                }

                // MARK: Connection
                statusSection(title: "Connection") {
                    HStack(spacing: 8) {
                        connectionDot
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connectionLabel)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(connectionColor)

                            if let machine = session.sessionState.machineName {
                                Text(machine)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.Text.secondary)
                            }

                            Text(transportLabel)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Text.dimmed)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Theme.Background.primary)
        .navigationTitle("Status")
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.Text.dimmed)
                .tracking(1)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statItem(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(Theme.Text.primary)

            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.Text.primary)

            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Theme.Text.secondary)
        }
    }

    private var taskSummary: String {
        // Show the last command line as a summary
        if let lastCommand = session.terminalLines.last(where: { $0.type == .command }) {
            return lastCommand.text
        }
        return "Running..."
    }

    private var formattedElapsed: String {
        let seconds = session.sessionState.elapsedSeconds
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return "\(seconds / 60)m"
        } else {
            return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
        }
    }

    private var connectionDot: some View {
        Circle()
            .fill(connectionColor)
            .frame(width: 10, height: 10)
    }

    private var connectionColor: Color {
        switch session.sessionState.connection {
        case .connected: return Theme.Accent.success
        case .connecting: return Theme.Text.secondary
        case .disconnected: return Theme.Accent.error
        case .iPhoneUnreachable: return Theme.Accent.approval
        }
    }

    private var connectionLabel: String {
        switch session.sessionState.connection {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .disconnected: return "Disconnected"
        case .iPhoneUnreachable: return "iPhone Unreachable"
        }
    }

    private var transportLabel: String {
        switch session.sessionState.transportMode {
        case .lan: return "Local network"
        case .remote: return "Remote relay"
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        StatusDashboard()
    }
    .environmentObject(WatchViewState.shared)
}
