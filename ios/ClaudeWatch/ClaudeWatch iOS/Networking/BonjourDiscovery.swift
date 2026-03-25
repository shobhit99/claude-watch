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
    /// Returns the first discovered service, or throws on failure.
    @MainActor
    func discover() async throws -> DiscoveredService {
        isSearching = true
        defer { isSearching = false }

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
                    let service = DiscoveredService(
                        name: name,
                        host: "\(host)",
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
