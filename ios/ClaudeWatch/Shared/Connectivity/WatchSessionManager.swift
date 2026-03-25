import Foundation
import WatchConnectivity
import Combine

/// Shared WCSession delegate used by both the iOS and watchOS targets.
/// Manages session activation, reachability, message sending with automatic
/// fallback to `transferUserInfo`, and application context updates.
///
/// Conforms to `ObservableObject` so SwiftUI views can observe connectivity changes.
final class WatchSessionManager: NSObject, ObservableObject {

    // MARK: - Singleton

    static let shared = WatchSessionManager()

    // MARK: - Published properties

    @Published private(set) var isReachable: Bool = false
    @Published private(set) var isActivated: Bool = false
    @Published private(set) var lastReceivedState: SessionState?

    // MARK: - Callbacks

    /// Called when a `WatchMessage` is received from the counterpart.
    var onMessageReceived: ((WatchMessage) -> Void)?

    /// Called when the application context is updated by the counterpart.
    var onApplicationContextReceived: (([String: Any]) -> Void)?

    // MARK: - Private

    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }

    private override init() {
        super.init()
    }

    // MARK: - Activation

    /// Activates the WCSession. Call this early in the app lifecycle
    /// (e.g., in `App.init()` or `application(_:didFinishLaunchingWithOptions:)`).
    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    // MARK: - Sending

    /// Sends a `WatchMessage` to the counterpart.
    ///
    /// If the counterpart is reachable, uses `sendMessage` for real-time delivery.
    /// Otherwise falls back to `transferUserInfo` which queues for delivery when
    /// the counterpart is next reachable.
    ///
    /// - Parameters:
    ///   - message: The `WatchMessage` to send.
    ///   - replyHandler: Optional closure invoked with the reply dictionary.
    ///   - errorHandler: Optional closure invoked on failure.
    func send(
        _ message: WatchMessage,
        replyHandler: (([String: Any]) -> Void)? = nil,
        errorHandler: ((Error) -> Void)? = nil
    ) {
        guard let session else {
            errorHandler?(WatchSessionError.sessionNotSupported)
            return
        }

        let dictionary = message.toDictionary()

        if session.isReachable {
            session.sendMessage(dictionary, replyHandler: replyHandler) { error in
                // sendMessage failed; fall back to transferUserInfo
                session.transferUserInfo(dictionary)
                errorHandler?(error)
            }
        } else {
            session.transferUserInfo(dictionary)
        }
    }

    /// Updates the application context with the current connection state.
    /// Application context is delivered lazily -- only the most recent value
    /// is kept, which makes it ideal for connection/session state.
    func updateApplicationContext(with state: SessionState) {
        guard let session else { return }

        let message = WatchMessage.sessionStateUpdate(state)
        let dictionary = message.toDictionary()

        do {
            try session.updateApplicationContext(dictionary)
        } catch {
            // Application context update failed; log and continue.
            print("[WatchSessionManager] Failed to update application context: \(error)")
        }
    }

    #if os(iOS)
    /// Transfers complication user info to the watch.
    /// Only available on iOS; the watch reads this via `didReceiveUserInfo`.
    func transferComplicationUserInfo(_ state: SessionState) {
        guard let session else { return }

        let message = WatchMessage.sessionStateUpdate(state)
        let dictionary = message.toDictionary()

        session.transferCurrentComplicationUserInfo(dictionary)
    }
    #endif

    // MARK: - Errors

    enum WatchSessionError: LocalizedError {
        case sessionNotSupported

        var errorDescription: String? {
            switch self {
            case .sessionNotSupported:
                return "WCSession is not supported on this device."
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {

    // MARK: Activation

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.isActivated = activationState == .activated
            self.isReachable = session.isReachable
        }

        if let error {
            print("[WatchSessionManager] Activation failed: \(error)")
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in
            self.isActivated = false
        }
    }

    func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            self.isActivated = false
            self.isReachable = false
        }
        // Re-activate for multi-watch switching support
        session.activate()
    }
    #endif

    // MARK: Reachability

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
        }
    }

    // MARK: Receiving messages

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        handleIncoming(dictionary: message)
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        handleIncoming(dictionary: message)
        replyHandler(["status": "received"])
    }

    // MARK: Receiving user info (transferUserInfo fallback)

    func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        handleIncoming(dictionary: userInfo)
    }

    // MARK: Application context

    func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        handleIncoming(dictionary: applicationContext)
        onApplicationContextReceived?(applicationContext)
    }

    // MARK: - Private helpers

    private func handleIncoming(dictionary: [String: Any]) {
        do {
            let message = try WatchMessage(from: dictionary)

            // If it's a session state update, publish it
            if case .sessionStateUpdate(let state) = message {
                Task { @MainActor in
                    self.lastReceivedState = state
                }
            }

            onMessageReceived?(message)
        } catch {
            print("[WatchSessionManager] Failed to decode incoming message: \(error)")
        }
    }
}
