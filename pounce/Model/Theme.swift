import SwiftTerm
import SwiftUI
import UIKit

/// declared in code, so themes cost no assets.
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    /// black, red, green, yellow, blue, magenta, cyan, white, then the bright
    /// variants in the same order.
    let ansi: [UInt32]

    var isDark: Bool { (UIColor(rgb: background).relativeLuminance) < 0.4 }

    static let pounce = TerminalTheme(
        id: "pounce", name: "Pounce", background: 0x17120F, foreground: 0xF2E6D8, cursor: 0xE8833A,
        ansi: [
            0x2A211C, 0xE8664F, 0x9BBF6A, 0xE8B04A, 0x6FA3D6, 0xC990C8, 0x6FC2B8, 0xD9CCBD,
            0x5A4A40, 0xFF8A70, 0xB5D98A, 0xFFCC66, 0x8FC0F0, 0xE3B0E0, 0x8FDDD3, 0xFFF6EA,
        ])

    static let all: [TerminalTheme] = [
        pounce,
        TerminalTheme(
            id: "paper", name: "Paper", background: 0xF7F5F0, foreground: 0x1F1F1F, cursor: 0xE8833A,
            ansi: [
                0x1F1F1F, 0xB3261E, 0x2E7D32, 0x8D6E00, 0x1F5FAD, 0x8E3A8E, 0x00796B, 0x6B6B6B,
                0x595959, 0xD32F2F, 0x388E3C, 0xA67C00, 0x1976D2, 0xAB47BC, 0x00897B, 0x1F1F1F,
            ]),
        TerminalTheme(
            id: "solarized-dark", name: "Solarized Dark", background: 0x002B36, foreground: 0x839496,
            cursor: 0x93A1A1, ansi: solarized),
        TerminalTheme(
            id: "solarized-light", name: "Solarized Light", background: 0xFDF6E3, foreground: 0x657B83,
            cursor: 0x586E75, ansi: solarized),
        TerminalTheme(
            id: "gruvbox", name: "Gruvbox", background: 0x282828, foreground: 0xEBDBB2, cursor: 0xEBDBB2,
            ansi: [
                0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
            ]),
        TerminalTheme(
            id: "nord", name: "Nord", background: 0x2E3440, foreground: 0xD8DEE9, cursor: 0xD8DEE9,
            ansi: [
                0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
            ]),
        TerminalTheme(
            id: "catppuccin", name: "Catppuccin", background: 0x1E1E2E, foreground: 0xCDD6F4, cursor: 0xF5E0DC,
            ansi: [
                0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
                0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
            ]),
        TerminalTheme(
            id: "tokyo-night", name: "Tokyo Night", background: 0x1A1B26, foreground: 0xC0CAF5, cursor: 0xC0CAF5,
            ansi: [
                0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
            ]),
        // green-phosphor vt100 look: every color is a shade of green.
        TerminalTheme(
            id: "phosphor", name: "Phosphor", background: 0x0A100A, foreground: 0x41FF6E, cursor: 0x41FF6E,
            ansi: [
                0x0A100A, 0x2FB34F, 0x41FF6E, 0x7DFF9A, 0x2A9C46, 0x5FD67C, 0x8CFFA8, 0xB8FFC9,
                0x1D4D29, 0x41FF6E, 0x7DFF9A, 0xB8FFC9, 0x41D963, 0x7DFF9A, 0xB8FFC9, 0xE6FFEC,
            ]),
    ]

    private static let solarized: [UInt32] = [
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ]

    static func named(_ id: String?) -> TerminalTheme {
        all.first { $0.id == id } ?? pounce
    }

    @MainActor func apply(to view: TerminalView) {
        view.installColors(ansi.map { Self.terminalColor($0) })
        view.nativeBackgroundColor = UIColor(rgb: background)
        view.nativeForegroundColor = UIColor(rgb: foreground)
        view.caretColor = UIColor(rgb: cursor)
        view.selectedTextBackgroundColor = UIColor(rgb: cursor).withAlphaComponent(0.35)
        view.keyboardAppearance = isDark ? .dark : .light
    }

    private static func terminalColor(_ rgb: UInt32) -> SwiftTerm.Color {
        // swiftterm colors are 16 bits per channel.
        SwiftTerm.Color(
            red: UInt16((rgb >> 16) & 0xff) * 257, green: UInt16((rgb >> 8) & 0xff) * 257,
            blue: UInt16(rgb & 0xff) * 257)
    }

    func color(_ rgb: UInt32) -> SwiftUI.Color { SwiftUI.Color(uiColor: UIColor(rgb: rgb)) }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

enum TerminalFont {
    static let defaultSize = 13.0
    static let sizes = 8.0...28.0

    static func clamped(_ size: Double) -> Double { min(sizes.upperBound, max(sizes.lowerBound, size)) }
}
