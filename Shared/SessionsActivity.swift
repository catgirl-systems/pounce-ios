import ActivityKit
import AppIntents
import Foundation

/// compiled into both the app, which starts and updates it, and the widget
/// extension, which draws it.
struct SessionsActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            /// app in the foreground, everything connected.
            case live
            /// app in the background: connections hold until `deadline`.
            case background
            /// ios suspended the app; connections come back when it's opened.
            case paused
        }

        struct Shell: Codable, Hashable {
            var name: String
            var connected: Bool
        }

        var shells: [Shell]
        var tunnels: Int
        var phase: Phase
        var deadline: Date?
        /// the time the garden scene shows, moved on every five minutes while the
        /// app runs.
        var clock: Date
    }

    /// when the first connection opened.
    var started: Date
    /// the accent colour, as `RRGGBB`.
    var accentHex: String
}

/// runs in the app, which ios wakes for it.
struct DisconnectAllIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Disconnect All"
    static let description = IntentDescription("Closes every session and stops every tunnel.")

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
            await MainActor.run { AppModel.shared.disconnectAll() }
        #endif
        return .result()
    }
}
