import SwiftUI

extension Color {

    /// Creates a `Color` from a hex string.
    ///
    /// Supported formats: `"#RRGGBB"`, `"RRGGBB"`, `"#RRGGBBAA"`, `"RRGGBBAA"`.
    /// Returns `Color.clear` for malformed input.
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&rgb)

        let r, g, b, a: Double
        switch sanitized.count {
        case 6: // RRGGBB
            r = Double((rgb >> 16) & 0xFF) / 255.0
            g = Double((rgb >> 8) & 0xFF) / 255.0
            b = Double(rgb & 0xFF) / 255.0
            a = 1.0
        case 8: // RRGGBBAA
            r = Double((rgb >> 24) & 0xFF) / 255.0
            g = Double((rgb >> 16) & 0xFF) / 255.0
            b = Double((rgb >> 8) & 0xFF) / 255.0
            a = Double(rgb & 0xFF) / 255.0
        default:
            r = 0; g = 0; b = 0; a = 0
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    // MARK: - Claude Watch brand colors

    /// Primary orange: #E87A35
    static let claudeOrange = Color(hex: "E87A35")

    /// Amber warning: #E8A735
    static let claudeAmber = Color(hex: "E8A735")

    /// Subtle text: #666666
    static let subtleText = Color(hex: "666666")

    /// Card / field background: #1a1a1a
    static let cardBackground = Color(hex: "1a1a1a")

    /// Border: #333333
    static let fieldBorder = Color(hex: "333333")

    /// Success green: #34C759
    static let statusGreen = Color(hex: "34C759")

    /// Connected pill background: #1a2233
    static let connectedPillBackground = Color(hex: "1a2233")
}
