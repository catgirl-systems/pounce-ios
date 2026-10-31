import SwiftUI

/// each pose is a few smooth silhouettes drawn in a fixed unit box, then
/// scaled to fit.

/// ginger, dimmed towards a moonlit blue as `night` goes to 1.
struct CatColors {
    var light: Color
    var base: Color
    var dark: Color
    var ear: Color

    init(night: Double) {
        let moon = RGB(0x5B5A86)
        light = RGB(0xF7B26A).mix(moon, night * 0.35).color
        base = RGB(0xE8823A).mix(moon, night * 0.4).color
        dark = RGB(0xB85A22).mix(RGB(0x3E3558), night * 0.4).color
        ear = RGB(0xF4A3A0).mix(moon, night * 0.35).color
    }

    var fur: LinearGradient {
        LinearGradient(colors: [light, base], startPoint: .top, endPoint: .bottom)
    }
}

private struct UnitShape: Shape {
    let unit: CGSize
    /// set to stroke instead of fill, with the width in units.
    var stroke: StrokeStyle?
    let build: @Sendable (inout Path) -> Void

    func path(in rect: CGRect) -> Path {
        var path = Path()
        build(&path)
        if let stroke { path = path.strokedPath(stroke) }
        let scale = min(rect.width / unit.width, rect.height / unit.height)
        let dx = rect.minX + (rect.width - unit.width * scale) / 2
        let dy = rect.minY + (rect.height - unit.height * scale)
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

// MARK: - sitting, from behind

/// head turned a little towards the sun. the box is wider than tall because
/// of the tail.
struct SittingCat: View {
    static let unit = CGSize(width: 120, height: 124)
    let colors: CatColors
    /// −1 (sun far left) to 1 (sun far right).
    let lean: Double

    var body: some View {
        let unit = Self.unit
        let tilt = lean * 10
        ZStack {
            UnitShape(unit: unit) { $0.addEllipse(in: CGRect(x: 4, y: 116, width: 102, height: 10)) }
                .fill(.black.opacity(0.18))
            UnitShape(unit: unit, stroke: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)) { path in
                path.move(to: CGPoint(x: 78, y: 114))
                path.addCurve(
                    to: CGPoint(x: 108, y: 96), control1: CGPoint(x: 100, y: 120), control2: CGPoint(x: 112, y: 110))
                path.addCurve(
                    to: CGPoint(x: 100, y: 74), control1: CGPoint(x: 106, y: 86), control2: CGPoint(x: 98, y: 82))
            }
            .fill(colors.base)
            UnitShape(unit: unit, build: Self.body)
                .fill(colors.fur)
            UnitShape(unit: unit, stroke: StrokeStyle(lineWidth: 3.5, lineCap: .round)) { path in
                for y in [70.0, 82, 94] {
                    path.move(to: CGPoint(x: 26, y: y))
                    path.addQuadCurve(to: CGPoint(x: 74, y: y), control: CGPoint(x: 50, y: y - 7))
                }
            }
            .fill(colors.dark.opacity(0.45))
            .mask(UnitShape(unit: unit, build: Self.body))
            ZStack {
                UnitShape(unit: unit, build: Self.head).fill(colors.fur)
                UnitShape(unit: unit, stroke: StrokeStyle(lineWidth: 3, lineCap: .round)) { path in
                    for (y, half) in [(24.0, 9.0), (32, 12)] {
                        path.move(to: CGPoint(x: 50 - half, y: y))
                        path.addQuadCurve(to: CGPoint(x: 50 + half, y: y), control: CGPoint(x: 50, y: y - 4))
                    }
                }
                .fill(colors.dark.opacity(0.35))
            }
            .rotationEffect(.degrees(tilt), anchor: UnitPoint(x: 50 / unit.width, y: 50 / unit.height))
        }
    }

    nonisolated static func body(_ path: inout Path) {
        path.move(to: CGPoint(x: 14, y: 118))
        path.addCurve(to: CGPoint(x: 30, y: 52), control1: CGPoint(x: 6, y: 92), control2: CGPoint(x: 14, y: 62))
        path.addCurve(to: CGPoint(x: 70, y: 52), control1: CGPoint(x: 40, y: 44), control2: CGPoint(x: 60, y: 44))
        path.addCurve(to: CGPoint(x: 86, y: 118), control1: CGPoint(x: 86, y: 62), control2: CGPoint(x: 94, y: 92))
        path.addQuadCurve(to: CGPoint(x: 14, y: 118), control: CGPoint(x: 50, y: 123))
        path.closeSubpath()
    }

    nonisolated static func head(_ path: inout Path) {
        path.move(to: CGPoint(x: 24, y: 40))
        path.addCurve(to: CGPoint(x: 26, y: 6), control1: CGPoint(x: 18, y: 28), control2: CGPoint(x: 20, y: 14))
        path.addCurve(to: CGPoint(x: 42, y: 16), control1: CGPoint(x: 32, y: 8), control2: CGPoint(x: 38, y: 12))
        path.addQuadCurve(to: CGPoint(x: 58, y: 16), control: CGPoint(x: 50, y: 13))
        path.addCurve(to: CGPoint(x: 74, y: 6), control1: CGPoint(x: 62, y: 12), control2: CGPoint(x: 68, y: 8))
        path.addCurve(to: CGPoint(x: 76, y: 40), control1: CGPoint(x: 80, y: 14), control2: CGPoint(x: 82, y: 28))
        path.addCurve(to: CGPoint(x: 24, y: 40), control1: CGPoint(x: 68, y: 56), control2: CGPoint(x: 32, y: 56))
        path.closeSubpath()
    }
}

// MARK: - lying, looking at the stars

/// lying like a loaf, seen from the side, chin up towards the sky.
struct LyingCat: View {
    static let unit = CGSize(width: 156, height: 84)
    let colors: CatColors

