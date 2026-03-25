import WatchKit

// MARK: - HapticManager

/// Static haptic feedback methods for common watch interactions.
enum HapticManager {

    /// Task completed successfully.
    static func taskComplete() {
        WKInterfaceDevice.current().play(.success)
    }

    /// An approval decision is needed from the user.
    static func approvalNeeded() {
        WKInterfaceDevice.current().play(.notification)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            WKInterfaceDevice.current().play(.directionUp)
        }
    }

    /// An error occurred.
    static func error() {
        WKInterfaceDevice.current().play(.failure)
    }

    /// A voice command was sent successfully.
    static func commandSent() {
        WKInterfaceDevice.current().play(.click)
    }

    /// Connection to the iPhone/Mac was lost.
    static func connectionLost() {
        WKInterfaceDevice.current().play(.retry)
    }
}
