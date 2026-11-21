import SwiftUI

/// each cat is a stack of flat layers drawn in a fixed unit box and scaled to
/// fit, feet on the bottom edge. paths are svg-style strings so the same art
/// can be previewed outside the app.

/// ginger, dimmed towards a moonlit blue as `night` goes to 1.
struct CatColors {
    private let night: Double

    init(night: Double) { self.night = night }

    func color(_ paint: CatPose.Paint) -> Color {
        let moon = RGB(0x5B5A86)
        return switch paint {
        case .fur, .base: RGB(0xEE8A3C).mix(moon, night * 0.4).color
        case .light: light.color
        case .dark: RGB(0xB9561F).mix(RGB(0x3E3558), night * 0.4).color
        case .cream: RGB(0xFFEBD2).mix(moon, night * 0.3).color
        case .ear: RGB(0xF7A9A8).mix(moon, night * 0.35).color
        case .nose: RGB(0xE8788A).mix(moon, night * 0.3).color
        case .ink: RGB(0x33241F).color
        case .white: .white
        case .shadow: .black
        }
    }

    private var light: RGB { RGB(0xFBC37F).mix(RGB(0x5B5A86), night * 0.35) }

    var fur: LinearGradient {
        LinearGradient(colors: [light.color, color(.base)], startPoint: .top, endPoint: .bottom)
    }
}

struct CatPose: Sendable {
    enum Paint: Sendable { case fur, base, light, dark, cream, ear, nose, ink, white, shadow }

    struct Layer: Sendable {
        var path: String
        var paint: Paint
        var opacity = 1.0
        /// set to stroke with round caps instead of fill; the width is in units.
        var stroke: Double?
        /// keeps markings inside the silhouette they sit on.
        var clip: String?
        /// head layers turn together around the pose's pivot.
        var head = false

        init(
            _ path: String, _ paint: Paint, opacity: Double = 1, stroke: Double? = nil, clip: String? = nil,
            head: Bool = false
        ) {
            self.path = path
            self.paint = paint
            self.opacity = opacity
            self.stroke = stroke
            self.clip = clip
            self.head = head
        }
    }

    var unit: CGSize
    /// the neck, in units.
    var pivot: CGPoint
    /// degrees the head is turned at rest.
    var tilt: Double
    var layers: [Layer]

    /// sitting, seen from behind, watching the sky. `lean` turns the head.
    static let sitting: CatPose = {
        let body = "M 16 122 C 5 96 13 66 30 54 C 40 46 68 46 78 54 C 95 66 103 96 92 122 Q 54 129 16 122 Z"
        let head =
            "M 27 44 C 19 34 21 22 26 16 L 27 2 C 34 4 40 8 44 13 Q 54 10 64 13 C 68 8 74 4 81 2 L 82 16 C 87 22 89 34 81 44 C 72 58 36 58 27 44 Z"
        return CatPose(
            unit: CGSize(width: 120, height: 130), pivot: CGPoint(x: 54, y: 50),
            tilt: 0,
            layers: [
                Layer(
                    "M 103 126 C 103 128.21 81.96 130 56 130 C 30.04 130 9 128.21 9 126 C 9 123.79 30.04 122 56 122 C 81.96 122 103 123.79 103 126 Z",
                    .shadow, opacity: 0.18),
                Layer("M 80 118 C 105 123 117 106 110 90 C 107 82 101 78 100 70", .base, stroke: 10),
                Layer("M 100.5 74 L 100 70", .cream, stroke: 10),
                Layer(body, .fur),
                Layer(
                    "M 85 51 C 85 56.52 71.12 61 54 61 C 36.88 61 23 56.52 23 51 C 23 45.48 36.88 41 54 41 C 71.12 41 85 45.48 85 51 Z",
                    .dark, opacity: 0.2, clip: body),
                Layer(
                    "M 28 70 Q 54 61 80 70 M 24 83 Q 54 74 84 83 M 22 96 Q 54 88 86 96", .dark, opacity: 0.42,
                    stroke: 4.2, clip: body),
                Layer("M 54 52 L 54 62", .dark, opacity: 0.42, stroke: 4.2, clip: body),
                Layer("M 25 121 C 15 108 19 92 31 87 M 83 121 C 93 108 89 92 77 87", .dark, opacity: 0.28, stroke: 2),
                Layer(
                    "M 14 34 L 27 37 M 15 43 L 27 40.5 M 94 34 L 81 37 M 93 43 L 81 40.5", .cream, opacity: 0.95,
                    stroke: 1.1, head: true),
                Layer(head, .fur, head: true),
                Layer(
                    "M 29 6.5 C 33 8 38 11 41 14.5 L 29.5 17 Z M 79 6.5 C 75 8 70 11 67 14.5 L 78.5 17 Z", .dark,
                    opacity: 0.38, head: true),
                Layer(
                    "M 54 14 L 54 24 M 46.5 15.5 L 47.5 23 M 61.5 15.5 L 60.5 23", .dark, opacity: 0.42, stroke: 3,
                    head: true),
                Layer(
                    "M 30 36 Q 34 40 31 45 M 78 36 Q 74 40 77 45", .dark, opacity: 0.3, stroke: 2.4, clip: head,
                    head: true),
            ])
    }()

