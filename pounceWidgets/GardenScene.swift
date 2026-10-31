import SwiftUI

/// the sun climbs from 6:00, hangs near the top 12:00 to 16:00 and sets by
/// 20:00; at night the cat lies watching the stars and the moon in its real
/// phase. shapes only, so no assets; recomputed from the date on every render.
struct GardenScene: View {
    let date: Date

    var body: some View {
        let hour = Self.hour(of: date)
        let sky = Sky(hour: hour)
        let garden = Garden(date: date)
        let sun = Celestial.sun(hour: hour)
        let moon = Celestial.moon(hour: hour)
        GeometryReader { geometry in
            let size = geometry.size
            let horizon = size.height * 0.7
            let point = { (arc: Celestial.Arc) in
                CGPoint(
                    x: size.width * (0.06 + 0.88 * arc.progress),
                    y: horizon - arc.elevation * (horizon - size.height * 0.2))
            }
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [sky.top.color, sky.bottom.color], startPoint: .top, endPoint: .bottom)

                StarField(stars: garden.stars, size: size, horizon: horizon).opacity(sky.night)
                if let streak = garden.shootingStar(at: date), sky.night > 0.8 {
                    ShootingStar()
                        .frame(width: size.width * 0.14, height: size.height * 0.05)
                        .rotationEffect(.degrees(streak.angle))
                        .position(x: size.width * streak.x, y: horizon * streak.y)
                }
                if let moon {
                    let d = size.height * 0.24
                    MoonDisc(phase: Celestial.moonPhase(on: date))
                        .frame(width: d, height: d)
                        .position(point(moon))
                        .opacity(sky.night)
                }
                if let sun {
                    let warmth = 1 - min(1, max(0, sun.elevation) / 0.5)
                    let radius = size.height * 0.12 * (1 + 0.18 * warmth)
                    let color = Celestial.sunColor(warmth: warmth, evening: sun.progress > 0.5)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [color.color.opacity(0.55), color.color.opacity(0)],
                                center: .center, startRadius: radius * 0.8, endRadius: radius * 2.6)
                        )
                        .frame(width: radius * 5.2, height: radius * 5.2)
                        .position(point(sun))
                    Circle()
                        .fill(color.color)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(point(sun))
                }

                Hill(wave: 0.06)
                    .fill(sky.backHill.color)
                    .frame(height: size.height - horizon + size.height * 0.06)
                    .offset(y: horizon - size.height * 0.06)
                Fence(color: sky.fence.color)
                    .frame(width: size.width * 0.17, height: size.height * 0.16)
                    .position(x: size.width * 0.9, y: horizon - size.height * 0.02)
                Hill(wave: 0.1)
                    .fill(sky.lawn.color)
                    .frame(height: size.height - horizon)
                    .offset(y: horizon + size.height * 0.04)
                Lawn(garden: garden, size: size, lawnTop: horizon + size.height * 0.08, sky: sky)

                let ground = horizon + size.height * 0.22
                if sky.night > 0.5 {
                    let height = size.height * 0.44
                    let unit = LyingCat.unit
                    LyingCat(colors: CatColors(night: sky.night))
                        .frame(width: height * unit.width / unit.height, height: height)
                        .position(x: size.width * Garden.catX, y: ground - height / 2)
                } else {
                    let height = size.height * 0.62
                    let unit = SittingCat.unit
                    let sunX = 0.06 + 0.88 * (sun?.progress ?? 0.3)
                    SittingCat(colors: CatColors(night: 0), lean: max(-1, min(1, (sunX - Garden.catX) * 2)))
                        .frame(width: height * unit.width / unit.height, height: height)
                        .position(x: size.width * Garden.catX, y: ground - height / 2)
                }
            }
        }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel(Sky.description(hour: hour))
    }

    /// fractional hours since midnight (13.5 is 13:30).
    static func hour(of date: Date) -> Double {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
    }
}

// MARK: - sun and moon

enum Celestial {
    struct Arc {
        /// from the left horizon (0) to the right one (1).
        var progress: Double
        /// 0 on the horizon, 1 at the top; a little below 0 when setting behind the
        /// hills.
        var elevation: Double
    }

