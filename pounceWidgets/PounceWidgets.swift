import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct PounceWidgets: WidgetBundle {
    var body: some Widget {
        SessionsLiveActivity()
    }
}

struct SessionsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionsActivity.self) { context in
            LockScreenView(context: context)
                .tint(context.attributes.accent)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(context.attributes.accent)
        } dynamicIsland: { context in
            let accent = context.attributes.accent
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(state.summary).font(.subheadline.weight(.semibold))
                    } icon: {
                        PhaseIcon(phase: context.phase, accent: accent)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PhaseClock(context: context)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: 80, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        GardenScene(date: state.clock)
                            .frame(height: 44)
                            .clipShape(.rect(cornerRadius: 14))
                        HStack(alignment: .center, spacing: 10) {
                            ShellList(shells: state.shells, limit: 2)
                            Spacer(minLength: 0)
                            DisconnectButton()
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                PhaseIcon(phase: context.phase, accent: accent)
            } compactTrailing: {
                if context.phase == .background, let deadline = state.deadline, deadline > .now {
                    Text(timerInterval: Date.now...deadline, countsDown: true)
                        .monospacedDigit()
                        .frame(maxWidth: 38)
                } else {
                    Text("\(state.shells.count + state.tunnels)").monospacedDigit()
                }
            } minimal: {
                PhaseIcon(phase: context.phase, accent: accent)
            }
            .keylineTint(accent)
            .widgetURL(URL(string: "pounce://sessions"))
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<SessionsActivity>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 0) {
            GardenScene(date: state.clock)
                .frame(height: 58)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.summary).font(.headline)
                        HStack(spacing: 4) {
                            Text(context.phase.caption)
                            PhaseClock(context: context)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    DisconnectButton()
                }
                if !state.shells.isEmpty {
                    ShellList(shells: state.shells, limit: 3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

/// the dynamic island doesn't take a tint, so the accent is passed in.
private struct PhaseIcon: View {
    let phase: SessionsActivity.ContentState.Phase
    let accent: Color

    var body: some View {
        Image(systemName: phase == .paused ? "pause.circle.fill" : "terminal.fill")
            .foregroundStyle(phase == .paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// time connected while live, time left in the background, nothing once paused.
private struct PhaseClock: View {
    let context: ActivityViewContext<SessionsActivity>

    var body: some View {
        switch context.phase {
        case .live:
            Text(context.attributes.started, style: .timer).monospacedDigit()
        case .background:
            if let deadline = context.state.deadline, deadline > .now {
                Text(timerInterval: Date.now...deadline, countsDown: true).monospacedDigit()
            }
        case .paused:
            EmptyView()
        }
    }
}

private struct ShellList: View {
    let shells: [SessionsActivity.ContentState.Shell]
    let limit: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(shells.prefix(limit).enumerated()), id: \.offset) { _, shell in
                HStack(spacing: 5) {
                    Circle()
                        .fill(shell.connected ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(shell.name)
                        .lineLimit(1)
                        .privacySensitive()
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.fill.tertiary, in: .capsule)
            }
            if shells.count > limit {
                Text("+\(shells.count - limit)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DisconnectButton: View {
    var body: some View {
        Button(intent: DisconnectAllIntent()) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .background(.fill.secondary, in: .circle)
        .accessibilityLabel("Disconnect All")
    }
}

extension ActivityViewContext<SessionsActivity> {
    /// past the background deadline the app may have been suspended before it
    /// could say so: show it as paused.
    fileprivate var phase: SessionsActivity.ContentState.Phase {
        isStale && state.phase == .background ? .paused : state.phase
    }
}

extension SessionsActivity {
    fileprivate var accent: Color {
        guard accentHex.count == 6, let value = UInt32(accentHex, radix: 16) else { return .orange }
        return RGB(value).color
    }
}

extension SessionsActivity.ContentState {
    fileprivate var summary: String {
        var parts: [String] = []
        if !shells.isEmpty { parts.append(shells.count == 1 ? "1 session" : "\(shells.count) sessions") }
        if tunnels > 0 { parts.append(tunnels == 1 ? "1 tunnel" : "\(tunnels) tunnels") }
        return parts.isEmpty ? "Nothing open" : parts.joined(separator: " · ")
    }
}

extension SessionsActivity.ContentState.Phase {
    fileprivate var caption: String {
        switch self {
        case .live: "Connected"
        case .background: "In the background, holds for"
        case .paused: "Paused, open pounce to reconnect"
        }
    }
}
