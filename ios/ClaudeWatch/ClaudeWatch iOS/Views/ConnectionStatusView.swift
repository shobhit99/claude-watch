import SwiftUI

struct ConnectionStatusView: View {

    @EnvironmentObject private var relayService: RelayService
    @EnvironmentObject private var sessionManager: WatchSessionManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings = false
    @State private var showBackgroundBanner = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 16) {
                    header
                    statusCard
                    terminalOutput
                    Spacer()
                    if showBackgroundBanner {
                        backgroundBanner
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Color.subtleText)
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(relayService)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            withAnimation(.easeInOut(duration: 0.3)) {
                showBackgroundBanner = (newPhase == .inactive)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Mascot
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.claudeOrange)
                .frame(width: 32, height: 32)
                .overlay(
                    Text("C")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )

            Text("Claude Watch")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            connectionBadge
        }
    }

    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.statusGreen)
                .frame(width: 6, height: 6)
            Text("LAN")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.statusGreen)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.connectedPillBackground)
        .clipShape(Capsule())
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected to \(relayService.machineName ?? "Mac")")
                .font(.system(size: 15))
                .foregroundStyle(Color.claudeOrange)

            if let model = relayService.modelName {
                Label {
                    Text(model)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.subtleText)
                } icon: {
                    Image(systemName: "cpu")
                        .foregroundStyle(Color.subtleText)
                        .font(.system(size: 11))
                }
            }

            if let dir = relayService.workingDirectory {
                Label {
                    Text(dir)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.subtleText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.subtleText)
                        .font(.system(size: 11))
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .foregroundStyle(Color.subtleText)
                    .font(.system(size: 11))
                Text(formattedElapsedTime)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.subtleText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Terminal output

    private var terminalOutput: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.subtleText)
                Spacer()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(relayService.recentTerminalLines) { line in
                            terminalLineView(line)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 200)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: relayService.recentTerminalLines.count) { _, _ in
                    if let lastLine = relayService.recentTerminalLines.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(lastLine.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func terminalLineView(_ line: TerminalLine) -> some View {
        Text(line.text)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(colorForLineType(line.type))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colorForLineType(_ type: TerminalLine.LineType) -> Color {
        switch type {
        case .output:   return Color.claudeOrange
        case .command:  return .white
        case .system:   return Color.subtleText
        case .thinking: return Color.claudeOrange.opacity(0.5)
        case .error:    return .red
        }
    }

    // MARK: - Background banner

    private var backgroundBanner: some View {
        Text("Keep this app open for real-time relay to your Watch")
            .font(.system(size: 13))
            .foregroundStyle(Color.claudeAmber)
            .multilineTextAlignment(.center)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Helpers

    private var formattedElapsedTime: String {
        let total = relayService.elapsedSeconds
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Preview

#Preview {
    ConnectionStatusView()
        .environmentObject(WatchSessionManager.shared)
        .environmentObject(RelayService.shared)
}
