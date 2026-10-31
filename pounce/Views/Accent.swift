import SwiftUI

enum Accent {
    static let defaultHex = "E8833A"

    struct Swatch: Identifiable {
        let name: String
        let hex: String
        var id: String { hex }
    }

    struct Family: Identifiable {
        let name: String
        let swatches: [Swatch]
        var id: String { name }
    }

    static let families: [Family] = [
        Family(
            name: "Warm",
            swatches: [
                Swatch(name: "Ginger", hex: "E8833A"), Swatch(name: "Honey", hex: "E0A526"),
                Swatch(name: "Amber", hex: "F2A93B"), Swatch(name: "Tangerine", hex: "F27A1A"),
                Swatch(name: "Persimmon", hex: "E8572E"), Swatch(name: "Coral", hex: "F2665B"),
                Swatch(name: "Crimson", hex: "D7263D"), Swatch(name: "Brick", hex: "B5432F"),
            ]),
        Family(
            name: "Pink",
            swatches: [
                Swatch(name: "Raspberry", hex: "D6336C"), Swatch(name: "Flamingo", hex: "F25C9A"),
                Swatch(name: "Bubblegum", hex: "FF7EB6"), Swatch(name: "Blush", hex: "F4A6B7"),
                Swatch(name: "Peach", hex: "F7A57A"), Swatch(name: "Magenta", hex: "D63AF9"),
            ]),
        Family(
            name: "Purple",
            swatches: [
                Swatch(name: "Lavender", hex: "A78BFA"), Swatch(name: "Violet", hex: "8B5CF6"),
                Swatch(name: "Grape", hex: "7B2CBF"), Swatch(name: "Plum", hex: "8E4585"),
                Swatch(name: "Iris", hex: "5D5FEF"), Swatch(name: "Lilac", hex: "C8A2C8"),
            ]),
        Family(
            name: "Blue",
            swatches: [
                Swatch(name: "System Blue", hex: "0A84FF"), Swatch(name: "Sky", hex: "4FC3F7"),
                Swatch(name: "Azure", hex: "2D9CDB"), Swatch(name: "Ocean", hex: "1565C0"),
                Swatch(name: "Indigo", hex: "3F51B5"), Swatch(name: "Navy", hex: "1F3A93"),
                Swatch(name: "Cyan", hex: "00BCD4"),
            ]),
        Family(
            name: "Green",
            swatches: [
                Swatch(name: "Mint", hex: "3DDC97"), Swatch(name: "Teal", hex: "14A098"),
                Swatch(name: "Emerald", hex: "10B981"), Swatch(name: "Sage", hex: "8DAA91"),
                Swatch(name: "Lime", hex: "9BD13C"), Swatch(name: "Moss", hex: "6B8E23"),
                Swatch(name: "Forest", hex: "2E7D32"),
            ]),
        Family(
            name: "Neutral",
            swatches: [
                Swatch(name: "Mocha", hex: "8B6B4E"), Swatch(name: "Sand", hex: "C9B18A"),
                Swatch(name: "Slate", hex: "64748B"), Swatch(name: "Graphite", hex: "6E6E73"),
                Swatch(name: "Stone", hex: "A8A29E"),
            ]),
    ]

    static func name(for hex: String) -> String {
        families.lazy.flatMap(\.swatches).first { $0.hex == hex }?.name ?? "Custom"
    }

    /// adjusted per appearance so it stays readable: very light colors darken
    /// in light mode, very dark ones lighten in dark mode.
    static func color(hex: String) -> Color {
        let base = UIColor(hex: hex) ?? UIColor(hex: defaultHex)!
        return Color(
            uiColor: UIColor { traits in
                var (h, s, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
                base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                let luminance = base.relativeLuminance
                if traits.userInterfaceStyle == .dark {
                    return luminance < 0.08
                        ? UIColor(hue: h, saturation: s * 0.85, brightness: max(b, 0.7), alpha: 1) : base
                }
                return luminance > 0.55
                    ? UIColor(hue: h, saturation: min(1, s * 1.15), brightness: b * 0.72, alpha: 1) : base
            })
    }

    static func hex(for color: Color) -> String {
        let ui = UIColor(color)
        var (r, g, b): (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        ui.getRed(&r, green: &g, blue: &b, alpha: nil)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

extension UIColor {
    convenience init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(rgb: value)
    }

    /// wcag relative luminance, 0 (black) to 1 (white).
    var relativeLuminance: CGFloat {
        var (r, g, b): (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        getRed(&r, green: &g, blue: &b, alpha: nil)
        func channel(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
}

struct AccentPickerView: View {
    @AppStorage("accentHex") private var accentHex = Accent.defaultHex

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                preview
                ForEach(Accent.families) { family in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(family.name).font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 14) {
                            ForEach(family.swatches) { swatch in
                                SwatchButton(swatch: swatch, isSelected: swatch.hex == accentHex) {
                                    withAnimation(.snappy) { accentHex = swatch.hex }
                                }
                            }
                        }
                    }
                }
                ColorPicker(
                    "Custom Color",
                    selection: Binding(
                        get: { Color(uiColor: UIColor(hex: accentHex) ?? .systemOrange) },
                        set: { accentHex = Accent.hex(for: $0) }),
                    supportsOpacity: false
                )
                .font(.headline)
            }
            .padding()
        }
        .navigationTitle("Accent Color")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: accentHex)
    }

    private var preview: some View {
        HStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Accent.color(hex: accentHex).gradient, in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(Accent.name(for: accentHex)).font(.headline)
                Text("Links, buttons and highlights").font(.subheadline).foregroundStyle(.tint)
            }
            Spacer()
            Image(systemName: "bolt.circle.fill").font(.largeTitle).foregroundStyle(.tint)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 18))
        .tint(Accent.color(hex: accentHex))
        .animation(.snappy, value: accentHex)
        .accessibilityElement(children: .combine)
    }
}

private struct SwatchButton: View {
    let swatch: Accent.Swatch
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(Accent.color(hex: swatch.hex).gradient)
                    .frame(width: 44, height: 44)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(3)
                    .overlay {
                        Circle().strokeBorder(isSelected ? Accent.color(hex: swatch.hex) : .clear, lineWidth: 2)
                    }
                Text(swatch.name)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