    /// up through the morning, slowing near the top from 12:00 to 16:00, then
    /// down faster and faster into the sunset. nil at night.
    static func sun(hour h: Double) -> Arc? {
        guard h >= 6, h < 20 else { return nil }
        let progress: Double
        switch h {
        case ..<12:
            let t = (h - 6) / 6
            progress = 0.45 * (1 - (1 - t) * (1 - t))
        case ..<16:
            progress = 0.45 + 0.1 * (h - 12) / 4
        default:
            let t = (h - 16) / 4
            progress = 0.55 + 0.45 * t * t
        }
        return Arc(progress: progress, elevation: sin(.pi * progress) * 1.08 - 0.08)
    }

    /// across the sky from 20:00 to 6:00. nil by day.
    static func moon(hour h: Double) -> Arc? {
        guard h >= 20 || h < 6 else { return nil }
        let progress = (h >= 20 ? h - 20 : h + 4) / 10
        return Arc(progress: progress, elevation: sin(.pi * progress) * 0.95 - 0.05)
    }

    /// pale yellow up high, orange near the horizon, redder in the evening.
    static func sunColor(warmth: Double, evening: Bool) -> RGB {
        let warm = RGB(0xFF9A3C).mix(RGB(0xF2604A), evening ? warmth * 0.6 : 0)
        return RGB(0xFFF4B8).mix(warm, warmth)
    }

    /// 0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter.
    static func moonPhase(on date: Date) -> Double {
        // a known new moon: 6 january 2000, 18:14 utc.
        let reference = Date(timeIntervalSince1970: 947_182_440)
        let synodicMonth = 29.530_588_853 * 86_400
        let cycles = date.timeIntervalSince(reference) / synodicMonth
        return cycles - cycles.rounded(.down)
    }
}

/// the lit part bright, the rest faintly there (earthshine).
private struct MoonDisc: View {
    let phase: Double

    var body: some View {
        let light = Color(red: 1, green: 0.96, blue: 0.82)
        ZStack {
            Circle().fill(light.opacity(0.1))
            MoonLight(phase: phase)
                .fill(light)
                .shadow(color: light.opacity(0.6), radius: 4)
        }
    }
}

/// the bright limb on one side, closed by the terminator: an ellipse whose
/// width follows the phase.
private struct MoonLight: Shape {
    let phase: Double

