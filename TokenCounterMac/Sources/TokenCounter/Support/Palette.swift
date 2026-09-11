import AppKit
import SwiftUI

/// The chart palette.
///
/// Eight categorical hues in a fixed order, each with a light step and a dark
/// step of the same hue. The order is the colorblind-safety mechanism, not
/// cosmetic: it clears the adjacent-pair CVD and normal-vision separation gates
/// in both modes. Hues are assigned by slot and never cycled - a ninth series
/// folds into "Other" instead of inventing a color.
enum Palette {
    private static let categorical: [(light: UInt32, dark: UInt32)] = [
        (0x2a78d6, 0x3987e5), // blue
        (0xeb6834, 0xd95926), // orange
        (0x1baf7a, 0x199e70), // aqua
        (0xeda100, 0xc98500), // yellow
        (0xe87ba4, 0xd55181), // magenta
        (0x008300, 0x008300), // green
        (0x4a3aa7, 0x9085e9), // violet
        (0xe34948, 0xe66767), // red
    ]

    /// The color for a categorical slot. Slot 7 is the "Other" bucket.
    static func series(_ slot: Int) -> Color {
        let pair = categorical[min(max(slot, 0), categorical.count - 1)]
        return Color(nsColor: dynamic(light: pair.light, dark: pair.dark))
    }

    /// Accent used for money and emphasis.
    static var accent: Color { series(1) }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        }
    }
}

extension NSColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}
