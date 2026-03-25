import SwiftUI

// MARK: - OnboardingView

/// First-launch view shown when the watch is not yet paired with the iPhone app.
struct OnboardingView: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Theme.Background.primary.ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()

                // Large mascot placeholder (48pt)
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.Text.primary)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Text("C")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                    )
                    .scaleEffect(isPulsing ? 1.08 : 1.0)
                    .opacity(isPulsing ? 0.8 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                        value: isPulsing
                    )

                Text("Welcome to\nClaude Watch")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Theme.Text.primary)
                    .multilineTextAlignment(.center)

                Text("Open the Claude Watch app on your iPhone and pair with your Mac")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Text.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                Spacer()

                // Waiting indicator
                HStack(spacing: 6) {
                    ProgressView()
                        .tint(Theme.Text.secondary)
                        .scaleEffect(0.8)

                    Text("Waiting for connection...")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Text.secondary)
                }

                Spacer()
                    .frame(height: 8)
            }
            .padding(.horizontal, 12)
        }
        .onAppear {
            isPulsing = true
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingView()
}