    func path(in rect: CGRect) -> Path {
        let r = rect.width / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // waxing, the right side is lit (as seen from the northern hemisphere).
        let side: Double = phase < 0.5 ? 1 : -1
        let k = cos(2 * .pi * phase)
        let steps = 32
        var path = Path()
        for i in 0...steps {
            let a = -Double.pi / 2 + Double.pi * Double(i) / Double(steps)
            let p = CGPoint(x: center.x + side * r * cos(a), y: center.y + r * sin(a))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        for i in 0...steps {
            let a = Double.pi / 2 - Double.pi * Double(i) / Double(steps)
            path.addLine(to: CGPoint(x: center.x + side * r * k * cos(a), y: center.y + r * sin(a)))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - the sky over the day

/// blendable, which swiftui's `Color` can't do in a widget without resolving
/// it first.
struct RGB {
    var r, g, b: Double

    init(_ hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    func mix(_ other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    var color: Color { Color(red: r, green: g, blue: b) }
}

private struct Sky {
    var top: RGB
    var bottom: RGB
    var backHill: RGB
    var lawn: RGB
    var fence: RGB
    /// 0 in daylight, 1 in full night: stars, moon, the cat lying down.
    var night: Double

    /// key moments of the day: hour, sky top, sky bottom, back hill, lawn.
    private static let keys: [(Double, UInt32, UInt32, UInt32, UInt32)] = [
        (0, 0x0B1030, 0x241E52, 0x1E3328, 0x253F31),
        (5.3, 0x10173D, 0x2A2560, 0x1E3328, 0x253F31),
        (6, 0x3C4C8E, 0xF2A97A, 0x4C6E45, 0x5A8550),
        (7.5, 0x6FA8DC, 0xFFD9AE, 0x5C9A50, 0x72B062),
        (10, 0x4A90D9, 0xBFE3F7, 0x5FA857, 0x7CC46A),
        (12, 0x2F7FD6, 0xA8D8F5, 0x5FA857, 0x7CC46A),
        (16, 0x3A86D6, 0xB5DCF2, 0x5FA857, 0x7CC46A),
        (17, 0x5B8FD0, 0xF6CB9C, 0x619E52, 0x7DB862),
        (18.5, 0x5A5FA8, 0xF49A6C, 0x5A8248, 0x6E9A52),
        (19.5, 0x3A3878, 0xE2716A, 0x405F3C, 0x4F7646),
        (20, 0x262659, 0x8A4E7A, 0x2D4A36, 0x365A40),
        (20.6, 0x121638, 0x2C2659, 0x1E3328, 0x253F31),
        (24, 0x0B1030, 0x241E52, 0x1E3328, 0x253F31),
    ]

    init(hour: Double) {
        let h = hour.truncatingRemainder(dividingBy: 24)
        let index = Self.keys.lastIndex { $0.0 <= h } ?? 0
        let a = Self.keys[index]
        let b = Self.keys[min(index + 1, Self.keys.count - 1)]
        let t = b.0 > a.0 ? (h - a.0) / (b.0 - a.0) : 0
        top = RGB(a.1).mix(RGB(b.1), t)
        bottom = RGB(a.2).mix(RGB(b.2), t)
        backHill = RGB(a.3).mix(RGB(b.3), t)
        lawn = RGB(a.4).mix(RGB(b.4), t)

        night =
            switch h {
            case 5.4..<6.2: 1 - (h - 5.4) / 0.8
            case 6.2..<20: 0
            case 20..<20.6: (h - 20) / 0.6
            default: 1
            }
        fence = RGB(0xF4EFE6).mix(RGB(0x55607A), night * 0.8)
    }

    static func description(hour: Double) -> String {
        switch hour {
        case 6..<12: "A cat in the garden, watching the sun rise"
        case 12..<16: "A cat in the garden, under the midday sun"
        case 16..<20: "A cat in the garden, watching the sun set"
        default: "A cat lying in the garden, looking at the stars"
        }
    }
}

// MARK: - what's scattered where

/// seeded so the garden stays put all day and changes the next. a garden day
/// runs 6:00 to 6:00, so the night sky doesn't change at midnight.
struct Garden {
    struct Flower {
        var x, depth, size: Double
        var petals: Int
        var color: UInt32
    }

    struct Star {
        var x, y, size: Double
        var sparkle: Bool
    }

    /// flowers keep clear of it.
    static let catX = 0.2

    private static let colors: [UInt32] = [0xF7A8C4, 0xFFE27A, 0xFFFFFF, 0xC9B3F5, 0x9CC9F5, 0xFF9E8A]

    var flowers: [Flower] = []
    var tufts: [(x: Double, depth: Double)] = []
    var stars: [Star] = []
    private let seed: UInt64

    init(date: Date) {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date.addingTimeInterval(-6 * 3600))
        seed = UInt64((day.year ?? 0) * 10_000 + (day.month ?? 0) * 100 + (day.day ?? 0))
        var random = SeededRandom(seed: seed)

        var taken: [Double] = []
        for _ in 0..<Int.random(in: 7...11, using: &random) {
            for _ in 0..<12 {
                let x = Double.random(in: 0.03...0.97, using: &random)
                guard abs(x - Self.catX) > 0.09, taken.allSatisfy({ abs($0 - x) > 0.045 }) else { continue }
                taken.append(x)
                flowers.append(
                    Flower(
                        x: x, depth: .random(in: 0.2...0.85, using: &random),
                        size: .random(in: 0.8...1.3, using: &random),
                        petals: Bool.random(using: &random) ? 5 : 6,
                        color: Self.colors.randomElement(using: &random) ?? 0xFFFFFF))
                break
            }
        }
        for _ in 0..<Int.random(in: 4...7, using: &random) {
            tufts.append((.random(in: 0.02...0.98, using: &random), .random(in: 0.1...0.8, using: &random)))
        }
        for i in 0..<Int.random(in: 18...26, using: &random) {
            stars.append(
                Star(
                    x: .random(in: 0.01...0.99, using: &random), y: .random(in: 0.04...0.85, using: &random),
                    size: .random(in: 0.6...1.3, using: &random), sparkle: i < 3))
        }
    }

    /// at night, a shooting star now and then: a fresh chance every five minutes.
    func shootingStar(at date: Date) -> (x: Double, y: Double, angle: Double)? {
        let slot = UInt64(max(0, date.timeIntervalSince1970 / 300))
        var random = SeededRandom(seed: seed &* 31 &+ slot)
        guard Double.random(in: 0...1, using: &random) < 0.3 else { return nil }
        return (
            .random(in: 0.15...0.75, using: &random), .random(in: 0.15...0.45, using: &random),
            .random(in: 15...35, using: &random)
        )
    }
}

/// splitmix64: small, fast, and the same sequence for the same seed.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - garden

private struct Hill: Shape {
    var wave: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let amp = rect.height * wave
        path.move(to: CGPoint(x: 0, y: amp))
        path.addCurve(
            to: CGPoint(x: rect.width, y: amp * 0.6),
            control1: CGPoint(x: rect.width * 0.3, y: -amp),
            control2: CGPoint(x: rect.width * 0.65, y: amp * 2.2))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

private struct Fence: View {
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let posts = 5
            let postWidth = w / CGFloat(posts) * 0.42
            Path { path in
                for i in 0..<posts {
                    let x = (CGFloat(i) + 0.5) * w / CGFloat(posts) - postWidth / 2
                    path.move(to: CGPoint(x: x, y: h))
                    path.addLine(to: CGPoint(x: x, y: h * 0.25))
                    path.addLine(to: CGPoint(x: x + postWidth / 2, y: 0))
                    path.addLine(to: CGPoint(x: x + postWidth, y: h * 0.25))
                    path.addLine(to: CGPoint(x: x + postWidth, y: h))
                    path.closeSubpath()
                }
                path.addRect(CGRect(x: 0, y: h * 0.45, width: w, height: h * 0.14))
                path.addRect(CGRect(x: 0, y: h * 0.75, width: w, height: h * 0.14))
            }
            .fill(color)
        }
    }
}

private struct Lawn: View {
    let garden: Garden
    let size: CGSize
    let lawnTop: CGFloat
    let sky: Sky

    var body: some View {
        let depth = size.height - lawnTop
        let dim = sky.night
        let blade = sky.lawn.mix(RGB(0x1E3A22), 0.35).color
        ForEach(Array(garden.tufts.enumerated()), id: \.offset) { _, tuft in
            Tuft()
                .fill(blade)
                .frame(width: size.height * 0.12, height: size.height * 0.08)
                .position(x: size.width * tuft.x, y: lawnTop + depth * tuft.depth)
        }
        ForEach(Array(garden.flowers.enumerated()), id: \.offset) { _, flower in
            let r = size.height * (0.03 + 0.02 * flower.depth) * flower.size
            let petal = RGB(flower.color).mix(RGB(0x3A4060), dim * 0.55).color
            ZStack {
                ForEach(0..<flower.petals, id: \.self) { i in
                    let angle = Double(i) / Double(flower.petals) * 2 * .pi
                    Circle().fill(petal)
                        .frame(width: r * 1.1, height: r * 1.1)
                        .offset(x: cos(angle) * r * 0.7, y: sin(angle) * r * 0.7)
                }
                Circle().fill(RGB(0xF2B33D).mix(RGB(0x5A5040), dim * 0.5).color)
                    .frame(width: r * 0.8, height: r * 0.8)
            }
            .position(x: size.width * flower.x, y: lawnTop + depth * flower.depth)
        }
    }
}

private struct Tuft: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (base, tip) in [(0.3, 0.05), (0.5, 0.5), (0.7, 0.95)] {
            path.move(to: CGPoint(x: rect.width * (base - 0.08), y: rect.height))
            path.addQuadCurve(
                to: CGPoint(x: rect.width * tip, y: 0), control: CGPoint(x: rect.width * base, y: rect.height * 0.4))
            path.addQuadCurve(
                to: CGPoint(x: rect.width * (base + 0.08), y: rect.height),
                control: CGPoint(x: rect.width * (base + 0.04), y: rect.height * 0.5))
            path.closeSubpath()
        }
        return path
    }
}

private struct StarField: View {
    let stars: [Garden.Star]
    let size: CGSize
    let horizon: CGFloat

    var body: some View {
        ForEach(Array(stars.enumerated()), id: \.offset) { index, star in
            let d = size.height * 0.035 * star.size
            Group {
                if star.sparkle {
                    Image(systemName: "sparkle")
                        .resizable()
                        .frame(width: d * 2.6, height: d * 2.6)
                } else {
                    Circle().frame(width: d, height: d)
                }
            }
            .foregroundStyle(Color(red: 1, green: 0.97, blue: 0.86).opacity(index.isMultiple(of: 3) ? 0.65 : 1))
            .position(x: size.width * star.x, y: horizon * 0.92 * star.y)
        }
    }
}

private struct ShootingStar: View {
    var body: some View {
        let light = Color(red: 1, green: 0.97, blue: 0.86)
        Capsule()
            .fill(LinearGradient(colors: [light.opacity(0), light], startPoint: .leading, endPoint: .trailing))
            .frame(height: 1.6)
            .overlay(alignment: .trailing) {
                Circle().fill(light).frame(width: 3, height: 3)
                    .shadow(color: light, radius: 2)
            }
    }
}
