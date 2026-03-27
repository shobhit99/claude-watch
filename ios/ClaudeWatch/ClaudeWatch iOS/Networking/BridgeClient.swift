import Foundation

/// HTTP client for communicating with the Claude Watch bridge server.
final class BridgeClient {

    // MARK: - Errors

    enum BridgeError: LocalizedError {
        case invalidCode
        case expired
        case rateLimited
        case networkError
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidCode:      return "Invalid pairing code."
            case .expired:          return "Pairing code expired."
            case .rateLimited:      return "Too many attempts. Try again later."
            case .networkError:     return "Cannot reach bridge server."
            case .serverError(let msg): return msg
            }
        }
    }

    // MARK: - Properties

    private(set) var baseURL: URL?
    private(set) var token: String?

    private let session: URLSession

    // MARK: - Init

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)

        // Restore saved token
        self.token = UserDefaults.standard.string(forKey: "bridge_token")
        if let saved = UserDefaults.standard.string(forKey: "bridge_url") {
            self.baseURL = URL(string: saved)
        }
    }

    // MARK: - Configuration

    func configure(host: String, port: UInt16) {
        let urlString = "http://\(host):\(port)"
        self.baseURL = URL(string: urlString)
        UserDefaults.standard.set(urlString, forKey: "bridge_url")
    }

    var isPaired: Bool {
        token != nil && baseURL != nil
    }

    func clearCredentials() {
        token = nil
        baseURL = nil
        UserDefaults.standard.removeObject(forKey: "bridge_token")
        UserDefaults.standard.removeObject(forKey: "bridge_url")
    }

    // MARK: - Pairing

    /// Pairs with the bridge using a 6-digit code.
    /// On success, stores the session token.
    @discardableResult
    func pair(code: String) async throws -> String {
        guard let baseURL else {
            throw BridgeError.networkError
        }

        let url = baseURL.appendingPathComponent("pair")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": code])

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgeError.networkError
        }

        switch httpResponse.statusCode {
        case 200:
            let result = try JSONDecoder().decode(PairResponse.self, from: data)
            self.token = result.token
            UserDefaults.standard.set(result.token, forKey: "bridge_token")
            return result.token

        case 401:
            let body = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if body?.error.contains("expired") == true {
                throw BridgeError.expired
            }
            throw BridgeError.invalidCode

        case 429:
            throw BridgeError.rateLimited

        default:
            let body = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw BridgeError.serverError(body?.error ?? "Unknown error (HTTP \(httpResponse.statusCode))")
        }
    }

    // MARK: - Commands

    /// Sends a text command to a specific session's PTY.
    func sendCommand(text: String, sessionId: String? = nil) async throws {
        var body: [String: Any] = ["command": text]
        if let sid = sessionId { body["sessionId"] = sid }
        try await authenticatedPostRaw(path: "command", body: body)
    }

    /// Spawns a new agent session.
    func spawnSession(agent: String, cwd: String? = nil) async throws -> String {
        var body: [String: Any] = ["spawn": agent]
        if let cwd { body["cwd"] = cwd }
        guard let baseURL, let token else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent("command")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError.serverError("Failed to spawn session")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["sessionId"] as? String ?? ""
    }

    /// Responds to an approval request.
    func respondToApproval(requestId: String, allow: Bool) async throws {
        var decision: [String: Any] = [
            "behavior": allow ? "allow" : "deny"
        ]
        if !allow {
            decision["message"] = "Denied from Agent Watch app"
        }
        let body: [String: Any] = [
            "permissionId": requestId,
            "decision": decision
        ]
        try await authenticatedPostRaw(path: "command", body: body)
    }

    /// Responds with "allow" + adds a permission rule so it doesn't ask again this session.
    func respondToApprovalAllowAll(requestId: String) async throws {
        let decision: [String: Any] = [
            "behavior": "allow"
        ]
        let body: [String: Any] = [
            "permissionId": requestId,
            "decision": decision,
            "allowAll": true
        ]
        try await authenticatedPostRaw(path: "command", body: body)
    }

    // MARK: - Status

    /// Fetches the current bridge status.
    func fetchStatus() async throws -> BridgeStatus {
        guard let baseURL else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent("status")
        let request = URLRequest(url: url)
        let (data, _) = try await performRequest(request)
        return try JSONDecoder().decode(BridgeStatus.self, from: data)
    }

    // MARK: - SSE URL

    /// Returns the URL for the SSE events endpoint, including auth.
    func eventsURL() -> URL? {
        guard let baseURL, let token else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("events"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url
    }

    // MARK: - Private helpers

    private func authenticatedPost(path: String, body: [String: String]) async throws {
        guard let baseURL, let token else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw BridgeError.serverError("Request failed")
        }
    }

    private func authenticatedPostRaw(path: String, body: [String: Any]) async throws {
        guard let baseURL, let token else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw BridgeError.serverError("Request failed")
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw BridgeError.networkError
        }
    }

    // MARK: - Response types

    private struct PairResponse: Decodable {
        let token: String
        let sessionId: String?
        let bridgeId: String?
        let availableAgents: [String]?
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    struct BridgeStatus: Decodable {
        let state: String
        let sessionId: String?
        let bridgeId: String?
        let hasPty: Bool
        let activeAgent: String?
        let availableAgents: [String]?
        let sessions: [BridgeSessionInfo]?
        let sseClients: Int
        let pendingPermissions: Int
        let eventBufferSize: Int
    }

    struct BridgeSessionInfo: Decodable {
        let id: String
        let agent: String
        let cwd: String
        let folderName: String
        let state: String
    }
}
