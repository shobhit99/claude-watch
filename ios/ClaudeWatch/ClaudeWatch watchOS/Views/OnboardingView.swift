import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var session: WatchViewState
    @StateObject private var bridge = WatchBridgeClient.shared

    @State private var code = ""
    @State private var ipAddress = ""
    @State private var isSearching = false
    @State private var isConnecting = false
    @State private var error: String?
    @State private var bridgeURL: URL?
    @FocusState private var codeFocused: Bool
    @FocusState private var ipFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            // Compact header — one line
            HStack(spacing: 4) {
                ClaudeMascot(size: 16)
                Text("Claude Watch")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.Text.primary)
            }

            if isSearching {
                Spacer()
                ProgressView()
                    .tint(Theme.Text.secondary)
                Text("Searching...")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Text.secondary)
                Spacer()

            } else if bridgeURL != nil {
                // Bridge found — code entry
                Text("Enter code from Mac")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Text.secondary)

                TextField("000000", text: $code)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Text.primary)
                    .multilineTextAlignment(.center)
                    .textContentType(.oneTimeCode)
                    .focused($codeFocused)
                    .onChange(of: code) { _, newValue in
                        let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
                        if filtered != newValue { code = filtered }
                        if filtered.count == 6 { submitCode(filtered) }
                    }

                if isConnecting {
                    ProgressView()
                        .tint(Theme.Text.primary)
                        .scaleEffect(0.7)
                }

            } else {
                // Not found — IP entry right away
                Text("Enter Mac IP")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Text.secondary)

                Text("Wi-Fi not required — routes via iPhone")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.Text.dimmed)

                TextField("192.168.1.x", text: $ipAddress)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Text.primary)
                    .multilineTextAlignment(.center)
                    .focused($ipFocused)

                Button { connectManual() } label: {
                    Text("Connect")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Theme.Text.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(ipAddress.isEmpty)

                Button("Retry auto") { searchForBridge() }
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Text.secondary)
            }

            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.Accent.error)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Background.primary)
        .onAppear {
            searchForBridge()
        }
    }

    private func connectManual() {
        let ip = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { return }
        isSearching = true
        error = nil

        Task {
            for port in 7860...7869 {
                let url = URL(string: "http://\(ip):\(port)/status")!
                var request = URLRequest(url: url)
                request.timeoutInterval = 3
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        await MainActor.run {
                            isSearching = false
                            bridgeURL = URL(string: "http://\(ip):\(port)")
                            codeFocused = true
                        }
                        return
                    }
                } catch { continue }
            }
            await MainActor.run {
                isSearching = false
                self.error = "Can't reach \(ip)"
            }
        }
    }

    private func searchForBridge() {
        isSearching = true
        error = nil
        Task {
            let url = await bridge.discover()
            await MainActor.run {
                isSearching = false
                bridgeURL = url
                if url != nil { codeFocused = true }
                else { ipFocused = true }
            }
        }
    }

    private func submitCode(_ code: String) {
        guard let url = bridgeURL, !isConnecting else { return }
        isConnecting = true
        error = nil

        Task {
            do {
                try await bridge.pair(baseURL: url, code: code)
                await MainActor.run {
                    session.isPaired = true
                    session.sessionState = SessionState(
                        connection: .connected, activity: .idle,
                        machineName: "Mac", modelName: nil,
                        workingDirectory: nil,
                        elapsedSeconds: 0, filesChanged: 0, linesAdded: 0,
                        transportMode: .lan
                    )
                    session.appendLine(TerminalLine(text: "Connected to bridge", type: .system))
                    session.startEventStream()
                }
            } catch {
                await MainActor.run {
                    self.isConnecting = false
                    self.error = error.localizedDescription
                    self.code = ""
                }
            }
        }
    }
}

#Preview { OnboardingView().environmentObject(WatchViewState.shared) }
