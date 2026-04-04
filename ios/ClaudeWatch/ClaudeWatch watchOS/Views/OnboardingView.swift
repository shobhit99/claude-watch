import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var session: WatchViewState
    @StateObject private var bridge = WatchBridgeClient.shared

    @State private var code = ""
    @State private var endpointInput = ""
    @State private var ingressToken = UserDefaults.standard.string(forKey: "watch_bridge_ingress_token") ?? ""
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
                AppLogo(size: 22)
                Text("Agent Watch")
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

                SecureField("Ingress Bearer token (optional)", text: $ingressToken)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.Text.primary)
                    .multilineTextAlignment(.center)

            } else {
                // Not found — IP entry right away
                Text("Enter bridge endpoint")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Text.secondary)

                Text("Supports IP or full URL")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.Text.dimmed)

                TextField("https://xxx.trycloudflare.com or 192.168.1.x", text: $endpointInput)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.Text.primary)
                    .multilineTextAlignment(.center)
                    .focused($ipFocused)

                SecureField("Ingress Bearer token (optional)", text: $ingressToken)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.Text.primary)
                    .multilineTextAlignment(.center)

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
                .disabled(endpointInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
        let input = endpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        bridge.setIngressToken(ingressToken)
        isSearching = true
        error = nil

        Task {
            if let directURL = normalizedEndpointURL(input) {
                let statusURL = directURL.appendingPathComponent("status")
                var request = URLRequest(url: statusURL)
                request.timeoutInterval = 3
                if let token = bridge.ingressToken, !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        await MainActor.run {
                            isSearching = false
                            bridgeURL = directURL
                            codeFocused = true
                        }
                        return
                    }
                } catch {
                    // ignore and fallback to error
                }
            } else {
                for port in 7860...7869 {
                    let url = URL(string: "http://\(input):\(port)/status")!
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 3
                    if let token = bridge.ingressToken, !token.isEmpty {
                        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                            await MainActor.run {
                                isSearching = false
                                bridgeURL = URL(string: "http://\(input):\(port)")
                                codeFocused = true
                            }
                            return
                        }
                    } catch { continue }
                }
            }
            await MainActor.run {
                isSearching = false
                self.error = "Cannot reach: \(input)"
            }
        }
    }

    private func normalizedEndpointURL(_ input: String) -> URL? {
        if let url = URL(string: input),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           url.host != nil {
            return stripPath(from: url)
        }

        if input.contains("://") {
            return nil
        }

        if input.contains(":"),
           let httpURL = URL(string: "http://\(input)"),
           httpURL.host != nil {
            return stripPath(from: httpURL)
        }

        if input.contains("."),
           !isLikelyIPv4(input),
           let httpsURL = URL(string: "https://\(input)"),
           httpsURL.host != nil {
            return stripPath(from: httpsURL)
        }

        return nil
    }

    private func stripPath(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func isLikelyIPv4(_ value: String) -> Bool {
        let segments = value.split(separator: ".")
        guard segments.count == 4 else { return false }
        return segments.allSatisfy { seg in
            guard let num = Int(seg), (0...255).contains(num) else { return false }
            return true
        }
    }

    private func searchForBridge() {
        bridge.setIngressToken(ingressToken)
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
        bridge.setIngressToken(ingressToken)
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
                        transportMode: transportMode(for: url)
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

    private func transportMode(for url: URL) -> SessionState.TransportMode {
        guard let host = url.host?.lowercased() else { return .lan }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return .lan
        }
        if isLikelyIPv4(host) {
            let parts = host.split(separator: ".").compactMap { Int($0) }
            if parts.count == 4 {
                if parts[0] == 10 { return .lan }
                if parts[0] == 192 && parts[1] == 168 { return .lan }
                if parts[0] == 172 && (16...31).contains(parts[1]) { return .lan }
            }
        }
        return .remote
    }
}

#Preview { OnboardingView().environmentObject(WatchViewState.shared) }