    var body: some View {
        let unit = Self.unit
        ZStack {
            UnitShape(unit: unit) { $0.addEllipse(in: CGRect(x: 10, y: 76, width: 132, height: 8)) }
                .fill(.black.opacity(0.22))
            UnitShape(unit: unit, stroke: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)) {
                Self.tail(&$0)
            }
            .fill(colors.base)
            UnitShape(unit: unit, stroke: StrokeStyle(lineWidth: 7, lineCap: .round)) { path in
                path.move(to: CGPoint(x: 141, y: 31))
                path.addQuadCurve(to: CGPoint(x: 132, y: 26), control: CGPoint(x: 138, y: 25))
            }
            .fill(colors.dark.opacity(0.9))
            UnitShape(unit: unit, build: Self.body).fill(colors.fur)
            UnitShape(unit: unit, stroke: StrokeStyle(lineWidth: 3.5, lineCap: .round)) { path in
                for x in [76.0, 90, 104] {
                    path.move(to: CGPoint(x: x, y: 40))
                    path.addQuadCurve(to: CGPoint(x: x + 3, y: 60), control: CGPoint(x: x + 6, y: 50))
                }
            }
            .fill(colors.dark.opacity(0.4))
            .mask(UnitShape(unit: unit, build: Self.body))
            UnitShape(unit: unit) { path in
                path.addRoundedRect(
                    in: CGRect(x: 22, y: 73, width: 24, height: 8), cornerSize: CGSize(width: 4, height: 4))
                path.addRoundedRect(
                    in: CGRect(x: 30, y: 70, width: 22, height: 8), cornerSize: CGSize(width: 4, height: 4))
            }
            .fill(colors.light)
            ZStack {
                UnitShape(unit: unit, build: Self.head).fill(colors.fur)
                UnitShape(unit: unit) { path in
                    path.move(to: CGPoint(x: 46, y: 12))
                    path.addLine(to: CGPoint(x: 51, y: 4))
                    path.addLine(to: CGPoint(x: 53, y: 15))
                    path.closeSubpath()
                }
                .fill(colors.ear.opacity(0.8))
                UnitShape(unit: unit) { $0.addEllipse(in: CGRect(x: 30, y: 22, width: 7, height: 6.5)) }
                    .fill(Color(red: 0.15, green: 0.1, blue: 0.1))
                UnitShape(unit: unit) { $0.addEllipse(in: CGRect(x: 31, y: 22.5, width: 2.6, height: 2.6)) }
                    .fill(.white.opacity(0.95))
                UnitShape(unit: unit) { $0.addEllipse(in: CGRect(x: 18, y: 17, width: 4.5, height: 3.4)) }
                    .fill(Color(red: 0.93, green: 0.55, blue: 0.6))
                UnitShape(unit: unit, stroke: StrokeStyle(lineWidth: 1.2, lineCap: .round)) { path in
                    path.move(to: CGPoint(x: 20, y: 21))
                    path.addQuadCurve(to: CGPoint(x: 25, y: 25), control: CGPoint(x: 20, y: 25))
                }
                .fill(colors.dark.opacity(0.7))
                UnitShape(unit: unit, stroke: StrokeStyle(lineWidth: 0.9, lineCap: .round)) { path in
                    path.move(to: CGPoint(x: 26, y: 26))
                    path.addLine(to: CGPoint(x: 11, y: 26))
                    path.move(to: CGPoint(x: 26, y: 28))
                    path.addLine(to: CGPoint(x: 13, y: 32))
                }
                .fill(colors.light.opacity(0.9))
            }
            .rotationEffect(.degrees(-20), anchor: UnitPoint(x: 44 / unit.width, y: 46 / unit.height))
        }
    }

