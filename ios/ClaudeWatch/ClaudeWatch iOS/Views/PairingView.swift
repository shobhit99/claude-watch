import SwiftUI

struct PairingView: View {

    @EnvironmentObject private var relayService: RelayService

    // MARK: - State

    @State private var code: String = ""
    @State private var endpoint: String = ""
    @State private var showManualIP: Bool = false
    @FocusState private var isCodeFocused: Bool
    @FocusState private var isIPFocused: Bool
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

                if showManualIP {
                    ipEntrySection
                }

                digitFields
                statusSection
                bottomSection

                Spacer()
            }
            .padding(.horizontal, 32)
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

            Text(showManualIP
                 ? "输入桥接地址和配对码"
                 : "Enter the pairing code from your Mac")
                .font(.system(size: 15))
                .foregroundStyle(Color.subtleText)
                .multilineTextAlignment(.center)
        }
    }

    private var ipEntrySection: some View {
        HStack(spacing: 8) {
            TextField("https://xxx.trycloudflare.com 或 192.168.1.x", text: $endpoint)
                .keyboardType(.URL)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .tint(Color.claudeOrange)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.fieldBorder, lineWidth: 1)
                )
                .focused($isIPFocused)
        }
    }

    private var digitFields: some View {
        ZStack {
            // Hidden single TextField that captures all input
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isCodeFocused)
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
                        isActive: index == code.count && isCodeFocused && !isConnecting,
                        isError: showError,
                        isDisabled: isConnecting
                    )
                }
            }
            .offset(x: shakeOffset)
            .contentShape(Rectangle())
            .onTapGesture {
                isCodeFocused = true
            }
        }
        .onAppear {
            if !showManualIP {
                isCodeFocused = true
            }
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

    private var bottomSection: some View {
        VStack(spacing: 12) {
            if !showManualIP {
                Button {
                    withAnimation {
                        showManualIP = true
                        isIPFocused = true
                    }
                } label: {
                    Text("无法自动连接？手动输入地址")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.claudeOrange)
                }
            }

            Text("Run `node server.js` in the bridge folder to start")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.subtleText)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 16)
    }

    // MARK: - Logic

    private func digitAt(_ index: Int) -> Character? {
        guard index < code.count else { return nil }
        return code[code.index(code.startIndex, offsetBy: index)]
    }

    private func handleCodeChange(_ newValue: String) {
        let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
        if filtered != code {
            code = filtered
        }

        if showError {
            withAnimation(.easeOut(duration: 0.2)) {
                showError = false
                errorMessage = ""
            }
        }

        if code.count == 6 && !isConnecting {
            submitCode(code)
        }
    }

    private func submitCode(_ code: String) {
        isConnecting = true
        isCodeFocused = false
        isIPFocused = false

        Task {
            do {
                if showManualIP {
                    let input = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !input.isEmpty else {
                        await MainActor.run {
                            showPairingError("请输入桥接地址（IP 或 URL）。")
                        }
                        return
                    }
                    try await relayService.pairWithEndpoint(input, code: code)
                } else {
                    try await relayService.pair(code: code)
                }
            } catch let error as BridgeClient.BridgeError {
                await MainActor.run { handlePairingError(error) }
            } catch {
                await MainActor.run {
                    let msg = error.localizedDescription
                    // If auto-discovery failed, suggest manual IP
                    if msg.contains("noServiceFound") || msg.contains("timed out") || msg.contains("not found") {
                        showManualIP = true
                        showPairingError("未自动发现桥接服务，请输入 IP 或完整 URL。")
                        isIPFocused = true
                    } else {
                        showPairingError("连接失败：\(msg)")
                    }
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
            if !showManualIP {
                showManualIP = true
                showPairingError("无法连接桥接服务，请输入 IP 或完整 URL。")
                isIPFocused = true
            } else {
                showPairingError("无法连接桥接服务，请检查地址与网络。")
            }
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
            if showManualIP && endpoint.isEmpty {
                isIPFocused = true
            } else {
                isCodeFocused = true
            }
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
