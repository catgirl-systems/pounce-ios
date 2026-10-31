import PounceCore
import SwiftUI

// MARK: - notice banner

struct NoticeBanner: View {
    /// the terminal covers the root view's banner, so each copy shows it
    /// only while it's on top.
    var active = true
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if active, let notice = app.notice {
                banner(notice)
                    .id(notice.id)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .move(edge: .top).combined(with: .scale(scale: 0.85, anchor: .top)),
                                removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.32), value: app.notice)
        .onChange(of: app.notice) { _, notice in
            guard active, let notice else { return }
            AccessibilityNotification.Announcement(
                [notice.title, notice.subtitle].compactMap { $0 }.joined(separator: ", ")
            ).post()
        }
        .sensoryFeedback(trigger: app.notice) { _, new in
            guard active, let new else { return nil }
            return new.isError ? .error : .success
        }
    }

    private func banner(_ notice: Notice) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .center, spacing: 1) {
                Text(notice.title).font(.subheadline.weight(.semibold)).lineLimit(3)
                if let subtitle = notice.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
            NoticeSymbol(notice: notice)
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 24)
        .onTapGesture { app.notice = nil }
        .gesture(DragGesture(minimumDistance: 8).onEnded { if $0.translation.height < 0 { app.notice = nil } })
        .task {
            // cancelled means this copy went away (the terminal closed, say),
            // not that time is up: leave the notice for the other copy.
            do { try await Task.sleep(for: .seconds(Self.readingTime(notice))) } catch { return }
            if app.notice?.id == notice.id { app.notice = nil }
        }
    }
}

extension NoticeBanner {
    /// a base plus time per word, more for errors; a tap dismisses sooner.
    static func readingTime(_ notice: Notice) -> Double {
        let words = "\(notice.title) \(notice.subtitle ?? "")".split(whereSeparator: \.isWhitespace).count
        let base = notice.isError ? 4.0 : 3.0
        return min(notice.isError ? 10 : 6, base + Double(words) * 0.3)
    }
}

private struct NoticeSymbol: View {
    let notice: Notice
    @State private var shown = false

    var body: some View {
        ZStack {
            if shown {
                Image(systemName: notice.symbol)
                    .font(.body.weight(.bold))
                    .foregroundStyle(notice.tint)
                    .transition(.symbolEffect(.drawOn))
            }
        }
        .frame(width: 22, height: 22)
        .task {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeOut(duration: 0.35)) { shown = true }
        }
    }
}

// MARK: - status

struct StatusDot: View {
    enum Kind { case idle, connecting, connected, failed }
    let kind: Kind
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if kind == .connecting, !reduceMotion {
                    Circle()
                        .stroke(color.opacity(0.6), lineWidth: 2)
                        .phaseAnimator([false, true]) { view, on in
                            view.scaleEffect(on ? 2.4 : 1).opacity(on ? 0 : 0.9)
                        } animation: { _ in
                            .easeOut(duration: 1.1)
                        }
                }
            }
            .animation(.snappy, value: kind)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch kind {
        case .idle: .secondary.opacity(0.4)
        case .connecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }
}

extension Session.State {
    var dot: StatusDot.Kind {
        switch self {
        case .connecting: .connecting
        case .connected: .connected
        case .failed: .failed
        case .exited: .idle
        }
    }
}

// MARK: - randomart

struct RandomartView: View {
    let lines: [String]
    @State private var revealed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Int { lines.reduce(0) { $0 + $1.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                Text(line)
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityLabel("Key randomart")
        .task(id: lines) {
            guard !reduceMotion else {
                revealed = total
                return
            }
            revealed = 0
            // about 0.6 s for the whole picture.
            let step = max(1, total / 60)
            while revealed < total {
                try? await Task.sleep(for: .milliseconds(10))
                revealed = min(total, revealed + step)
            }
        }
    }

    /// blanks everything past the reveal point so the frame keeps its size
    /// while the art draws in.
    private var visibleLines: [String] {
        var budget = revealed
        return lines.map { line in
            let shown = line.prefix(max(0, budget))
            budget -= line.count
            return String(shown) + String(repeating: " ", count: line.count - shown.count)
        }
    }
}

struct FingerprintText: View {
    let fingerprint: String

