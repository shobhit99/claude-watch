import SwiftUI

struct CodexLogo: View {
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            CodexBackgroundShape()
                .fill(Color.white)
                .frame(width: size, height: size)
            CodexInnerShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "B1A7FF"),
                            Color(hex: "7A9DFF"),
                            Color(hex: "3941FF"),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size, height: size)
        }
    }
}

/// Rounded rectangle background from the Codex SVG.
struct CodexBackgroundShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        let t = CGAffineTransform(scaleX: sx, y: sy)

        var p = Path()
        // M19.503 0H4.496A4.496 4.496 0 000 4.496v15.007A4.496 4.496 0 004.496 24h15.007A4.496 4.496 0 0024 19.503V4.496A4.496 4.496 0 0019.503 0z
        p.addRoundedRect(
            in: CGRect(x: 0, y: 0, width: 24, height: 24).applying(t),
            cornerSize: CGSize(width: 4.496 * sx, height: 4.496 * sy)
        )
        return p
    }
}

/// The inner icon path from the Codex SVG (the ">_" terminal prompt).
struct CodexInnerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 24
        let sy = rect.height / 24
        let t = CGAffineTransform(scaleX: sx, y: sy)

        var p = Path()

        // Outer blob (the organic shape)
        p.move(to: CGPoint(x: 9.064, y: 3.344).applying(t))

        // This is a complex SVG path with curves. For the Codex icon,
        // the key recognizable elements are:
        // 1. The organic blob background
        // 2. The ">_" prompt characters
        //
        // We'll render the full SVG path data.

        // Organic blob outline (simplified as the full path with curves)
        let blobPoints: [(Double, Double)] = [
            (9.064, 3.344), (11.349, 3.032), (12.349, 3.147),
            (14.24, 3.687), (14.912, 4.422), (14.949, 4.443),
            (14.992, 4.443), (18.038, 4.718), (18.085, 4.74),
            (18.201, 4.797), (20.389, 7.196), (20.704, 7.706),
            (21.019, 8.237), (21.019, 8.791), (20.885, 10.014),
            (20.915, 10.129), (21.509, 10.736), (22.098, 11.299),
            (22.692, 12.906), (21.805, 14.593), (21.669, 14.759),
            (19.468, 16.147), (19.387, 16.223), (19.196, 16.774),
            (18.813, 17.797), (18.073, 18.268), (17.173, 19.455),
            (14.951, 21.106), (13.462, 21.1), (12.275, 21.094),
            (11.036, 20.66), (10.118, 19.798), (10.013, 19.774),
            (9.625, 19.899), (8.845, 19.917), (7.641, 19.779),
            (5.696, 18.446), (5.544, 18.244), (5.241, 17.852),
            (4.827, 17.235), (4.457, 16.274), (4.443, 13.976),
            (4.449, 13.92), (4.422, 13.872), (3.388, 12.221),
            (3.137, 11.029), (3.137, 9.837), (3.278, 8.237),
            (3.615, 7.125), (4.26, 6.252), (5.211, 5.619),
            (5.423, 5.478), (5.624, 5.368), (5.857, 5.289),
            (6.072, 5.2), (6.287, 5.125), (6.503, 5.062),
            (6.568, 4.996), (7.397, 3.447), (9.064, 3.344),
        ]

        // For accuracy, use the simplified recognizable shapes instead:
        // The horizontal bar (the underscore/cursor): M12.546 13.909 to h3.636 rounded
        // The chevron (>): the angled lines

        // Horizontal bar: rect at y≈13.9, h≈1.27
        let barY = 13.909 * sy
        let barX = 12.546 * sx
        let barW = 3.636 * sx
        let barH = 1.272 * sy
        let barR = 0.637 * min(sx, sy)
        p.addRoundedRect(
            in: CGRect(x: barX, y: barY, width: barW, height: barH),
            cornerSize: CGSize(width: barR, height: barR)
        )

        // Chevron (>) — the left-pointing angle bracket
        // From SVG: M8.462 9.23 → line to (9.734, 11.454) → line to (8.468, 13.59)
        // This is the ">" character
        let chevronPath = Path { cp in
            cp.move(to: CGPoint(x: 8.1 * sx, y: 9.0 * sy))
            cp.addLine(to: CGPoint(x: 10.0 * sx, y: 11.85 * sy))
            cp.addLine(to: CGPoint(x: 8.1 * sx, y: 14.65 * sy))
        }
        p.addPath(chevronPath.strokedPath(StrokeStyle(lineWidth: 1.3 * min(sx, sy), lineCap: .round, lineJoin: .round)))

        return p
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
