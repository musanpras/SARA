import SwiftUI

/// Visual language for SARA: calm, dark, low-chroma, with a single accent that
/// carries state. Defined once so no view hardcodes a colour.
public enum SARATheme {
    public enum Palette {
        public static let background = Color(red: 0.04, green: 0.05, blue: 0.07)
        public static let surface = Color(red: 0.09, green: 0.10, blue: 0.13)
        public static let surfaceRaised = Color(red: 0.13, green: 0.14, blue: 0.18)
        public static let primaryText = Color(red: 0.94, green: 0.95, blue: 0.97)
        public static let secondaryText = Color(red: 0.58, green: 0.61, blue: 0.68)
        public static let accent = Color(red: 0.45, green: 0.62, blue: 1.00)
        public static let listening = Color(red: 0.36, green: 0.80, blue: 0.70)
        public static let caution = Color(red: 0.98, green: 0.72, blue: 0.35)
        public static let destructive = Color(red: 0.95, green: 0.42, blue: 0.42)
        public static let success = Color(red: 0.42, green: 0.85, blue: 0.58)
    }

    public enum Metrics {
        public static let cornerRadius: CGFloat = 18
        public static let bubbleRadius: CGFloat = 20
        public static let gutter: CGFloat = 20
        public static let stackSpacing: CGFloat = 12
    }

    public enum Typography {
        public static let identity = Font.system(size: 17, weight: .semibold, design: .rounded)
        public static let body = Font.system(size: 16, weight: .regular, design: .rounded)
        public static let caption = Font.system(size: 12, weight: .medium, design: .rounded)
        public static let state = Font.system(size: 13, weight: .medium, design: .rounded)
    }
}