    var body: some View {
        Text(fingerprint)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(3)
    }
}

// MARK: - hops

struct HopTrail: View {
    let hops: [String]
    let stages: [ConnectStage]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone").foregroundStyle(.secondary)
            ForEach(Array(hops.enumerated()), id: \.offset) { index, hop in
                Image(systemName: "chevron.compact.right")
                    .foregroundStyle(.tertiary)
                let stage = stages.indices.contains(index) ? stages[index] : .connecting
                Text(hop)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(background(for: stage, index: index), in: .capsule)
                    .foregroundStyle(stage == .ready ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .scaleEffect(stage == .ready ? 1 : 0.96)
            }
        }
        .font(.caption.weight(.medium))
        .accessibilityElement(children: .combine)
    }

    private func background(for stage: ConnectStage, index: Int) -> AnyShapeStyle {
        switch stage {
        case .ready: AnyShapeStyle(.tint)
        case .connecting where !isActive(index): AnyShapeStyle(.quaternary.opacity(0.5))
        default: AnyShapeStyle(.tint.opacity(0.25))
        }
    }

    private func isActive(_ index: Int) -> Bool {
        index == 0 || (stages.indices.contains(index - 1) && stages[index - 1] == .ready)
    }
}

extension ConnectStage {
    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .securing: "Securing"
        case .authenticating: "Signing in"
        case .ready: "Connected"
        }
    }
}

// MARK: - themes

struct ThemePreview: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line([("molly@cat", 2), (":", 7), ("~/src", 4), ("$ ", 7), ("ls", -1)])
            line([("README.md  ", -1), ("build/  ", 4), ("run.sh", 2)])
            HStack(spacing: 0) {
                line([("$ ", 7)])
                Rectangle().fill(theme.color(theme.cursor)).frame(width: 7, height: 13)
            }
            HStack(spacing: 3) {
                ForEach(0..<8) { index in
                    RoundedRectangle(cornerRadius: 2).fill(theme.color(theme.ansi[index])).frame(height: 5)
                }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color(theme.background), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .accessibilityHidden(true)
    }

    /// -1 means the default foreground.
    private func line(_ runs: [(String, Int)]) -> some View {
        var line = AttributedString()
        for (text, color) in runs {
            var run = AttributedString(text)
            run.foregroundColor = theme.color(color < 0 ? theme.foreground : theme.ansi[color])
            line += run
        }
        return Text(line)
    }
}

// MARK: - forms

extension View {
    /// `action` is responsible for dismissing when it's done.
    func editorToolbar(
        _ title: String, confirm: String = "Save", disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(EditorToolbar(confirm: confirm, disabled: disabled, action: action))
    }

    /// with `cancel`, an xmark button instead of done.
    func dismissToolbar(_ title: String = "Done", cancel: Bool = false) -> some View {
        modifier(DismissToolbar(title: title, cancel: cancel))
    }
}

private struct EditorToolbar: ViewModifier {
    let confirm: String
    let disabled: Bool
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(confirm, systemImage: "checkmark", action: action).disabled(disabled)
            }
        }
    }
}

private struct DismissToolbar: ViewModifier {
    let title: String
    let cancel: Bool
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: cancel ? .cancellationAction : .confirmationAction) {
                Button(title, systemImage: cancel ? "xmark" : "checkmark") { dismiss() }
            }
        }
    }
}

struct PortField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: $value, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct CodeEditor: View {
    @Binding var text: String
    var placeholder = ""
    var font: Font = .system(.footnote, design: .monospaced)
    var minHeight: CGFloat = 160

