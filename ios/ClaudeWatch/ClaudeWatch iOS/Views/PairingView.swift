import SwiftUI

struct PairingView: View {

    @EnvironmentObject private var relayService: RelayService

    // MARK: - State

    @State private var digits: [String] = Array(repeating: "", count: 6)
    @FocusState private var focusedField: Int?
    @State private var shakeOffset: CGFloat = 0
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var isConnecting: Bool = false

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                mascotIcon
                titleSection
                digitFields
                statusSection
                bottomInstruction

                Spacer()
            }
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Subviews

    private var mascotIcon: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.claudeOrange)
            .frame(width: 64, height: 64)
            .overlay(
                Text("C")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    private var titleSection: some View {
        VStack(spacing: 8) {
            Text("Claude Watch")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.claudeOrange)

            Text("Enter the pairing code from your Mac")
                .font(.system(size: 15))
                .foregroundStyle(Color.subtleText)
                .multilineTextAlignment(.center)
        }
    }

    private var digitFields: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { index in
                SingleDigitField(
                    text: $digits[index],
                    isError: showError,
                    isDisabled: isConnecting
                )
                .focused($focusedField, equals: index)
                .onChange(of: digits[index]) { _, newValue in
                    handleDigitChange(at: index, newValue: newValue)
                }
            }
        }
        .offset(x: shakeOffset)
        .onAppear {
            focusedField = 0
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if isConnecting {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(Color.claudeOrange)
                Text("Connecting to Mac...")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.subtleText)
            }
            .padding(.top, 4)
        } else if showError {
            Text(errorMessage)
                .font(.system(size: 14))
                .foregroundStyle(errorMessage.contains("expired") ? Color.claudeAmber : .red)
                .multilineTextAlignment(.center)
                .transition(.opacity)
                .padding(.top, 4)
        }
    }

    private var bottomInstruction: some View {
        Text("Run /claude-watch in Claude Code to get started")
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Color.subtleText)
            .multilineTextAlignment(.center)
            .padding(.bottom, 16)
    }

    // MARK: - Logic

    private func handleDigitChange(at index: Int, newValue: String) {
        // Only allow single digits
        let filtered = newValue.filter { $0.isNumber }
        if filtered.count > 1 {
            digits[index] = String(filtered.last!)
        } else {
            digits[index] = filtered
        }

        // Clear error state on new input
        if showError {
            withAnimation(.easeOut(duration: 0.2)) {
                showError = false
                errorMessage = ""
            }
        }

        // Auto-advance
        if !digits[index].isEmpty && index < 5 {
            focusedField = index + 1
        }

        // Auto-submit when all 6 digits entered
        let code = digits.joined()
        if code.count == 6 {
            submitCode(code)
        }
    }

    private func submitCode(_ code: String) {
        isConnecting = true
        focusedField = nil

        Task {
            do {
                try await relayService.pair(code: code)
                print("[PairingView] Pair succeeded, isPaired=\(relayService.isPaired)")
                // Success -- RelayService.isPaired will flip, triggering
                // the app-level transition to ConnectionStatusView.
            } catch let error as BridgeClient.BridgeError {
                print("[PairingView] BridgeError: \(error)")
                await MainActor.run {
                    handlePairingError(error)
                }
            } catch {
                print("[PairingView] Error: \(error)")
                await MainActor.run {
                    showPairingError("Connection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handlePairingError(_ error: BridgeClient.BridgeError) {
        switch error {
        case .invalidCode:
            showPairingError("Incorrect code. Please try again.")
            shakeFields()
        case .expired:
            showPairingError("Code expired. A new code has been generated on your Mac.")
        case .rateLimited:
            showPairingError("Too many attempts. Please wait a few minutes.")
        case .networkError:
            showPairingError("Cannot reach the bridge server. Check your network.")
        case .serverError(let msg):
            showPairingError(msg)
        }
    }

    private func showPairingError(_ message: String) {
        isConnecting = false
        errorMessage = message
        withAnimation(.easeInOut(duration: 0.3)) {
            showError = true
        }
        resetDigits()
    }

    private func resetDigits() {
        digits = Array(repeating: "", count: 6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            focusedField = 0
        }
    }

    private func shakeFields() {
        withAnimation(.easeInOut(duration: 0.06).repeatCount(5, autoreverses: true)) {
            shakeOffset = 10
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            shakeOffset = 0
        }
    }
}

// MARK: - Single Digit Field

private struct SingleDigitField: View {

    @Binding var text: String
    let isError: Bool
    let isDisabled: Bool

    var body: some View {
        TextField("", text: $text)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .multilineTextAlignment(.center)
            .font(.system(size: 28, weight: .bold, design: .monospaced))
            .foregroundStyle(isError ? .red : Color.claudeOrange)
            .frame(width: 48, height: 56)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isError ? .red : Color.fieldBorder,
                        lineWidth: 1
                    )
            )
            .opacity(isDisabled ? 0.4 : 1.0)
            .disabled(isDisabled)
    }
}

// MARK: - Preview

#Preview {
    PairingView()
        .environmentObject(RelayService.shared)
}
