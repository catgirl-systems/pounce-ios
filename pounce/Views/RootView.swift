import PounceCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(SessionManager.self) private var sessions
    @SceneStorage("tab") private var tab = "hosts"
    @Namespace private var namespace

    var body: some View {
        @Bindable var sessions = sessions
        TabView(selection: $tab) {
            Tab("Hosts", systemImage: "server.rack", value: "hosts") {
                NavigationStack { HostListView(namespace: namespace) }
            }
            Tab("Keys", systemImage: "key.horizontal.fill", value: "keys") {
                NavigationStack { IdentityListView() }
            }
            Tab("Tunnels", systemImage: "point.3.connected.trianglepath.dotted", value: "tunnels") {
                NavigationStack { TunnelListView() }
            }
            .badge(app.tunnels.runningCount)
            Tab("Snippets", systemImage: "text.alignleft", value: "snippets") {
                NavigationStack { SnippetListView() }
            }
            Tab("Settings", systemImage: "gearshape", value: "settings") {
                NavigationStack { SettingsView() }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: !sessions.sessions.isEmpty) {
            SessionsAccessory()
                .matchedTransitionSource(id: "sessions", in: namespace)
        }
        .fullScreenCover(isPresented: presentedBinding) {
            // falls back to the current session so the screen doesn't go blank
            // during the dismiss animation.
            if let session = sessions.presentedSession ?? sessions.currentSession {
                TerminalScreen(initial: session.id)
                    .navigationTransition(.zoom(sourceID: zoomSource, in: namespace))
                    // edge drags and pinches belong to the terminal (selection, zoom);
                    // leaving is the back button.
                    .interactiveDismissDisabled()
            }
        }
        .prompts(active: sessions.presented == nil)
        .overlay(alignment: .top) { NoticeBanner(active: sessions.presented == nil) }
    }

    /// a new session zooms out of its host's row; returning to one zooms
    /// out of the bottom bar.
    private var zoomSource: String {
        guard let session = sessions.presentedSession, session.state == .connecting, sessions.sessions.count == 1 else {
            return "sessions"
        }
        return "host-\(session.host.id)"
    }

    /// stays up while sessions are switched or closed; only goes away when
    /// nothing is presented.
    private var presentedBinding: Binding<Bool> {
        Binding(get: { sessions.presented != nil }, set: { if !$0 { sessions.presented = nil } })
    }
}

private struct SessionsAccessory: View {
    @Environment(SessionManager.self) private var sessions

    var body: some View {
        let session = sessions.currentSession
        Button {
            if let session { sessions.present(session) }
        } label: {
            HStack(spacing: 10) {
                StatusDot(kind: session?.state.dot ?? .idle)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session?.displayTitle ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if sessions.sessions.count > 1 {
                        Text("\(sessions.sessions.count) sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(sessions.sessions.count)))
                    }
                }
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: sessions.sessions.count)
        .accessibilityLabel("Open sessions, \(session?.displayTitle ?? "")")
    }
}
