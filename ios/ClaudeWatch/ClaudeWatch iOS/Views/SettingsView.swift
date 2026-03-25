import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var relayService: RelayService
    @Environment(\.dismiss) private var dismiss

    @AppStorage("connectionMode") private var connectionMode: ConnectionMode = .auto

    @State private var showForgetConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                pairedMacSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(Color.claudeOrange)
                }
            }
            .alert("Forget Mac?", isPresented: $showForgetConfirmation) {
                Button("Forget", role: .destructive) {
                    relayService.unpair()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You will need to re-pair with a new code from Claude Code.")
            }
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section {
            Picker("Connection Mode", selection: $connectionMode) {
                Text("Auto").tag(ConnectionMode.auto)
                Text("LAN Only").tag(ConnectionMode.lanOnly)
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Auto discovers the bridge via Bonjour on your local network.")
        }
    }

    private var pairedMacSection: some View {
        Section("Paired Mac") {
            if relayService.isPaired {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(relayService.machineName ?? "Unknown Mac")
                            .foregroundStyle(.white)
                        if let lastConnected = relayService.lastConnected {
                            Text("Last connected \(lastConnected, style: .relative) ago")
                                .font(.caption)
                                .foregroundStyle(Color.subtleText)
                        }
                    }
                    Spacer()
                }

                Button("Forget This Mac", role: .destructive) {
                    showForgetConfirmation = true
                }
            } else {
                Text("No Mac paired")
                    .foregroundStyle(Color.subtleText)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                    .foregroundStyle(Color.subtleText)
            }

            Link(destination: URL(string: "https://github.com/anthropics/claude-code")!) {
                HStack {
                    Text("Claude Code")
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(Color.subtleText)
                }
            }
        }
    }
}

// MARK: - Connection Mode

enum ConnectionMode: String {
    case auto
    case lanOnly
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(RelayService.shared)
}
