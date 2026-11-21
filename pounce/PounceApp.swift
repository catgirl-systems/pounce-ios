import SwiftUI

@main
struct PounceApp: App {
    @State private var app = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("accentHex") private var accentHex = Accent.defaultHex
    @State private var cover = CoverWindow()

    private var lock: AppLock { app.lock }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.sessions)
                .environment(app.tunnels)
                .environment(app.prompts)
                .tint(Accent.color(hex: accentHex))
                // hides terminal contents in the app switcher and while locked.
                .onChange(of: [scenePhase != .active, lock.isLocked], initial: true) {
                    cover.update(covered: scenePhase != .active || lock.isLocked, lock: lock)
                }
                // tapping the live activity comes back to the last session.
                .onOpenURL { url in
                    guard url.scheme == "pounce", url.host() == "sessions", let session = app.sessions.currentSession
                    else { return }
                    app.sessions.present(session)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                app.sessions.didEnterBackground()
                lock.didEnterBackground()
            case .active:
                app.sessions.didBecomeActive()
                lock.unlockIfNeeded()
            default: break
            }
        }
    }
}

/// locks at launch and after a minute in the background.
@MainActor @Observable final class AppLock {
    private(set) var isLocked: Bool
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var unlocking: Task<Bool, Never>?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "appLock") }

    init() { isLocked = Self.isEnabled }

    /// also true while in the background past the grace period, before
    /// `unlockIfNeeded` has had a chance to lock.
    var needsUnlock: Bool {
        guard Self.isEnabled else { return false }
        if let since = backgroundedAt, Date.now.timeIntervalSince(since) > 60 { return true }
        return isLocked
    }

    func didEnterBackground() {
        backgroundedAt = .now
    }

    func unlockIfNeeded() {
        if needsUnlock { isLocked = true }
        backgroundedAt = nil
        guard isLocked else { return }
        Task { await unlock() }
    }

    /// shares one prompt between the lock screen and shortcuts waiting on it.
    @discardableResult
    func unlock() async -> Bool {
        if needsUnlock { isLocked = true }
        guard isLocked else { return true }
        let task = unlocking ?? Task { await Biometry.authenticate("Unlock pounce") }
        unlocking = task
        let ok = await task.value
        unlocking = nil
        if ok { isLocked = false }
        return ok
    }
}

/// the privacy cover gets a window of its own: an overlay on the root view
/// would sit under the terminal's full screen cover and under every sheet.
@MainActor final class CoverWindow {
    private var window: UIWindow?
    private var covered = false

    func update(covered: Bool, lock: AppLock) {
        self.covered = covered
        guard covered else { return hide() }
        guard let window = window ?? makeWindow(lock: lock) else {
            // no scene yet at launch; it's there a turn later.
            Task { if self.covered, self.window == nil { self.update(covered: true, lock: lock) } }
            return
        }
        window.layer.removeAllAnimations()
        window.alpha = 1
        guard lock.isLocked else {
            window.isHidden = false
            return
        }
        // the keyboard's window sits above this one, so whatever is being typed
        // into has to let go of it.
        for other in window.windowScene?.windows ?? [] where other !== window { other.endEditing(true) }
        window.makeKeyAndVisible()
    }

    private func hide() {
        guard let window, !window.isHidden else { return }
        UIView.animate(withDuration: 0.2) {
            window.alpha = 0
        } completion: { _ in
            if !self.covered { window.isHidden = true }
        }
    }

    private func makeWindow(lock: AppLock) -> UIWindow? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            return nil
        }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: PrivacyCover(lock: lock))
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        window.rootViewController = host
        self.window = window
        return window
    }
}

private struct PrivacyCover: View {
    let lock: AppLock
    @AppStorage("accentHex") private var accentHex = Accent.defaultHex

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(spacing: 14) {
                Image(systemName: lock.isLocked ? "lock.fill" : "terminal.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                if lock.isLocked {
                    Button("Unlock") { lock.unlockIfNeeded() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .ignoresSafeArea()
        .tint(Accent.color(hex: accentHex))
    }
}
