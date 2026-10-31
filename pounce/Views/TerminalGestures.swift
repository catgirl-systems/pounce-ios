import SwiftTerm
import UIKit

/// replaces swiftterm's touch handling: long press selects a word and extends
/// with a loupe as the finger drags, handles stay draggable, double tap sends
/// tab, and without scrollback (tmux, less, vim) swipes send wheel/arrow keys.
@MainActor final class TerminalGestures: NSObject, UIGestureRecognizerDelegate {
    private unowned let view: TerminalView
    private let doubleTapped: () -> Void
    private let longPress = UILongPressGestureRecognizer()
    private let handlePan = UIPanGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private let wheelPan = UIPanGestureRecognizer()
    /// the end of the selection that stays put while the other one moves.
    private var anchor = Position(col: 0, row: 0)
    /// the word the long press landed on, kept whole while dragging past it.
    private var seed: (start: Position, end: Position)?
    private var loupe: UITextLoupeSession?
    private var autoscroll: Task<Void, Never>?
    private var lastFocus: Position?
    /// relative to the visible part of the terminal, for extending the
    /// selection while it scrolls by itself.
    private var touch = CGPoint.zero
    /// finger travel not yet turned into wheel or arrow steps.
    private var wheelTravel: CGFloat = 0
    private var wheelPoint = CGPoint.zero
    private var coast: Task<Void, Never>?

    init(view: TerminalView, doubleTapped: @escaping () -> Void) {
        self.view = view
        self.doubleTapped = doubleTapped
        super.init()

        // swiftterm's own long press only opens a menu with `Select`, and its
        // double and triple taps select a word or a line. ours replace them.
        for recognizer in view.gestureRecognizers ?? [] {
            if recognizer is UILongPressGestureRecognizer
                || (recognizer as? UITapGestureRecognizer)?.numberOfTapsRequired ?? 1 > 1
            {
                view.removeGestureRecognizer(recognizer)
            }
        }

        longPress.addTarget(self, action: #selector(pressed(_:)))
        longPress.minimumPressDuration = 0.3
        longPress.delegate = self
        view.addGestureRecognizer(longPress)

        handlePan.addTarget(self, action: #selector(draggedHandle(_:)))
        handlePan.delegate = self
        handlePan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(handlePan)
        // scrolling waits for the handle drag to decline, which it does
        // straight away unless the touch lands on a handle.
        view.panGestureRecognizer.require(toFail: handlePan)

        wheelPan.addTarget(self, action: #selector(swiped(_:)))
        wheelPan.delegate = self
        wheelPan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(wheelPan)
        wheelPan.require(toFail: handlePan)
        // same here: the wheel declines straight away when there's
        // scrollback to scroll natively.
        view.panGestureRecognizer.require(toFail: wheelPan)

        doubleTap.addTarget(self, action: #selector(tappedTwice(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        for case let tap as UITapGestureRecognizer in view.gestureRecognizers ?? []
        where tap !== doubleTap && tap.numberOfTapsRequired == 1 {
            tap.require(toFail: doubleTap)
        }
    }

    // MARK: double tap

    @objc private func tappedTwice(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        UIDevice.current.playInputClick()
        doubleTapped()
    }

    // MARK: long press

    @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            _ = view.becomeFirstResponder()
            let position = view.bufferPosition(at: point)
            view.selection.selectWordOrExpression(at: position, in: view.getTerminal().buffer)
            let (start, end) = (view.selection.start, view.selection.end)
            let word = ordered(
                start, Position.compare(start, end) == .equal ? Position(col: start.col + 1, row: start.row) : end)
            seed = word
            setSelection(word.0, word.1)
            lastFocus = position
            view.isScrollEnabled = false
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            loupe = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: nil, in: view)
        case .changed:
            extend(to: point)
        case .ended, .cancelled, .failed:
            finish()
        default:
            break
        }
    }

    // MARK: handles

    /// generous targets, since the drawn handles are small.
    private func handle(at point: CGPoint) -> (moving: Position, fixed: Position)? {
        guard view.selection.active else { return nil }
        let cell = view.cellSize
        let (start, end) = ordered(view.selection.start, view.selection.end)
        let startPoint = CGPoint(x: CGFloat(start.col) * cell.width, y: CGFloat(start.row) * cell.height)
        let endPoint = CGPoint(x: CGFloat(end.col) * cell.width, y: CGFloat(end.row + 1) * cell.height)
        let reach: CGFloat = 30
        let toStart = hypot(point.x - startPoint.x, point.y - startPoint.y)
        let toEnd = hypot(point.x - endPoint.x, point.y - endPoint.y)
        guard min(toStart, toEnd) < reach else { return nil }
        return toStart < toEnd ? (start, end) : (end, start)
    }

    @objc private func draggedHandle(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: view)
        switch gesture.state {
        case .began:
            guard let grabbed = handle(at: gesture.location(in: view)) else { return }
            anchor = grabbed.fixed
            seed = nil
            lastFocus = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            loupe = UITextLoupeSession.begin(at: point, fromSelectionWidgetView: nil, in: view)
        case .changed:
            extend(to: point)
        case .ended, .cancelled, .failed:
            finish()
        default:
            break
        }
    }

