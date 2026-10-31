import Foundation
import Observation
import PounceCore
import SwiftTerm
import SwiftUI
import UIKit

@MainActor @Observable final class Session: Identifiable {
    enum State: Equatable {
        case connecting
        case connected
        /// dropped or never came up; can be retried.
        case failed(String)
        case exited(Int?)
    }

    let id = UUID()
    let host: Host
    /// for the hop capsules.
    let hops: [String]
    private(set) var state = State.connecting
    private(set) var stages: [ConnectStage]
    /// set via an osc title sequence; only shown while settings allows it.
    private(set) var title: String?
    /// bumped on every bel, for the haptic and the edge flash.
    private(set) var bells = 0
    /// keeps a dropped session showing its last screen under the overlay.
    private(set) var hasOutput = false
    /// an established connection dropped, as opposed to one that never came up.
    /// only these reconnect on their own.
    private(set) var dropped = false
    /// the remote side is asking for a password and the host has one saved.
    private(set) var asksForPassword = false
    private(set) var hasSavedPassword = false
    private(set) var isFilling = false
    /// waits here until its placeholders are filled in.
    var pendingStartup: Snippet?
    var theme: TerminalTheme {
        didSet {
            theme.apply(to: terminal.view)
            terminal.caret?.themeChanged()
        }
    }

    let terminal: TerminalController
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var shell: SSHShell?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sentStartup = false

    init(host: Host, hops: [String], theme: TerminalTheme, fontSize: CGFloat) {
        self.host = host
        self.hops = hops
        self.stages = Array(repeating: .connecting, count: hops.count)
        self.theme = theme
        self.terminal = TerminalController(theme: theme, fontSize: fontSize)
        terminal.session = self
    }

    var displayTitle: String {
        guard let title, !title.isEmpty, UserDefaults.standard.bool(forKey: "programTitles", default: true) else {
            return host.displayName
        }
        return title
    }

    var isLive: Bool { state == .connected || state == .connecting }