    nonisolated static func tail(_ path: inout Path) {
        path.move(to: CGPoint(x: 126, y: 62))
        path.addCurve(to: CGPoint(x: 146, y: 40), control1: CGPoint(x: 142, y: 60), control2: CGPoint(x: 148, y: 50))
        path.addCurve(to: CGPoint(x: 132, y: 26), control1: CGPoint(x: 145, y: 30), control2: CGPoint(x: 138, y: 25))
    }

    nonisolated static func body(_ path: inout Path) {
        path.move(to: CGPoint(x: 28, y: 80))
        path.addLine(to: CGPoint(x: 126, y: 80))
        path.addCurve(to: CGPoint(x: 126, y: 50), control1: CGPoint(x: 140, y: 78), control2: CGPoint(x: 140, y: 56))
        path.addCurve(to: CGPoint(x: 70, y: 40), control1: CGPoint(x: 112, y: 40), control2: CGPoint(x: 90, y: 38))
        path.addCurve(to: CGPoint(x: 34, y: 48), control1: CGPoint(x: 54, y: 40), control2: CGPoint(x: 42, y: 42))
        path.addCurve(to: CGPoint(x: 28, y: 80), control1: CGPoint(x: 26, y: 56), control2: CGPoint(x: 22, y: 72))
        path.closeSubpath()
    }

    nonisolated static func head(_ path: inout Path) {
        path.move(to: CGPoint(x: 18, y: 22))
        path.addCurve(to: CGPoint(x: 34, y: 10), control1: CGPoint(x: 20, y: 14), control2: CGPoint(x: 26, y: 10))
        path.addLine(to: CGPoint(x: 42, y: 10))
        path.addLine(to: CGPoint(x: 52, y: 0))
        path.addCurve(to: CGPoint(x: 58, y: 22), control1: CGPoint(x: 56, y: 6), control2: CGPoint(x: 58, y: 14))
        path.addCurve(to: CGPoint(x: 52, y: 48), control1: CGPoint(x: 60, y: 32), control2: CGPoint(x: 58, y: 42))
        path.addCurve(to: CGPoint(x: 28, y: 44), control1: CGPoint(x: 44, y: 54), control2: CGPoint(x: 32, y: 52))
        path.addCurve(to: CGPoint(x: 18, y: 22), control1: CGPoint(x: 22, y: 38), control2: CGPoint(x: 16, y: 30))
        path.closeSubpath()
    }
}
