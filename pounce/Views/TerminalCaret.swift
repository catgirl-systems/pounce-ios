import SwiftTerm
import SwiftUI
import UIKit

/// a remote program can still request another shape (vim's bar in insert
/// mode, say), and gets it.
enum CaretShape: String, CaseIterable, Identifiable {
    case block, bar, underline

    var id: Self { self }

    var label: String {
        switch self {
        case .block: "Block"
        case .bar: "Bar"
        case .underline: "Underline"
        }
    }
}

enum CaretAnimation: String, CaseIterable, Identifiable {
    case steady
    case blink
    case pulse

    var id: Self { self }

    var label: String {
        switch self {
        case .steady: "Steady"
        case .blink: "Blink"
        case .pulse: "Pulse"
        }
    }
}

struct CaretStyle: Equatable {
    var shape: CaretShape
    var animation: CaretAnimation
    var glide: Bool

    static var current: CaretStyle {
        let defaults = UserDefaults.standard
        return CaretStyle(
            shape: CaretShape(rawValue: defaults.string(forKey: "caretShape") ?? "") ?? .bar,
            animation: CaretAnimation(rawValue: defaults.string(forKey: "caretAnimation") ?? "") ?? .pulse,
            glide: defaults.bool(forKey: "caretGlide", default: true))
    }

    /// how long the caret stays solid after it moves, so it doesn't fade or
    /// blink away while you type.
    static let restAfterMove: TimeInterval = 0.5
}

// MARK: - caret overlay

/// drawn over swiftterm's own caret, which is turned off.
@MainActor final class TerminalCaret: UIView {
    private unowned let terminal: TerminalView
    private let body = UIView()
    private let glyph = UILabel()
    private var state: TerminalView.CaretState?
    private var style = CaretStyle.current
    private var settingsObserver: NSObjectProtocol?

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
        addSubview(body)
        body.addSubview(glyph)
        glyph.textAlignment = .center
        terminal.drawsCaret = false
        terminal.addSubview(self)
        terminal.caretObserver = { [weak self] in self?.update($0) }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    func themeChanged() {
        guard let state else { return }
        draw(state)
    }

    private func settingsChanged() {
        let new = CaretStyle.current
        guard new != style else { return }
        style = new
        if let state {
            draw(state)
            restartAnimation()
        }
    }

    private func update(_ new: TerminalView.CaretState) {
        let old = state
        state = new
        guard let frame = new.frame else {
            isHidden = true
            return
        }
        // stay on top of anything swiftterm adds (its own caret, links).
        if terminal.subviews.last !== self { terminal.bringSubviewToFront(self) }
        // swiftterm reports the caret on every redraw, moved or not.
        guard new != old || isHidden else { return }
        let moved = old?.frame != frame
        let glide =
            style.glide && !UIAccessibility.isReduceMotionEnabled && !isHidden && moved
            && old?.frame.map { abs($0.minY - frame.minY) < frame.height * 4 } == true
        isHidden = false
        draw(new)
        if glide {
            UIView.animate(
                withDuration: 0.09, delay: 0, options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
            ) { self.frame = frame }
        } else {
            self.frame = frame
        }
        if moved || old?.focused != new.focused { restartAnimation() }
    }

    private func draw(_ state: TerminalView.CaretState) {
        guard let frame = state.frame else { return }
        let size = frame.size
        let color = terminal.caretColor
        let shape = Self.shape(for: state.style, default: style.shape)
        body.layer.cornerCurve = .continuous

        guard state.focused else {
            // without focus, a hollow block, like most terminals.
            body.frame = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            body.backgroundColor = .clear
            body.layer.borderColor = color.withAlphaComponent(0.8).cgColor
            body.layer.borderWidth = 1.2
            body.layer.cornerRadius = 2
            glyph.isHidden = true
            return
        }
        body.layer.borderWidth = 0
        body.backgroundColor = color
        switch shape {
        case .block:
            body.frame = CGRect(origin: .zero, size: size)
            body.layer.cornerRadius = min(3, size.width * 0.25)
        case .bar:
            let width = max(2, (size.width * 0.16).rounded())
            body.frame = CGRect(x: 0, y: 1, width: width, height: size.height - 2)
            body.layer.cornerRadius = width / 2
        case .underline:
            let height = max(2, (size.height * 0.1).rounded())
            body.frame = CGRect(x: 0.5, y: size.height - height, width: size.width - 1, height: height)
            body.layer.cornerRadius = height / 2
        }
        // in a block, the character shows through in the background colour.
        glyph.isHidden = shape != .block || state.character.trimmingCharacters(in: .whitespaces).isEmpty
        if !glyph.isHidden {
            glyph.text = state.character
            glyph.font = terminal.font
            glyph.textColor = terminal.nativeBackgroundColor
            glyph.frame = body.bounds
        }
    }