    func start() {
        task?.cancel()
        state = .connecting
        dropped = false
        stages = Array(repeating: .connecting, count: hops.count)
        task = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        do {
            let connection = try await AppModel.shared.connect(host) { [weak self] hop, stage in
                Task { @MainActor in self?.advance(hop: hop, to: stage) }
            }
            guard !Task.isCancelled else {
                connection.close()
                return
            }
            self.connection = connection
            let size = terminal.size
            let shell = try await connection.openShell(
                columns: size.cols, rows: size.rows, environment: ["LANG": "en_US.UTF-8"])
            guard !Task.isCancelled else {
                connection.close()
                return
            }
            self.shell = shell
            let hostID = host.id
            hasSavedPassword = await Task.detached { Keychain.hasPassword(for: hostID) }.value
            withAnimation(.snappy) { state = .connected }
            if !sentStartup, let snippet = AppModel.shared.snippet(host.startupSnippetID) {
                sentStartup = true
                if snippet.placeholders.isEmpty { run(snippet, values: [:]) } else { pendingStartup = snippet }
            }
            for await chunk in shell.output {
                if !hasOutput { hasOutput = true }
                terminal.feed(chunk)
                checkForPasswordPrompt()
            }
            // output ends when the shell exits (we have its status) or the connection
            // goes away.
            if let status = shell.exitStatus {
                state = .exited(status)
                connection.close()
                endedWithoutCard(error: nil, status: status)
            } else if !Task.isCancelled {
                dropped = true
                state = .failed("The connection was lost.")
                endedWithoutCard(error: "Connection lost")
            }
        } catch {
            guard !Task.isCancelled else { return }
            log.error("session failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
            endedWithoutCard(error: error.localizedDescription)
        }
        shell = nil
    }

    /// with the end-of-session card off, the session closes itself with a toast.
    /// only a connection dropped outside the foreground stays, to reconnect on
    /// return; an exited shell closes regardless.
    private func endedWithoutCard(error: String?, status: Int? = nil) {
        guard !UserDefaults.standard.bool(forKey: "showEndCard", default: true),
            !dropped || UIApplication.shared.applicationState == .active
        else { return }
        let app = AppModel.shared
        if let error {
            app.fail(error, subtitle: host.displayName)
        } else {
            app.notify(
                "Session ended",
                subtitle: status.map { $0 == 0 ? host.displayName : "\(host.displayName) · exit \($0)" }
                    ?? host.displayName)
        }
        app.sessions.close(self)
    }

    private func advance(hop: Int, to stage: ConnectStage) {
        guard stages.indices.contains(hop), stage > stages[hop] else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.3)) { stages[hop] = stage }
    }

    func send(_ bytes: [UInt8]) {
        if asksForPassword { withAnimation(.snappy) { asksForPassword = false } }
        shell?.write(bytes)
    }

    private func checkForPasswordPrompt() {
        guard hasSavedPassword else { return }
        let terminal = terminal.view.getTerminal()
        let buffer = terminal.buffer
        let line = terminal.getLine(row: buffer.y)?.translateToString(trimRight: true, endCol: buffer.x) ?? ""
        let asks = PasswordPrompt.matches(line)
        if asks != asksForPassword { withAnimation(.snappy) { asksForPassword = asks } }
    }

    /// asks for face id first when the setting requires it.
    func fillPassword() async {
        guard !isFilling else { return }
        isFilling = true
        defer { isFilling = false }
        if UserDefaults.standard.bool(forKey: "fillNeedsBiometry") {
            guard await Biometry.authenticate("Fill the saved password") else { return }
        }
        let hostID = host.id
        guard let password = await Task.detached(operation: { Keychain.password(for: hostID) }).value else {
            log.error("no saved password to fill")
            return
        }
        send(Array((password + "\r").utf8))
    }

    func run(_ snippet: Snippet, values: [String: String]) {
        send(Array((snippet.filled(values) + (snippet.runImmediately ? "\r" : "")).utf8))
    }

    func resize(columns: Int, rows: Int) { shell?.resize(columns: columns, rows: rows) }

    func ring() { bells += 1 }

    func setTitle(_ title: String) { self.title = title }

    /// keeps what's on screen.
    func reconnect() {
        connection?.close()
        terminal.feed(Array("\r\n\u{1B}[2m— reconnecting —\u{1B}[0m\r\n".utf8))
        start()
    }

    func close() {
        task?.cancel()
        task = nil
        shell?.close()
        connection?.close()
        connection = nil
    }
}

/// owns the swiftterm view so the terminal and its scrollback outlive any
/// swiftui view showing it.
@MainActor final class TerminalController: NSObject, TerminalViewDelegate {
    let view: TerminalView
    weak var session: Session?
    private var gestures: TerminalGestures?
    private(set) var caret: TerminalCaret?

    init(theme: TerminalTheme, fontSize: CGFloat) {
        view = PounceTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        super.init()
        view.terminalDelegate = self
        setFontSize(fontSize)
        view.optionAsMetaKey = true
        theme.apply(to: view)
        // our key bar replaces swiftterm's.
        view.inputAccessoryView = nil
        gestures = TerminalGestures(view: view) { [weak self] in self?.view.send([0x09]) }
        caret = TerminalCaret(terminal: view)
    }

    var size: (cols: Int, rows: Int) {
        let terminal = view.getTerminal()
        return (max(terminal.cols, 20), max(terminal.rows, 5))
    }

    func feed(_ bytes: [UInt8]) {
        view.feed(byteArray: bytes[...])
    }

    func setFontSize(_ size: CGFloat) {
        view.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: `TerminalViewDelegate`
    // swiftterm calls these on the main thread.

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated { session?.send(bytes) }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { session?.resize(columns: newCols, rows: newRows) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated { session?.setTitle(title) }
    }

    nonisolated func bell(source: TerminalView) {
        MainActor.assumeIsolated { session?.ring() }
    }

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        MainActor.assumeIsolated {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return
            }
            UIApplication.shared.open(url)
        }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        // osc 52 from the remote side, like tmux or vim copying.
        MainActor.assumeIsolated {
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }
}

