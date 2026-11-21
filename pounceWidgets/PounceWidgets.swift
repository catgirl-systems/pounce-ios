import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PounceWidgets: WidgetBundle {
    var body: some Widget {
        SessionsLiveActivity()
    }
}

/// only the glue to activitykit; the views are in `ActivityViews.swift`.
struct SessionsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionsActivity.self) { context in
            let model = context.model
            LockScreenView(model: model)
                .widgetURL(URL(string: "pounce://sessions"))
                // the same colour as the bottom of the picture, for the edges.
                .activityBackgroundTint(GardenScene.ground(at: model.state.clock))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let model = context.model
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandHeader(model: model).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PhaseStatus(model: model)
                        .font(.subheadline.weight(.medium))
                        .fontDesign(.rounded)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 96, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandBottom(model: model).padding(.horizontal, 4)
                }
            } compactLeading: {
                PhaseGlyph(model: model).frame(width: 20, height: 17)
            } compactTrailing: {
                if model.phase == .background, let deadline = model.state.deadline, deadline > .now {
                    Text(timerInterval: Date.now...deadline, countsDown: true)
                        .monospacedDigit()
                        .foregroundStyle(PhaseStatus.amber)
                        .frame(maxWidth: 38)
                } else {
                    Text("\(model.state.shells.count + model.state.tunnels)")
                        .monospacedDigit()
                        .fontDesign(.rounded)
                        .accessibilityLabel(model.state.summary)
                }
            } minimal: {
                PhaseGlyph(model: model).frame(width: 18, height: 15)
            }
            .keylineTint(model.accent)
            .widgetURL(URL(string: "pounce://sessions"))
        }
    }
}

extension ActivityViewContext<SessionsActivity> {
    /// past the background deadline the app may have been suspended before it
    /// could say so: show it as paused.
    fileprivate var model: ActivityModel {
        ActivityModel(
            state: state, phase: isStale && state.phase == .background ? .paused : state.phase,
            started: attributes.started, accent: attributes.accent)
    }
}

extension SessionsActivity {
    fileprivate var accent: Color {
        guard accentHex.count == 6, let value = UInt32(accentHex, radix: 16) else { return .orange }
        return RGB(value).color
    }
}