    /// the program's decscusr style wins over the setting, except the default
    /// (blinking block), which is what programs reset to.
    private static func shape(for style: CursorStyle, default shape: CaretShape) -> CaretShape {
        switch style {
        case .blinkBlock: shape
        case .steadyBlock: .block
        case .blinkBar, .steadyBar: .bar
        case .blinkUnderline, .steadyUnderline: .underline
        }
    }

    private func restartAnimation() {
        layer.removeAllAnimations()
        layer.opacity = 1
        guard state?.focused == true else { return }
        let animation: CAAnimation
        switch style.animation {
        case .steady:
            return
        case .blink:
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 0]
            blink.keyTimes = [0, 0.5, 1]
            blink.calculationMode = .discrete
            blink.duration = 1.06
            animation = blink
        case .pulse:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.15
            pulse.duration = 0.75
            pulse.autoreverses = true
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation = pulse
        }
        animation.repeatCount = .infinity
        animation.beginTime = CACurrentMediaTime() + CaretStyle.restAfterMove
        layer.add(animation, forKey: "caret")
    }
}

// MARK: - preview

/// driven by the clock, so it loops by itself.
struct CaretPreview: View {
    let theme: TerminalTheme
    let style: CaretStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let prompt = "molly@cat:~$ "
    private static let command = "ssh pounce"
    private static let cellWidth: CGFloat = 8.4
    private static let cellHeight: CGFloat = 17

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5)
            // types the command for the first 2 s, then waits.
            let typed = min(Self.command.count, Int(max(0, t - 0.3) / 0.17))
            let lastKey = 0.3 + Double(typed) * 0.17
            let column = Self.prompt.count + typed
            let sinceMove = typed == 0 ? t : t - lastKey
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Text(Self.prompt).foregroundStyle(theme.color(theme.ansi[2]))
                    Text(String(Self.command.prefix(typed))).foregroundStyle(theme.color(theme.foreground))
                }
                caret
                    .opacity(opacity(sinceMove: sinceMove))
                    .offset(x: offset(column: column, sinceMove: sinceMove))
            }
            .font(.system(size: 14, design: .monospaced))
            .frame(height: Self.cellHeight)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color(theme.background), in: .rect(cornerRadius: 12))
        .accessibilityHidden(true)
    }

    @ViewBuilder private var caret: some View {
        let color = theme.color(theme.cursor)
        switch style.shape {
        case .block:
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(color)
                .frame(width: Self.cellWidth, height: Self.cellHeight)
        case .bar:
            Capsule().fill(color).frame(width: 2, height: Self.cellHeight - 2)
        case .underline:
            Capsule().fill(color).frame(width: Self.cellWidth - 1, height: 2)
                .frame(height: Self.cellHeight, alignment: .bottom)
        }
    }

    private func offset(column: Int, sinceMove: Double) -> CGFloat {
        let target = CGFloat(column) * Self.cellWidth
        guard style.glide, !reduceMotion, column > Self.prompt.count else { return target }
        let progress = min(1, sinceMove / 0.09)
        let eased = 1 - pow(1 - progress, 3)
        return target - Self.cellWidth * (1 - eased)
    }

    private func opacity(sinceMove: Double) -> Double {
        let idle = sinceMove - CaretStyle.restAfterMove
        guard idle > 0 else { return 1 }
        switch style.animation {
        case .steady:
            return 1
        case .blink:
            return idle.truncatingRemainder(dividingBy: 1.06) < 0.53 ? 1 : 0
        case .pulse:
            // 1 → 0.15 → 1 over 1.5 s, eased.
            let phase = idle.truncatingRemainder(dividingBy: 1.5) / 1.5
            return 0.15 + 0.85 * (0.5 + 0.5 * cos(phase * 2 * .pi))
        }
    }
}
