import PounceCore
import SwiftTerm
import SwiftUI
import UIKit

struct TerminalScreen: View {
    @Environment(SessionManager.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Session.ID
    @State private var showSnippets = false
    @State private var flash = false
    @Namespace private var chips
    @AppStorage("fontSize") private var fontSize = TerminalFont.defaultSize
    @AppStorage("keepAwake") private var keepAwake = true

    init(initial: Session.ID) {
        _selected = State(initialValue: initial)
    }

    private var session: Session? { sessions.sessions[id: selected] }

    var body: some View {
        ZStack {
            if let session {
                session.theme.color(session.theme.background).ignoresSafeArea()
                TerminalHost(session: session, fontSize: fontSize, showSnippets: $showSnippets)
                    .id(session.id)
                    .padding(.horizontal, 4)
                    .opacity(session.state == .connected || session.hasOutput ? 1 : 0)
                    .safeAreaInset(edge: .top, spacing: 0) { topBar(session) }
                StateOverlay(session: session)
                if session.asksForPassword {
                    PasswordChip(session: session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                        .transition(
                            reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                // the bell: a quick glow around the edges.
                RoundedRectangle(cornerRadius: 44)
                    .strokeBorder(Color.accentColor, lineWidth: flash ? 6 : 0)
                    .opacity(flash ? 0.8 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, (session?.theme.isDark ?? true) ? .dark : .light)
        .prompts(active: true)
        .overlay(alignment: .top) { NoticeBanner() }
        .sheet(isPresented: $showSnippets) {
            if let session { SnippetPicker(session: session) }
        }
        .sheet(item: startupBinding) { snippet in
            if let session { StartupSnippetSheet(session: session, snippet: snippet) }
        }
        .onChange(of: session?.bells) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.08)) { flash = true }
            withAnimation(.easeIn(duration: 0.35).delay(0.1)) { flash = false }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: session?.bells)
        .sensoryFeedback(trigger: session?.state) { _, new in
            switch new {
            case .connected: .impact(weight: .medium)
            case .failed: .error
            default: nil
            }
        }
        .onChange(of: sessions.sessions.map(\.id)) { _, ids in
            if !ids.contains(selected) {
                if let next = sessions.current, ids.contains(next) { selected = next } else { dismiss() }
            }
        }
        .onChange(of: selected) { _, id in sessions.current = id }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepAwake }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .statusBarHidden(false)
    }

    // MARK: top bar

    private func topBar(_ session: Session) -> some View {
        HStack(spacing: 10) {
            Button {
                sessions.presented = nil
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Back to hosts")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(sessions.sessions) { other in
                        chip(other)
                    }
                }
                .padding(4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .glassEffect(.regular, in: .capsule)

            menu(session)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func chip(_ other: Session) -> some View {
        let isSelected = other.id == selected
        return Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.25)) { selected = other.id }
        } label: {
            HStack(spacing: 6) {
                StatusDot(kind: other.state.dot)
                Text(other.displayTitle)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    Capsule().fill(.tint.opacity(0.22)).matchedGeometryEffect(id: "selection", in: chips)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Close", systemImage: "xmark", role: .destructive) { sessions.close(other) }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func menu(_ session: Session) -> some View {
        Menu {
            Section {
                Button("Snippets", systemImage: "text.alignleft") { showSnippets = true }
                Button("New Session", systemImage: "plus") {
                    let new = sessions.open(session.host)
                    selected = new.id
                }
                Button("Paste", systemImage: "doc.on.clipboard") {
                    if let text = UIPasteboard.general.string { session.terminal.view.send(txt: text) }
                }
            }
            Section {
                Picker(selection: themeBinding(session)) {
                    ForEach(TerminalTheme.all) { Text($0.name).tag($0.id) }
                } label: {
                    Label("Theme", systemImage: "paintpalette")
                }
                .pickerStyle(.menu)
                ControlGroup {
                    Button("Smaller", systemImage: "textformat.size.smaller") { changeFont(by: -1) }
                    Button("Larger", systemImage: "textformat.size.larger") { changeFont(by: 1) }
                }
            }
            Section {
                if !session.isLive {
                    Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() }
                }
                Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { sessions.close(session) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Session options")
    }

    private var startupBinding: Binding<Snippet?> {
        Binding(get: { session?.pendingStartup }, set: { session?.pendingStartup = $0 })
    }

    private func themeBinding(_ session: Session) -> Binding<String> {
        Binding(get: { session.theme.id }, set: { session.theme = TerminalTheme.named($0) })
    }

    private func changeFont(by delta: Double) {
        fontSize = TerminalFont.clamped(fontSize + delta)
    }
}

// MARK: - password

/// non-blocking: typing carries on and dismisses it.
private struct PasswordChip: View {
    let session: Session

    var body: some View {
        Button {
            Task { await session.fillPassword() }
        } label: {
            Label("Fill Password", systemImage: "key.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .buttonStyle(.glass)
        .disabled(session.isFilling)
        .sensoryFeedback(.success, trigger: session.isFilling) { old, new in old && !new }
    }
}

// MARK: - connection state

private struct StateOverlay: View {
    let session: Session
    @Environment(SessionManager.self) private var sessions

    var body: some View {
        Group {
            switch session.state {
            case .connecting:
                VStack(spacing: 18) {
                    HopTrail(hops: session.hops, stages: session.stages)
                    Text(currentStage.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .animation(.snappy, value: currentStage)
                    Button("Cancel") { sessions.close(session) }
                        .buttonStyle(.glass)
                }
                .overlayCard()
            case .failed(let message):
                card(symbol: "bolt.horizontal.circle", title: "Disconnected", message: message)
            case .exited(let status):
                card(
                    symbol: "checkmark.circle", title: "Session Ended",
                    message: status.map { $0 == 0 ? "The shell exited." : "The shell exited with status \($0)." }
                        ?? "The shell exited.")
            case .connected:
                EmptyView()
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.25), value: session.state)
        .padding(.horizontal, 24)
    }

    private var currentStage: ConnectStage {
        session.stages.last(where: { $0 > .connecting }) ?? .connecting
    }

    private func card(symbol: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, options: .nonRepeating)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Close") { sessions.close(session) }
                    .buttonStyle(.glass)
                Button("Reconnect") { session.reconnect() }
                    .buttonStyle(.glassProminent)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 296)
        .overlayCard()
    }
}

extension View {
    fileprivate func overlayCard() -> some View {
        padding(22)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
}

// MARK: - terminal view

/// the swiftterm view lives as long as the session, not this view.
private struct TerminalHost: UIViewRepresentable {
    let session: Session
    let fontSize: Double
    @Binding var showSnippets: Bool

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        let view = session.terminal.view
        view.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
        view.inputAccessoryView = KeyBarHost(session: session, showSnippets: $showSnippets)
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        view.addGestureRecognizer(pinch)
        context.coordinator.pinch = pinch
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.session = session
        let view = session.terminal.view
        if view.font.pointSize != fontSize { session.terminal.setFontSize(fontSize) }
    }

    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        if let pinch = coordinator.pinch { pinch.view?.removeGestureRecognizer(pinch) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor final class Coordinator: NSObject {
        var session: Session
        weak var pinch: UIPinchGestureRecognizer?
        private var startSize = TerminalFont.defaultSize

        init(session: Session) { self.session = session }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                startSize = session.terminal.view.font.pointSize
            case .changed:
                let size = TerminalFont.clamped((startSize * gesture.scale).rounded())
                if size != session.terminal.view.font.pointSize {
                    UserDefaults.standard.set(size, forKey: "fontSize")
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            default: break
            }
        }
    }
}

// MARK: - key bar

private final class KeyBarHost: UIInputView {
    private let host: UIHostingController<KeyBar>

    init(session: Session, showSnippets: Binding<Bool>) {
        host = UIHostingController(rootView: KeyBar(session: session, showSnippets: showSnippets))
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 52), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.sizingOptions = .intrinsicContentSize
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: 52),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private struct KeyBar: View {
    let session: Session
    @Binding var showSnippets: Bool
    @State private var control = Modifier.off
    @State private var meta = Modifier.off
    @State private var dragOffset: CGFloat = 0
    /// set when a hold just locked a modifier, so the tap that ends it is ignored.
    @State private var heldAt: Date?
    @AppStorage("modifierLock") private var lockGesture = ModifierLock.doubleTap

    private var view: TerminalView { session.terminal.view }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc") { view.send([0x1B]) }
                toggle("ctrl", state: $control) { view.controlModifier = $0 }
                toggle("alt", state: $meta) { view.metaModifier = $0 }
                key("tab") { view.send([0x09]) }
                arrows
                ForEach(["|", "~", "/", "-", "_", ":", "*"], id: \.self) { symbol in
                    key(symbol) { view.send(txt: symbol) }
                }
                if session.hasSavedPassword {
                    key(systemImage: "key.fill", label: "Fill Password") { Task { await session.fillPassword() } }
                        .disabled(session.isFilling)
                }
                key(systemImage: "text.alignleft", label: "Snippets") { showSnippets = true }
                key(systemImage: "keyboard.chevron.compact.down", label: "Hide keyboard") {
                    _ = view.resignFirstResponder()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        // swiftterm drops a modifier after each key; a locked one goes back on
        // (after swiftterm's own setter has returned).
        .onReceive(NotificationCenter.default.publisher(for: .terminalViewControlModifierReset)) {
            relock($0, $control) { view.controlModifier = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalViewMetaModifierReset)) {
            relock($0, $meta) { view.metaModifier = true }
        }
        .sensoryFeedback(trigger: control, Modifier.feedback)
        .sensoryFeedback(trigger: meta, Modifier.feedback)
    }

    private func relock(_ note: Notification, _ state: Binding<Modifier>, apply: @escaping () -> Void) {
        guard note.object as? TerminalView === view else { return }
        if state.wrappedValue == .locked { Task { apply() } } else { state.wrappedValue = .off }
    }

    /// also a trackpad: drag sideways across the arrows to move the cursor
    /// one cell per step.
    private var arrows: some View {
        HStack(spacing: 2) {
            ForEach([("left", 0x44), ("up", 0x41), ("down", 0x42), ("right", 0x43)] as [(String, UInt8)], id: \.0) {
                name, code in
                RepeatKey(systemImage: "arrow.\(name)", label: name.capitalized) { view.sendArrow(code) }
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in
                    let steps = Int((value.translation.width - dragOffset) / 14)
                    guard steps != 0 else { return }
                    for _ in 0..<abs(steps) { view.sendArrow(steps > 0 ? 0x43 : 0x44) }
                    dragOffset += CGFloat(steps) * 14
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                .onEnded { _ in dragOffset = 0 }
        )
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            UIDevice.current.playInputClick()
            action()
        }) {
            Text(title)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .frame(minWidth: 30, minHeight: 36)
                .padding(.horizontal, 6)
        }
        .buttonStyle(KeyStyle(isOn: false))
    }

    private func key(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(minWidth: 34, minHeight: 36)
        }
        .buttonStyle(KeyStyle(isOn: false))
        .accessibilityLabel(label)
    }

    /// a tap applies it to the next key. depending on the setting, a quick
    /// second tap or a hold locks it on until it's tapped again.
    private func toggle(_ title: String, state: Binding<Modifier>, apply: @escaping (Bool) -> Void) -> some View {
        let current = state.wrappedValue
        return Button {
            // lifting the finger after a hold that locked the key.
            if let heldAt, Date.now.timeIntervalSince(heldAt) < 10 {
                self.heldAt = nil
                return
            }
            let next = current.tapped(at: .now, doubleTapLocks: lockGesture == .doubleTap)
            state.wrappedValue = next
            apply(next != .off)
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .frame(minWidth: 34, minHeight: 36)
                .padding(.horizontal, 6)
                .overlay(alignment: .bottom) {
                    if current == .locked {
                        Capsule().frame(width: 14, height: 2.5).padding(.bottom, 4)
                    }
                }
        }
        .buttonStyle(KeyStyle(isOn: current != .off))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                guard lockGesture == .hold else { return }
                heldAt = .now
                state.wrappedValue = .locked
                apply(true)
            },
            isEnabled: lockGesture == .hold
        )
        .accessibilityValue(current == .locked ? "Locked" : current == .off ? "" : "On")
        .accessibilityHint(lockGesture == .hold ? "Touch and hold to lock" : "Double tap twice quickly to lock")
        .accessibilityAddTraits(current != .off ? .isSelected : [])
        .accessibilityAction(named: "Lock") {
            state.wrappedValue = .locked
            apply(true)
        }
    }
}

enum ModifierLock: String, CaseIterable, Identifiable {
    case doubleTap
    case hold

    var id: Self { self }

    var label: String {
        switch self {
        case .doubleTap: "Double Tap"
        case .hold: "Touch and Hold"
        }
    }
}

private enum Modifier: Equatable {
    case off
    /// on for the next key only. remembers when, to detect a double tap.
    case once(Date)
    case locked

    func tapped(at now: Date, doubleTapLocks: Bool) -> Modifier {
        switch self {
        case .off: .once(now)
        case .once(let since): doubleTapLocks && now.timeIntervalSince(since) < 0.35 ? .locked : .off
        case .locked: .off
        }
    }

    static func feedback(_ old: Modifier, _ new: Modifier) -> SensoryFeedback? {
        new == .locked ? .impact(weight: .medium) : .selection
    }
}

/// repeats while held, after a short pause.
private struct RepeatKey: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @State private var repeating: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 32, height: 34)
            .background(
                repeating == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.tint.opacity(0.25)),
                in: .rect(cornerRadius: 8)
            )
            .contentShape(.rect)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 12) {
            } onPressingChanged: { pressing in
                if pressing {
                    action()
                    repeating = Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        while !Task.isCancelled {
                            action()
                            try? await Task.sleep(for: .milliseconds(70))
                        }
                    }
                } else {
                    repeating?.cancel()
                    repeating = nil
                }
            }
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

private struct KeyStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(
                isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(configuration.isPressed ? 1 : 0.6)),
                in: .rect(cornerRadius: 9)
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.4), value: configuration.isPressed)
            .animation(.snappy, value: isOn)
    }
}