    /// lying with its chin up, looking at the stars.
    static let lying: CatPose = {
        let body =
            "M 34 88 L 138 88 C 154 86 156 62 140 54 C 122 44 94 43 74 47 C 56 49 43 55 37 63 C 30 71 28 82 34 88 Z"
        let head =
            "M 22 35 C 20 26 25 16 35 13 L 38 1 C 45 5 49 10 51 15 C 59 19 63 27 63 37 C 63 49 53 57 41 57 C 31 57 25 51 22 45 C 17.5 44 16.5 38 22 35 Z"
        return CatPose(
            unit: CGSize(width: 172, height: 94), pivot: CGPoint(x: 46, y: 52),
            tilt: -24,
            layers: [
                Layer(
                    "M 160 90 C 160 92.21 127.77 94 88 94 C 48.23 94 16 92.21 16 90 C 16 87.79 48.23 86 88 86 C 127.77 86 160 87.79 160 90 Z",
                    .shadow, opacity: 0.22),
                Layer("M 140 76 C 160 76 168 62 162 50 C 158 42 150 40 145 44", .base, stroke: 9),
                Layer("M 149 41.5 C 147.5 41.5 146 42.5 145 44", .cream, stroke: 9),
                Layer(body, .fur),
                Layer(
                    "M 86 42 Q 91 54 86 64 M 100 41 Q 105 53 100 63 M 114 42 Q 119 54 114 64 M 128 46 Q 132 56 128 64",
                    .dark, opacity: 0.42, stroke: 4.2, clip: body),
                Layer("M 114 88 C 105 74 113 60 130 58", .dark, opacity: 0.28, stroke: 2),
                Layer(
                    "M 68 58 C 68 64.63 57.26 70 44 70 C 30.74 70 20 64.63 20 58 C 20 51.37 30.74 46 44 46 C 57.26 46 68 51.37 68 58 Z",
                    .dark, opacity: 0.2, clip: body),
                Layer(
                    "M 36 64 C 44 60 54 66 54 76 C 54 84 44 88 34 88 C 28 82 30 70 36 64 Z", .cream, opacity: 0.9,
                    clip: body),
                Layer(
                    "M 56 85 C 56 87.76 49.73 90 42 90 C 34.27 90 28 87.76 28 85 C 28 82.24 34.27 80 42 80 C 49.73 80 56 82.24 56 85 Z M 68 83.5 C 68 85.99 62.63 88 56 88 C 49.37 88 44 85.99 44 83.5 C 44 81.01 49.37 79 56 79 C 62.63 79 68 81.01 68 83.5 Z",
                    .light),
                Layer(
                    "M 34 85 L 34 88 M 38 85.5 L 38 88.5 M 49 84 L 49 87 M 53 84.5 L 53 87.5", .dark, opacity: 0.35,
                    stroke: 1),
                Layer("M 49 14 L 57 3 C 61 8 63 15 62 23 Z", .base, head: true),
                Layer("M 49 14 L 57 3 C 61 8 63 15 62 23 Z", .dark, opacity: 0.45, head: true),
                Layer("M 9 41 L 24 43.5 M 10 50 L 24 46.5", .cream, opacity: 0.95, stroke: 1.1, head: true),
                Layer(head, .fur, head: true),
                Layer("M 38.5 5 C 43 8 46 12 47.5 16 L 38 17 Z", .ear, opacity: 0.95, head: true),
                Layer(
                    "M 35.5 43.5 C 35.5 47.09 31.69 50 27 50 C 22.31 50 18.5 47.09 18.5 43.5 C 18.5 39.91 22.31 37 27 37 C 31.69 37 35.5 39.91 35.5 43.5 Z",
                    .cream, clip: head, head: true),
                Layer(
                    "M 22.1 38.6 C 22.1 39.65 20.98 40.5 19.6 40.5 C 18.22 40.5 17.1 39.65 17.1 38.6 C 17.1 37.55 18.22 36.7 19.6 36.7 C 20.98 36.7 22.1 37.55 22.1 38.6 Z",
                    .nose, head: true),
                Layer("M 20 41 Q 21 45.5 26.5 45.5", .ink, opacity: 0.6, stroke: 1.2, head: true),
                Layer(
                    "M 37 31 C 37 33.21 35.43 35 33.5 35 C 31.57 35 30 33.21 30 31 C 30 28.79 31.57 27 33.5 27 C 35.43 27 37 28.79 37 31 Z",
                    .ink, head: true),
                Layer(
                    "M 33.75 29.4 C 33.75 30.15 33.15 30.75 32.4 30.75 C 31.65 30.75 31.05 30.15 31.05 29.4 C 31.05 28.65 31.65 28.05 32.4 28.05 C 33.15 28.05 33.75 28.65 33.75 29.4 Z",
                    .white, opacity: 0.95, head: true),
                Layer(
                    "M 47 33 L 56 31 M 47 38.5 L 57 38.5 M 46 44 L 55 46", .dark, opacity: 0.42, stroke: 2.6,
                    clip: head, head: true),
                Layer("M 43 14 L 44 21 M 49 17 L 49 23", .dark, opacity: 0.42, stroke: 2.6, clip: head, head: true),
            ])
    }()

