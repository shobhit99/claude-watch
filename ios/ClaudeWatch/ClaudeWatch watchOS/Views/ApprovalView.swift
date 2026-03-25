import SwiftUI

// MARK: - ApprovalView

/// Decision mode: presented as a sheet so the terminal remains visible underneath.
struct ApprovalView: View {
    @EnvironmentObject private var session: WatchSessionManager
    @Environment(\.dismiss) private var dismiss

    let request: ApprovalRequest

    @State private var flashColor: Color? = nil
    @State private var hasResponded = false

    var body: some View {
        ZStack {
            Theme.Background.overlay.ignoresSafeArea()

            // Flash overlay for approve/deny feedback
            if let color = flashColor {
                color.opacity(0.3)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            VStack(spacing: 16) {
                Spacer()

                // Header
                Text("Claude wants to:")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Text.secondary)

                // Action summary
                ScrollView {
                    Text(request.actionSummary)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(Theme.Accent.approval)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)

                Spacer()

                // Approve / Deny buttons
                HStack(spacing: 8) {
                    // Deny
                    Button {
                        respondDeny()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                            Text("Deny")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Theme.Accent.error)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(hasResponded)

                    // Approve
                    Button {
                        respondApprove()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .bold))
                            Text("OK")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Theme.Accent.success)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(hasResponded)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .onChange(of: request.status) { newStatus in
            // If the approval expired server-side, auto-dismiss
            if newStatus == .expired {
                dismiss()
            }
        }
    }

    // MARK: - Actions

    private func respondApprove() {
        guard !hasResponded else { return }
        hasResponded = true

        HapticManager.approvalNeeded() // success haptic
        WKInterfaceDevice.current().play(.success)

        withAnimation(.easeIn(duration: 0.15)) {
            flashColor = Theme.Accent.success
        }

        session.respondToApproval(requestId: request.id, approved: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            dismiss()
        }
    }

    private func respondDeny() {
        guard !hasResponded else { return }
        hasResponded = true

        WKInterfaceDevice.current().play(.failure)

        withAnimation(.easeIn(duration: 0.15)) {
            flashColor = Theme.Accent.error
        }

        session.respondToApproval(requestId: request.id, approved: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            dismiss()
        }
    }
}

// MARK: - Preview

#Preview {
    ApprovalView(
        request: ApprovalRequest(
            toolName: "bash",
            actionSummary: "Run: rm -rf node_modules && npm install"
        )
    )
    .environmentObject(WatchSessionManager.shared)
}
