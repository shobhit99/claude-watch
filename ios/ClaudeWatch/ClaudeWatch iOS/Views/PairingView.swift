import SwiftUI

struct PairingView: View {

    @EnvironmentObject private var relayService: RelayService

    // MARK: - State

    @State private var code: String = ""
    @FocusState private var isFieldFocused: Bool
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
        .onTapGesture {
            isFieldFocused = true
        }
    }

    // MARK: - Subviews

    private var mascotIcon: some View {
        AppLogo(size: 88)
    }

    private var titleSection: some View {
        VStack(spacing: 8) {
            Text("Agent Watch")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.claudeOrange)

            Text("Enter the pairing code from your Mac")
                .font(.system(size: 15))
                .foregroundStyle(Color.subtleText)
                .multilineTextAlignment(.center)
        }
    }

    private var digitFields: some View {
        ZStack {
            // Hidden single TextField that captures all input
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isFieldFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .accentColor(.clear)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: code) { _, newValue in
                    handleCodeChange(newValue)
                }

            // Visual digit boxes
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    DigitBox(
                        character: digitAt(index),
                        isActive: index == code.count && isFieldFocused && !isConnecting,
                        isError: showError,
                        isDisabled: isConnecting
                    )
                }
            }
            .offset(x: shakeOffset)
            .contentShape(Rectangle())
            .onTapGesture {
                isFieldFocused = true
            }
        }
        .onAppear {
            isFieldFocused = true
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
        Text("Run `node server.js` in the bridge folder to start")
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Color.subtleText)
            .multilineTextAlignment(.center)
            .padding(.bottom, 16)
    }

    // MARK: - Logic

    private func digitAt(_ index: Int) -> Character? {
        guard index < code.count else { return nil }
        return code[code.index(code.startIndex, offsetBy: index)]
    }

    private func handleCodeChange(_ newValue: String) {
        // Only allow digits, max 6
        let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
        if filtered != code {
            code = filtered
        }

        // Clear error state on new input
        if showError {
            withAnimation(.easeOut(duration: 0.2)) {
                showError = false
                errorMessage = ""
            }
        }

        // Auto-submit when all 6 digits entered
        if code.count == 6 && !isConnecting {
            submitCode(code)
        }
    }

    private func submitCode(_ code: String) {
        isConnecting = true
        isFieldFocused = false

        Task {
            do {
                try await relayService.pair(code: code)
                print("[PairingView] Pair succeeded, isPaired=\(relayService.isPaired)")
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
        code = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isFieldFocused = true
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

// MARK: - Digit Box (display only)

private struct DigitBox: View {

    let character: Character?
    let isActive: Bool
    let isError: Bool
    let isDisabled: Bool

    var body: some View {
        Text(character.map(String.init) ?? "")
            .font(.system(size: 28, weight: .bold, design: .monospaced))
            .foregroundStyle(isError ? .red : Color.claudeOrange)
            .frame(width: 48, height: 56)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isError ? .red : (isActive ? Color.claudeOrange : Color.fieldBorder),
                        lineWidth: isActive ? 2 : 1
                    )
            )
            .opacity(isDisabled ? 0.4 : 1.0)
    }
}

// MARK: - Preview

#Preview {
    PairingView()
        .environmentObject(RelayService.shared)
}
