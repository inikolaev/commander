import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        precondition(hex <= 0xFFFFFF, "NSColor hex value must be RRGGBB")
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
