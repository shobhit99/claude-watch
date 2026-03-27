import SwiftUI

// MARK: - Design Tokens (watchOS)

enum Theme {
    enum Background {
        static let primary = Color(hex: "000000")
        static let capture = Color(hex: "1a2233")
        static let overlay = Color(hex: "1a1a1a")
    }

    enum Text {
        static let primary = Color(hex: "E87A35")
        static let secondary = Color(hex: "666666")
        static let dimmed = Color(hex: "555555")
    }

    enum Accent {
        static let success = Color(hex: "34C759")
        static let error = Color(hex: "FF3B30")
        static let approval = Color(hex: "E8A735")
    }
}

// MARK: - App Entry Point

@main
struct ClaudeWatchWatchApp: App {
    @StateObject private var sessionManager = WatchViewState.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if sessionManager.isPaired {
                    MultiSessionPager()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(sessionManager)
        }
    }

}
