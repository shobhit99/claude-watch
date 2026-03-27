import SwiftUI

struct CodexLogo: View {
    var size: CGFloat = 32

    var body: some View {
        Image("CodexIcon")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

#Preview {
    HStack(spacing: 16) {
        CodexLogo(size: 24)
        CodexLogo(size: 32)
        CodexLogo(size: 48)
    }
    .padding()
    .background(Color.black)
}
