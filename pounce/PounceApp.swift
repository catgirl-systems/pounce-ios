import SwiftUI

@main
struct PounceApp: App {
    @State private var app = AppModel.shared
    @State private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("accentHex") private var accentHex = Accent.defaultHex

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.sessions)
                .environment(app.tunnels)
                .environment(app.prompts)
                .overlay {
                    // hides terminal contents in the app switcher and while locked.
                    if scenePhase != .active || lock.isLocked {
                        PrivacyCover(lock: lock)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: scenePhase)
                .animation(.easeOut(duration: 0.25), value: lock.isLocked)
                // after the overlay, so the cover shown at launch is tinted too.
                .tint(Accent.color(hex: accentHex))
                // tapping the live activity comes back to the last session.
                .onOpenURL { url in
                    guard url.scheme == "pounce", url.host() == "sessions", let session = app.sessions.currentSession
                    else { return }
                    app.sessions.present(session)
                }
        }
        .onChange(of: scenePhase) { old, phase in
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
    @ObservationIgnored private var authenticating = false

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "appLock") }

    init() { isLocked = Self.isEnabled }

    func didEnterBackground() {
        backgroundedAt = .now
    }

    func unlockIfNeeded() {
        if let since = backgroundedAt, Date.now.timeIntervalSince(since) > 60, Self.isEnabled { isLocked = true }
        backgroundedAt = nil
        guard isLocked, !authenticating else { return }
        authenticating = true
        Task {
            let ok = await Biometry.authenticate("Unlock pounce")
            authenticating = false
            if ok { isLocked = false }
        }
    }
}

private struct PrivacyCover: View {
    let lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(spacing: 14) {
                Image(systemName: lock.isLocked ? "lock.fill" : "terminal.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.tint)
                    .contentTransition(.symbolEffect(.replace))
                if lock.isLocked {
                    Button("Unlock") { lock.unlockIfNeeded() }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .ignoresSafeArea()
    }
}