/// swiftterm minus its mouse drag: when the remote program asks for the
/// mouse, swiftterm turns a pan into a held left button, which makes tmux
/// select text. `TerminalGestures` sends the wheel instead.
private final class PounceTerminalView: TerminalView {
    override func mouseModeChanged(source: Terminal) {}
}

extension TerminalView {
    /// `code` is `A` to `D` for up, down, right, left, in whichever cursor mode
    /// the remote program asked for (vim and less use application mode).
    func sendArrow(_ code: UInt8) {
        send([0x1B, getTerminal().applicationCursor ? 0x4F : 0x5B, code])
    }
}

@MainActor @Observable final class SessionManager {
    private(set) var sessions: [Session] = []
    var presented: Session.ID?
    /// for going back to it from the bottom bar.
    var current: Session.ID?

    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var wasInBackground = false

    var presentedSession: Session? { sessions[id: presented] }
    var currentSession: Session? { sessions[id: current] ?? sessions.first }

    @discardableResult
    func open(_ host: Host) -> Session {
        let app = AppModel.shared
        let chain = (try? app.jumpChain(for: host)) ?? [host]
        let defaults = UserDefaults.standard
        let size = defaults.double(forKey: "fontSize")
        let theme = TerminalTheme.named(host.themeID ?? defaults.string(forKey: "themeID"))
        let session = Session(
            host: host, hops: chain.map(\.displayName), theme: theme,
            fontSize: size > 0 ? size : TerminalFont.defaultSize)
        sessions.append(session)
        session.start()
        present(session)
        return session
    }

    func present(_ session: Session) {
        current = session.id
        presented = session.id
    }

    func close(_ session: Session) {
        session.close()
        let index = sessions.firstIndex { $0.id == session.id }
        sessions.removeAll { $0.id == session.id }
        if presented == session.id || current == session.id {
            // move to a neighbour, or leave the terminal when it was the last.
            let next = index.flatMap { sessions.indices.contains($0) ? sessions[$0] : sessions.last }
            current = next?.id
            if presented == session.id { presented = next?.id }
        }
    }

    func closeAll() {
        for session in sessions { session.close() }
        sessions = []
        presented = nil
        current = nil
    }

    func sessions(for host: Host) -> [Session] { sessions.filter { $0.host.id == host.id } }

    // MARK: background

    /// asks ios for extra time so a quick trip to another app doesn't drop the
    /// connections.
    func didEnterBackground() {
        wasInBackground = true
        guard AppModel.shared.hasOpenConnections, backgroundTask == .invalid else { return }
        // with location on, the app keeps running and nothing pauses.
        guard !AppModel.shared.keeper.isRunning else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Keep SSH sessions") { [weak self] in
            MainActor.assumeIsolated {
                // out of time: say so on the live activity before ios suspends the app.
                _ = Task {
                    await AppModel.shared.liveActivity.pausing()
                    self?.endBackgroundTask()
                }
            }
        }
        AppModel.shared.liveActivity.enteredBackground(remaining: UIApplication.shared.backgroundTimeRemaining)
    }

    /// reconnects whatever dropped; returning from a face id prompt or control
    /// center doesn't count.
    func didBecomeActive() {
        endBackgroundTask()
        guard wasInBackground else { return }
        wasInBackground = false
        AppModel.shared.liveActivity.becameActive()
        for session in sessions where session.dropped { session.reconnect() }
        AppModel.shared.tunnels.restartDropped()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension UserDefaults {
    /// like `@AppStorage` with a `true` default.
    func bool(forKey key: String, default value: Bool) -> Bool {
        object(forKey: key) as? Bool ?? value
    }
}