    /// curled up asleep, for when the connections are paused.
    static let sleeping: CatPose = {
        let body = "M 14 80 C 3 62 15 35 46 27 C 77 19 118 23 136 43 C 148 57 145 76 134 80 Z"
        let head =
            "M 22 63 C 17 53 21 43 27 38 L 27 25 C 34 28 38 32 41 36 Q 45.5 35 50 36 C 53 32 57 28 64 25 L 64 38 C 70 43 74 53 69 63 C 62 77 29 77 22 63 Z"
        return CatPose(
            unit: CGSize(width: 152, height: 86), pivot: CGPoint(x: 45, y: 60),
            tilt: 0,
            layers: [
                Layer(
                    "M 140 82 C 140 84.21 111.35 86 76 86 C 40.65 86 12 84.21 12 82 C 12 79.79 40.65 78 76 78 C 111.35 78 140 79.79 140 82 Z",
                    .shadow, opacity: 0.22),
                Layer(body, .fur),
                Layer(
                    "M 72 20 Q 76 34 71 44 M 90 20 Q 95 34 90 46 M 108 24 Q 113 38 108 48 M 124 32 Q 128 44 124 52",
                    .dark, opacity: 0.42, stroke: 4.2, clip: body),
                Layer("M 106 80 C 97 64 107 50 126 50", .dark, opacity: 0.28, stroke: 2),
                Layer("M 136 66 C 128 80 96 80 76 76", .base, stroke: 8.5),
                Layer("M 136 66 C 128 80 96 80 76 76", .dark, opacity: 0.14, stroke: 8.5),
                Layer("M 80 76.5 L 76 76", .cream, stroke: 8.5),
                Layer(
                    "M 76 63 C 76 74.05 63.46 83 48 83 C 32.54 83 20 74.05 20 63 C 20 51.95 32.54 43 48 43 C 63.46 43 76 51.95 76 63 Z",
                    .dark, opacity: 0.22, clip: body),
                Layer(
                    "M 34 66 L 19 63.5 M 34 68.5 L 20 71.5 M 57 66 L 72 63.5 M 57 68.5 L 71 71.5", .cream,
                    opacity: 0.95, stroke: 1.1, head: true),
                Layer(head, .fur, head: true),
                Layer(
                    "M 29 29.5 C 33 31.5 36 34.5 38.5 38 L 29.5 40 Z M 62 29.5 C 58 31.5 55 34.5 52.5 38 L 61.5 40 Z",
                    .ear, opacity: 0.95, head: true),
                Layer(
                    "M 45.5 39 L 45.5 47 M 39.5 40 L 40.5 46.5 M 51.5 40 L 50.5 46.5", .dark, opacity: 0.42,
                    stroke: 2.6, head: true),
                Layer(
                    "M 56.5 65 C 56.5 69.14 51.58 72.5 45.5 72.5 C 39.42 72.5 34.5 69.14 34.5 65 C 34.5 60.86 39.42 57.5 45.5 57.5 C 51.58 57.5 56.5 60.86 56.5 65 Z",
                    .cream, clip: head, head: true),
                Layer(
                    "M 30.5 55.5 Q 35 60 39.5 55.5 M 51.5 55.5 Q 56 60 60.5 55.5", .ink, opacity: 0.85, stroke: 1.7,
                    head: true),
                Layer(
                    "M 47.9 62 C 47.9 62.94 46.83 63.7 45.5 63.7 C 44.17 63.7 43.1 62.94 43.1 62 C 43.1 61.06 44.17 60.3 45.5 60.3 C 46.83 60.3 47.9 61.06 47.9 62 Z",
                    .nose, head: true),
                Layer(
                    "M 45.5 63.7 Q 43 68 39.5 66 M 45.5 63.7 Q 48 68 51.5 66", .ink, opacity: 0.6, stroke: 1.2,
                    head: true),
            ])
    }()
}

