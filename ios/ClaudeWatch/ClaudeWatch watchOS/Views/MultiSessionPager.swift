import SwiftUI

struct MultiSessionPager: View {
    @EnvironmentObject private var state: WatchViewState

    var body: some View {
        if state.sessions.isEmpty {
            waitingView
        } else {
            TabView(selection: $state.activeSessionIndex) {
                ForEach(Array(state.sessions.enumerated()), id: \.element.id) { index, session in
                    SessionView(agentSession: session)
                        .tag(index)
                }
            }
            .tabViewStyle(.page)
        }
    }

    private var waitingView: some View {
        VStack(spacing: 8) {
            ClaudeMascot(size: 24)
                .opacity(0.6)
            Text("Waiting for session...")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            Text("Start Claude or Codex on your Mac")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.3))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
