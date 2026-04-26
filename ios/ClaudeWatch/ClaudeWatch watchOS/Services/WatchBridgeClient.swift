import Foundation

/// Lightweight HTTP client for the watch to connect directly to the bridge.
/// Works in simulator (localhost) and on real hardware (LAN).
class WatchBridgeClient: ObservableObject {
    static let shared = WatchBridgeClient()

    @Published var baseURL: URL?
    @Published var token: String?
    @Published var ingressToken: String?

    var isPaired: Bool { token != nil && baseURL != nil }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    init() {
        // Restore saved credentials
        if let url = UserDefaults.standard.string(forKey: "watch_bridge_url") {
            baseURL = URL(string: url)
        }
        token = UserDefaults.standard.string(forKey: "watch_bridge_token")
        ingressToken = UserDefaults.standard.string(forKey: "watch_bridge_ingress_token")
    }

    /// Discover bridge via Bonjour on LAN, fallback to localhost (simulator)
    func discover() async -> URL? {
        // Try Bonjour first (works on real watch over Wi-Fi)
        if let url = await discoverBonjour() { return url }
        #if targetEnvironment(simulator)
        // Localhost only works in simulator
        return await discoverLocalhost()
        #else
        // On real device, localhost won't work — return nil to trigger manual IP entry
        return nil
        #endif
    }

    private func discoverBonjour() async -> URL? {
        await withCheckedContinuation { continuation in
            let browser = BonjourBrowser()
            browser.search { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func discoverLocalhost() async -> URL? {
        for port in UInt16(7860)...UInt16(7869) {
            let url = URL(string: "http://127.0.0.1:\(port)/status")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let ingressToken, !ingressToken.isEmpty {
                request.setValue("Bearer \(ingressToken)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (_, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return URL(string: "http://127.0.0.1:\(port)")!
                }
            } catch { continue }
        }
        return nil
    }

    /// Pair with bridge using 6-digit code
    func pair(baseURL: URL, code: String) async throws {
        let url = baseURL.appendingPathComponent("pair")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let ingressToken, !ingressToken.isEmpty {
            request.setValue("Bearer \(ingressToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(["code": code])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BridgeError.network }

        if http.statusCode == 200 {
            let result = try JSONDecoder().decode(PairResponse.self, from: data)
            self.baseURL = baseURL
            self.token = result.token
            UserDefaults.standard.set(baseURL.absoluteString, forKey: "watch_bridge_url")
            UserDefaults.standard.set(result.token, forKey: "watch_bridge_token")
        } else if http.statusCode == 429 {
            throw BridgeError.rateLimited
        } else if http.statusCode == 404, ingressToken != nil {
            throw BridgeError.unauthorized
        } else if http.statusCode == 401 {
            let body = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if body?.error.lowercased().contains("unauthorized") == true {
                throw BridgeError.unauthorized
            }
            throw BridgeError.invalidCode
        } else {
            throw BridgeError.invalidCode
        }
    }

    /// Fetch latest events from bridge (polling — simpler than SSE for watch)
    func fetchEvents(since lastEventId: Int = 0) async throws -> [BridgeEvent] {
        guard let baseURL, let token else { throw BridgeError.notPaired }
        let url = baseURL.appendingPathComponent("status")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        let status = try JSONDecoder().decode(BridgeStatus.self, from: data)
        return [BridgeEvent(state: status.state, hasPty: status.hasPty)]
    }

    func unpair() {
        token = nil
        baseURL = nil
        UserDefaults.standard.removeObject(forKey: "watch_bridge_url")
        UserDefaults.standard.removeObject(forKey: "watch_bridge_token")
    }

    func setIngressToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ingressToken = trimmed.isEmpty ? nil : trimmed
        if let ingressToken {
            UserDefaults.standard.set(ingressToken, forKey: "watch_bridge_ingress_token")
        } else {
            UserDefaults.standard.removeObject(forKey: "watch_bridge_ingress_token")
        }
    }

    // MARK: - Types

    enum BridgeError: LocalizedError {
        case network, invalidCode, rateLimited, unauthorized, notPaired
        var errorDescription: String? {
            switch self {
            case .network: return "Can't reach bridge"
            case .invalidCode: return "Wrong code"
            case .rateLimited: return "Too many attempts"
            case .unauthorized: return "Bearer token invalid or missing"
            case .notPaired: return "Not paired"
            }
        }
    }

    struct ErrorResponse: Decodable {
        let error: String
    }

    struct PairResponse: Decodable {
        let token: String
        let sessionId: String
    }

    struct BridgeStatus: Decodable {
        let state: String
        let sessionId: String
        let hasPty: Bool
        let sseClients: Int
        let pendingPermissions: Int
        let eventBufferSize: Int
    }

    struct BridgeEvent {
        let state: String
        let hasPty: Bool
    }
}

// MARK: - Bonjour Browser for watchOS

import Network

private class BonjourBrowser {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.claudewatch.bonjour.watch")

    func search(completion: @escaping (URL?) -> Void) {
        var hasCompleted = false

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_claude-watch._tcp", domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true

        let b = NWBrowser(for: descriptor, using: params)
        self.browser = b

        b.browseResultsChangedHandler = { results, _ in
            guard !hasCompleted else { return }
            for result in results {
                if case let .service(name, type, domain, _) = result.endpoint {
                    // Resolve via NWConnection
                    let conn = NWConnection(
                        to: .service(name: name, type: type, domain: domain, interface: nil),
                        using: .tcp
                    )
                    conn.stateUpdateHandler = { state in
                        if case .ready = state {
                            if let endpoint = conn.currentPath?.remoteEndpoint,
                               case let .hostPort(host, port) = endpoint {
                                var hostStr = "\(host)"
                                if let pct = hostStr.firstIndex(of: "%") {
                                    hostStr = String(hostStr[..<pct])
                                }
                                let url = URL(string: "http://\(hostStr):\(port.rawValue)")
                                hasCompleted = true
                                conn.cancel()
                                b.cancel()
                                completion(url)
                            }
                        }
                    }
                    conn.start(queue: self.queue)
                    return
                }
            }
        }

        b.stateUpdateHandler = { state in
            if case .failed = state {
                guard !hasCompleted else { return }
                hasCompleted = true
                completion(nil)
            }
        }

        b.start(queue: queue)

        // 5-second timeout
        queue.asyncAfter(deadline: .now() + 5) {
            guard !hasCompleted else { return }
            hasCompleted = true
            b.cancel()
            completion(nil)
        }
    }
}
