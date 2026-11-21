import AppIntents
import SwiftUI

/// views read `phase`, not `state.phase`: it already has the stale check folded in
struct ActivityModel {
    var state: SessionsActivity.ContentState
    var phase: SessionsActivity.ContentState.Phase
    var started: Date
    var accent: Color
}

struct LockScreenView: View {
    let model: ActivityModel

    var body: some View {
        let ground = GardenScene.ground(at: model.state.clock)
        VStack(spacing: 0) {
            GardenScene(date: model.state.clock, asleep: model.phase == .paused, covered: 9)
                .frame(height: 90)
                .overlay(alignment: .bottom) {
                    Hill(wave: 0.45).fill(ground).frame(height: 13)
                }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.state.summary)
                            .font(.headline)
                            .lineLimit(1)
                        PhaseStatus(model: model)
                            .font(.subheadline.weight(.medium))
                            .layoutPriority(1)
                    }
                    if model.phase == .paused {
                        Text("Open pounce to reconnect").font(.caption).opacity(0.7)
                    } else if !model.state.shells.isEmpty {
                        ShellList(shells: model.state.shells, limit: 3)
                    }
                }
                Spacer(minLength: 0)
                DisconnectButton()
            }
            .padding(.horizontal, 16)
            .padding(.top, 3)
            .padding(.bottom, 14)
            .background(ground)
        }
        .fontDesign(.rounded)
        .foregroundStyle(.white)
    }
}

struct IslandHeader: View {
    let model: ActivityModel

    var body: some View {
        HStack(spacing: 7) {
            PhaseGlyph(model: model).frame(width: 20, height: 17)
            Text(model.state.summary)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .fontDesign(.rounded)
    }
}

struct IslandBottom: View {
    let model: ActivityModel

    var body: some View {
        VStack(spacing: 9) {
            GardenScene(date: model.state.clock, asleep: model.phase == .paused)
                .frame(height: 54)
                .clipShape(.rect(cornerRadius: 16))
            HStack(spacing: 10) {
                if !model.state.shells.isEmpty {
                    ShellList(shells: model.state.shells, limit: 2)
                } else if model.phase == .paused {
                    Text("Open pounce to reconnect")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                DisconnectButton()
            }
        }
        .fontDesign(.rounded)
    }
}

struct PhaseGlyph: View {
    let model: ActivityModel

    var body: some View {
        CatFace(asleep: model.phase == .paused)
            .fill(
                model.phase == .paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(model.accent),
                style: FillStyle(eoFill: true)
            )
            .accessibilityLabel(model.phase == .paused ? "pounce, paused" : "pounce")
    }
}

struct PhaseStatus: View {
    let model: ActivityModel

    var body: some View {
        switch model.phase {
        case .live:
            HStack(spacing: 5) {
                Circle().fill(Self.green).frame(width: 7, height: 7)
                PhaseClock(model: model)
            }
            .opacity(0.85)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Connected")
        case .background:
            Label {
                PhaseClock(model: model)
            } icon: {
                Image(systemName: "hourglass")
            }
            .labelStyle(TightLabelStyle())
            .foregroundStyle(Self.amber)
            .accessibilityLabel("In the background, holds for")
        case .paused:
            Label("Paused", systemImage: "moon.zzz.fill")
                .labelStyle(TightLabelStyle())
                .opacity(0.85)
        }
    }

    static let green = Color(red: 0.48, green: 0.9, blue: 0.58)
    static let amber = Color(red: 1, green: 0.82, blue: 0.48)
}

struct PhaseClock: View {
    let model: ActivityModel

    var body: some View {
        switch model.phase {
        case .live:
            Text(model.started, style: .timer).monospacedDigit()
        case .background:
            if let deadline = model.state.deadline, deadline > .now {
                Text(timerInterval: Date.now...deadline, countsDown: true).monospacedDigit()
            }
        case .paused:
            EmptyView()
        }
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
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
                    // hollow when dropped, so the state doesn't rely on colour alone
                    Circle()
                        .strokeBorder(shell.connected ? PhaseStatus.green : PhaseStatus.amber, lineWidth: 1.5)
                        .background(Circle().fill(shell.connected ? PhaseStatus.green : .clear))
                        .frame(width: 7, height: 7)
                    Text(shell.name)
                        .lineLimit(1)
                        .privacySensitive()
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.14), in: .capsule)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(shell.name), \(shell.connected ? "connected" : "not connected")")
            }
            if shells.count > limit {
                Text("+\(shells.count - limit)")
                    .font(.caption.weight(.medium))
                    .opacity(0.7)
            }
        }
    }
}

private struct DisconnectButton: View {
    var body: some View {
        Button(intent: DisconnectAllIntent()) {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.bold))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.16), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Disconnect All")
    }
}

extension SessionsActivity.ContentState {
    var summary: String {
        var parts: [String] = []
        if !shells.isEmpty { parts.append(shells.count == 1 ? "1 session" : "\(shells.count) sessions") }
        if tunnels > 0 { parts.append(tunnels == 1 ? "1 tunnel" : "\(tunnels) tunnels") }
        return parts.isEmpty ? "Nothing open" : parts.joined(separator: " · ")
    }
}
