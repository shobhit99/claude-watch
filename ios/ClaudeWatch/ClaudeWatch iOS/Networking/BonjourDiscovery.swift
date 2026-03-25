import Foundation
import Network

/// Discovers `_claude-watch._tcp` services on the local network using NWBrowser.
/// Requires the local network privacy entitlement on iOS 14+.
final class BonjourDiscovery: ObservableObject {

    // MARK: - Types

    struct DiscoveredService {
        let name: String
        let host: String
        let port: UInt16
        let machineName: String?
    }

    enum DiscoveryError: LocalizedError {
        case timeout
        case noServiceFound
        case permissionDenied
        case browsingFailed(String)

        var errorDescription: String? {
            switch self {
            case .timeout:
                return "Discovery timed out after 5 seconds."
            case .noServiceFound:
                return "No Claude Watch bridge found on your network."
            case .permissionDenied:
                return "Local network access was denied. Enable it in Settings > Privacy > Local Network."
            case .browsingFailed(let reason):
                return "Browsing failed: \(reason)"
            }
        }
    }

    // MARK: - Properties

    @Published private(set) var discoveredServices: [DiscoveredService] = []
    @Published private(set) var isSearching: Bool = false

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.claudewatch.bonjour", qos: .userInitiated)

    // MARK: - Discovery

    /// Searches for the bridge service on LAN with a 5-second timeout.
    /// Falls back to localhost:7860 if Bonjour fails (common on simulator).
    @MainActor
    func discover() async throws -> DiscoveredService {
        isSearching = true
        defer { isSearching = false }

        // Try Bonjour first, fall back to localhost
        do {
            return try await bonjourDiscover()
        } catch {
            print("[BonjourDiscovery] Bonjour failed (\(error.localizedDescription)), trying localhost fallback...")
            return try await localhostFallback()
        }
    }

    /// Tries to connect to localhost:7860-7869 directly.
    private func localhostFallback() async throws -> DiscoveredService {
        for port in UInt16(7860)...UInt16(7869) {
            let url = URL(string: "http://127.0.0.1:\(port)/status")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    return DiscoveredService(
                        name: "localhost",
                        host: "127.0.0.1",
                        port: port,
                        machineName: ProcessInfo.processInfo.hostName
                    )
                }
            } catch {
                continue
            }
        }
        throw DiscoveryError.noServiceFound
    }

    /// Bonjour-based discovery.
    private func bonjourDiscover() async throws -> DiscoveredService {
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let lock = NSLock()

            func resume(with result: Result<DiscoveredService, Error>) {
                lock.lock()
                guard !hasResumed else {
                    lock.unlock()
                    return
                }
                hasResumed = true
                lock.unlock()
                stopBrowsing()
                continuation.resume(with: result)
            }

            let descriptor = NWBrowser.Descriptor.bonjour(type: "_claude-watch._tcp", domain: nil)
            let parameters = NWParameters()
            parameters.includePeerToPeer = true

            let newBrowser = NWBrowser(for: descriptor, using: parameters)
            self.browser = newBrowser

            newBrowser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    let message = error.localizedDescription
                    if message.lowercased().contains("denied") || message.lowercased().contains("permission") {
                        resume(with: .failure(DiscoveryError.permissionDenied))
                    } else {
                        resume(with: .failure(DiscoveryError.browsingFailed(message)))
                    }
                case .cancelled:
                    // Only fail if we haven't already resumed
                    resume(with: .failure(DiscoveryError.noServiceFound))
                default:
                    break
                }
            }

            newBrowser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case let .service(name, type, domain, _) = result.endpoint {
                        // Resolve the endpoint to get host:port
                        self.resolve(name: name, type: type, domain: domain) { service in
                            if let service {
                                resume(with: .success(service))
                            }
                        }
                    }
                }
            }

            newBrowser.start(queue: self.queue)

            // 5-second timeout
            self.queue.asyncAfter(deadline: .now() + 5.0) {
                resume(with: .failure(DiscoveryError.timeout))
            }
        }
    }

    /// Stops any active browsing.
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    // MARK: - Resolution

    private func resolve(
        name: String,
        type: String,
        domain: String,
        completion: @escaping (DiscoveredService?) -> Void
    ) {
        let connection = NWConnection(
            to: .service(name: name, type: type, domain: domain, interface: nil),
            using: .tcp
        )

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let endpoint = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = endpoint {
                    // Strip interface scope suffix (e.g. "192.168.1.4%en0" → "192.168.1.4")
                    var hostString = "\(host)"
                    if let pctIndex = hostString.firstIndex(of: "%") {
                        hostString = String(hostString[..<pctIndex])
                    }
                    let service = DiscoveredService(
                        name: name,
                        host: hostString,
                        port: port.rawValue,
                        machineName: name
                    )
                    completion(service)
                } else {
                    completion(nil)
                }
                connection.cancel()
            case .failed, .cancelled:
                completion(nil)
            default:
                break
            }
        }

        connection.start(queue: queue)

        // Resolution timeout
        queue.asyncAfter(deadline: .now() + 3.0) {
            connection.cancel()
        }
    }
}
