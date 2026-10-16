import SwiftUI

/// The chart palette.
///
/// Two series, assigned in fixed slot order and validated as a categorical pair against
/// both surfaces. Method: Machado (2009) severity-1.0 simulation of protanopia,
/// deuteranopia and tritanopia, CIEDE2000 between the simulated pair, worst case taken
/// across normal vision and all three; contrast is the WCAG ratio against the card the
/// chart sits on (`secondarySystemGroupedBackground`).
///
/// | | worst-case ΔE2000 | contrast |
/// |---|---|---|
/// | light, on `#FFFFFF` | 21.9 | 9.11 / 3.30 |
/// | dark, on `#1C1C1E` | 28.8 | 3.31 / 12.12 |
///
/// Red against green is the pair colour-vision deficiency punishes hardest — the two
/// hues converge under deuteranopia, and the obvious choice of system red against system
/// green scores 7.9, *below* the ≥ 8 gate, in dark mode. What rescues it is lightness:
/// these two are deliberately far apart in L*, red the darker of the pair on both
/// surfaces, so the bars stay told apart by brightness once the hue is gone. That is
/// also why the light-mode green is a strong mid green rather than a dark one, and the
/// dark-mode green a pale mint. Nudging either toward a "nicer" hue collapses the pair;
/// re-run the numbers before changing them.
enum Palette {
    /// Slot 1 — energy drawn from the grid.
    static let consumption = adaptive(light: 0x8C1D18, dark: 0xCC3333)
    /// Slot 2 — energy fed back to the grid by the inverter.
    static let feedIn = adaptive(light: 0x16A34A, dark: 0x86EFAC)

    /// Slot 3 — cloud cover, which is context rather than energy, so it is deliberately
    /// neutral. Adding it does not narrow the pair: worst-case ΔE2000 stays 21.9 in light
    /// (red/green remains the binding pair) and 25.9 in dark, both past the ≥ 8 gate, and
    /// it clears 5:1 contrast on both surfaces.
    static let cloud = adaptive(light: 0x6E6E73, dark: 0x8E8E93)

    /// The hours the sun was down. A system fill, so it shades on both surfaces without
    /// having to guess which way "dimmer" runs against the card behind it.
    static let night = Color(uiColor: .tertiarySystemFill)

    /// Recessive chrome. Text and axes wear text tokens, never a series colour.
    static let gridline = Color(uiColor: .separator)
    static let axis = Color(uiColor: .tertiaryLabel)

    /// The balance wears the series colours: red when the meter ran net inwards, green
    /// when it ran net outwards, and nothing at all when the two cancelled.
    static func color(for balance: EnergyBalance) -> Color {
        switch balance {
        case .taken: return consumption
        case .sentBack: return feedIn
        case .balanced: return .primary
        }
    }

    static func color(for direction: ChannelDirection) -> Color {
        switch direction {
        case .consumption: return consumption
        case .feedIn: return feedIn
        case .other: return Color(uiColor: .tertiaryLabel)
        }
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