    var body: some View {
        TextEditor(text: $text)
            .font(font)
            .frame(minHeight: minHeight)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - formatting

extension Int {
    var byteCount: String { ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .binary) }
}

extension KeyKind {
    var label: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsaP256: "ECDSA P-256"
        case .ecdsaP384: "ECDSA P-384"
        case .ecdsaP521: "ECDSA P-521"
        case .rsa: "RSA"
        case .secureEnclaveP256: "Secure Enclave"
        }
    }

    var symbol: String {
        self == .secureEnclaveP256 ? "cpu" : "key.horizontal"
    }
}

struct CrouchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.3, bounce: 0.45), value: configuration.isPressed)
    }
}

// MARK: - icons

extension Host {
    var symbol: String { icon ?? defaultSymbol }

    var defaultSymbol: String {
        jumpHostIDs.isEmpty ? "terminal" : "point.topleft.down.to.point.bottomright.curvepath"
    }
}

extension Identity {
    var symbol: String { icon ?? kind.symbol }
}

struct IconTile: View {
    let symbol: String
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5))
            .foregroundStyle(.tint)
            .frame(width: size, height: size)
            .background(.tint.opacity(0.12), in: .rect(cornerRadius: size * 0.26))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// picking the default clears the choice.
struct IconPickerRow: View {
    @Binding var icon: String?
    let defaultSymbol: String
    let symbols: [String]

    var body: some View {
        NavigationLink {
            IconPickerView(icon: $icon, defaultSymbol: defaultSymbol, symbols: symbols)
        } label: {
            LabeledContent("Icon") {
                IconTile(symbol: icon ?? defaultSymbol, size: 28)
            }
        }
    }
}

private struct IconPickerView: View {
    @Binding var icon: String?
    let defaultSymbol: String
    let symbols: [String]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 12)], spacing: 12) {
                cell(defaultSymbol, isDefault: true)
                ForEach(symbols.filter { $0 != defaultSymbol }, id: \.self) { cell($0, isDefault: false) }
            }
            .padding()
        }
        .navigationTitle("Icon")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: icon)
    }

    private func cell(_ symbol: String, isDefault: Bool) -> some View {
        let isSelected = (icon ?? defaultSymbol) == symbol
        return Button {
            withAnimation(.snappy) { icon = isDefault ? nil : symbol }
        } label: {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                .frame(width: 52, height: 52)
                .background(
                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.12)), in: .rect(cornerRadius: 13))
        }
        .buttonStyle(CrouchButtonStyle())
        .accessibilityLabel(isDefault ? "Default" : symbol.replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

enum IconChoices {
    static let host = [
        "server.rack", "desktopcomputer", "laptopcomputer", "macmini", "pc", "display", "cpu", "memorychip",
        "externaldrive", "internaldrive", "opticaldiscdrive", "cloud", "globe", "network", "wifi.router",
        "antenna.radiowaves.left.and.right", "house", "building.2", "building.columns", "briefcase", "tv",
        "gamecontroller", "printer", "camera", "music.note", "film", "lock.shield", "shield.lefthalf.filled",
        "cylinder.split.1x2", "shippingbox", "cube", "square.stack.3d.up", "hammer", "wrench.and.screwdriver",
        "flask", "testtube.2", "chevron.left.forwardslash.chevron.right", "terminal", "apple.terminal",
        "bolt", "flame", "leaf", "tree", "sun.max", "moon", "star", "heart", "sparkles", "pawprint", "cat",
        "dog", "fish", "bird", "ant", "tortoise", "hare", "ladybug", "airplane", "car", "sailboat",
    ]

    static let key = [
        "key.horizontal", "key", "key.fill", "key.2.on.ring", "lock", "lock.shield", "lock.rectangle",
        "person", "person.badge.key", "person.2", "cpu", "iphone", "laptopcomputer", "desktopcomputer",
        "server.rack", "cloud", "house", "building.2", "briefcase", "graduationcap", "hammer",
        "wrench.and.screwdriver", "flask", "shippingbox", "bolt", "flame", "leaf", "star", "heart", "sparkles",
        "crown", "flag", "tag", "bookmark", "pawprint", "cat", "dog", "fish", "bird", "ladybug",
    ]
}
