import SwiftUI

@main
struct ClaudeWatchApp: App {

    @StateObject private var sessionManager = WatchSessionManager.shared
    @StateObject private var relayService = RelayService.shared

    init() {
        WatchSessionManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if relayService.isPaired {
                    ConnectionStatusView()
                } else {
                    PairingView()
                }
            }
            .environmentObject(sessionManager)
            .environmentObject(relayService)
            .preferredColorScheme(.dark)
        }
    }
}