    // MARK: extending

    /// with a seed word, the word stays selected whichever way the finger goes.
    private func extend(to point: CGPoint) {
        loupe?.move(to: point, withCaretRect: .zero, trackingCaret: false)
        scrollIfNeeded(near: point)
        moveFocus(to: point)
    }

    private func moveFocus(to point: CGPoint) {
        let focus = view.bufferPosition(at: point)
        guard focus != lastFocus else { return }
        lastFocus = focus
        let past = Position(col: focus.col + 1, row: focus.row)
        if let seed {
            if Position.compare(focus, seed.start) == .before {
                setSelection(focus, seed.end)
            } else {
                setSelection(seed.start, Position.compare(past, seed.end) == .after ? past : seed.end)
            }
        } else if Position.compare(focus, anchor) == .before {
            setSelection(focus, anchor)
        } else {
            setSelection(anchor, past)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func finish() {
        autoscroll?.cancel()
        autoscroll = nil
        loupe?.invalidate()
        loupe = nil
        seed = nil
        lastFocus = nil
        view.isScrollEnabled = true
        view.showSelectionMenu()
    }

    private func setSelection(_ start: Position, _ end: Position) {
        view.setSelectionRange(start: start, end: end)
        view.refreshSelection()
    }

    private func ordered(_ a: Position, _ b: Position) -> (Position, Position) {
        Position.compare(a, b) == .after ? (b, a) : (a, b)
    }

    /// dragging into the top or bottom band scrolls a line at a time, so a
    /// selection can run past what's on screen.
    private func scrollIfNeeded(near point: CGPoint) {
        let band = view.cellSize.height * 1.5
        touch = CGPoint(x: point.x, y: point.y - view.contentOffset.y)
        let y = touch.y
        let step: CGFloat =
            if y < band { -view.cellSize.height } else if y > view.bounds.height - band { view.cellSize.height } else {
                0
            }
        guard step != 0 else {
            autoscroll?.cancel()
            autoscroll = nil
            return
        }
        guard autoscroll == nil else { return }
        autoscroll = Task { [weak self] in
            while !Task.isCancelled, let self {
                let maxY = max(0, self.view.contentSize.height - self.view.bounds.height)
                let offset = min(maxY, max(0, self.view.contentOffset.y + step))
                guard offset != self.view.contentOffset.y else { break }
                self.view.contentOffset.y = offset
                self.moveFocus(to: CGPoint(x: self.touch.x, y: self.touch.y + offset))
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    // MARK: wheel

    /// a vertical swipe goes to the remote program when it asked for the
    /// mouse, or on the alternate screen, which has no scrollback of its own.
    private var swipesGoRemote: Bool {
        let terminal = view.getTerminal()
        return terminal.mouseMode != .off || terminal.isCurrentBufferAlternate
    }

    @objc private func swiped(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            coast?.cancel()
            coast = nil
            wheelTravel = 0
            wheelPoint = gesture.location(in: view)
        case .changed:
            let translation = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            travel(translation.y)
        case .ended:
            coastAway(from: gesture.velocity(in: view).y)
        default:
            break
        }
    }

    /// a wheel notch every two rows (tmux, vim and less scroll several lines
    /// per notch), or an arrow key per row.
    private func travel(_ distance: CGFloat) {
        let terminal = view.getTerminal()
        let wheel = terminal.mouseMode != .off
        let step = view.cellSize.height * (wheel ? 2 : 1)
        guard step > 0 else { return }
        wheelTravel += distance
        while abs(wheelTravel) >= step {
            // dragging down reveals what's above, like scrolling the history.
            let up = wheelTravel > 0
            wheelTravel -= up ? step : -step
            if wheel {
                sendWheel(up: up)
            } else {
                view.sendArrow(up ? 0x41 : 0x42)
            }
        }
    }

    private func sendWheel(up: Bool) {
        let terminal = view.getTerminal()
        let cell = view.cellSize
        let position = view.bufferPosition(at: wheelPoint)
        let col = max(0, min(terminal.cols - 1, position.col))
        let row = max(0, min(terminal.rows - 1, position.row - terminal.buffer.yDisp))
        let flags = terminal.encodeButton(button: up ? 4 : 5, release: false, shift: false, meta: false, control: false)
        terminal.sendEvent(
            buttonFlags: flags, x: col, y: row,
            pixelX: Int(CGFloat(col) * cell.width), pixelY: Int(CGFloat(row) * cell.height))
    }

    private func coastAway(from velocity: CGFloat) {
        guard abs(velocity) > 200 else { return }
        coast = Task { [weak self] in
            var velocity = velocity
            let frame = 1.0 / 60
            while !Task.isCancelled, abs(velocity) > 60, let self {
                self.travel(velocity * frame)
                velocity *= 0.97
                try? await Task.sleep(for: .seconds(frame))
            }
        }
    }

    // MARK: `UIGestureRecognizerDelegate`

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture === handlePan { return handle(at: gesture.location(in: view)) != nil }
        if gesture === wheelPan {
            guard swipesGoRemote else { return false }
            let velocity = wheelPan.velocity(in: view)
            return abs(velocity.y) > abs(velocity.x)
        }
        return true
    }
}