struct Cat: View {
    let pose: CatPose
    let colors: CatColors
    /// −1 (looking far left) to 1 (far right), on top of the pose's own tilt.
    var lean = 0.0

    var body: some View {
        ZStack {
            part(head: false)
            part(head: true)
                .rotationEffect(
                    .degrees(pose.tilt + lean * 10),
                    anchor: UnitPoint(x: pose.pivot.x / pose.unit.width, y: pose.pivot.y / pose.unit.height))
        }
        .aspectRatio(pose.unit.width / pose.unit.height, contentMode: .fit)
    }

    private func part(head: Bool) -> some View {
        ZStack {
            ForEach(Array(pose.layers.enumerated()), id: \.offset) { _, layer in
                if layer.head == head { draw(layer) }
            }
        }
    }

    @ViewBuilder private func draw(_ layer: CatPose.Layer) -> some View {
        let shape = UnitShape(unit: pose.unit, path: layer.path, stroke: layer.stroke)
        let filled =
            layer.paint == .fur
            ? AnyView(shape.fill(colors.fur)) : AnyView(shape.fill(colors.color(layer.paint).opacity(layer.opacity)))
        if let clip = layer.clip {
            filled.mask(UnitShape(unit: pose.unit, path: clip, stroke: nil))
        } else {
            filled
        }
    }
}

/// the cat's head as a glyph, for the dynamic island: ears, and eyes cut out.
struct CatFace: Shape {
    /// closed eyes are thin slits.
    var asleep = false

    func path(in rect: CGRect) -> Path {
        var path = Path(
            svg: "M 3 15 C 1 11 2 7 4 5 L 4 0.5 C 6.5 1.5 8.5 3 10 5 Q 12 4.4 14 5 C 15.5 3 17.5 1.5 20 0.5 L 20 5 "
                + "C 22 7 23 11 21 15 C 18.5 20 5.5 20 3 15 Z")
        for x in [8.0, 16.0] {
            path.addEllipse(in: CGRect(x: x - 1.6, y: asleep ? 10.6 : 9, width: 3.2, height: asleep ? 0.9 : 3.6))
        }
        let scale = min(rect.width / 24, rect.height / 20)
        return path.applying(
            CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale, tx: rect.midX - 12 * scale, ty: rect.midY - 10 * scale))
    }
}

private struct UnitShape: Shape {
    let unit: CGSize
    let path: String
    let stroke: Double?

    func path(in rect: CGRect) -> Path {
        var path = Path(svg: path)
        if let stroke {
            path = path.strokedPath(StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
        }
        let scale = min(rect.width / unit.width, rect.height / unit.height)
        let dx = rect.minX + (rect.width - unit.width * scale) / 2
        let dy = rect.minY + (rect.height - unit.height * scale)
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy))
    }
}

extension Path {
    /// the absolute `M L Q C Z` subset of svg path data, separated by spaces.
    /// anything it can't read ends the path there.
    init(svg: String) {
        self.init()
        var numbers: [Double] = []
        var command: Character = "M"
        func point(_ i: Int) -> CGPoint { CGPoint(x: numbers[i], y: numbers[i + 1]) }
        func flush(_ path: inout Path) {
            switch (command, numbers.count) {
            case ("M", 2): path.move(to: point(0))
            case ("L", 2): path.addLine(to: point(0))
            case ("Q", 4): path.addQuadCurve(to: point(2), control: point(0))
            case ("C", 6): path.addCurve(to: point(4), control1: point(0), control2: point(2))
            default: return
            }
            numbers = []
        }
        for token in svg.split(separator: " ") {
            if let value = Double(token) {
                numbers.append(value)
                flush(&self)
            } else if token == "Z" {
                closeSubpath()
            } else if let letter = token.first, token.count == 1 {
                command = letter
                numbers = []
            } else {
                return
            }
        }
    }
}
