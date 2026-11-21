import ActivityKit
import Foundation
import Observation
import UIKit

/// starts with the first open session or tunnel and ends with the last
@MainActor final class LiveActivityController {
    /// only the id is kept: `Activity` isn't `Sendable`, so it's looked up again
    /// off the main actor to update or end it
    private var activityID: String?
    private var phase = SessionsActivity.ContentState.Phase.live
    private var deadline: Date?
    private var last: SessionsActivity.ContentState?
    private var watching: Task<Void, Never>?
    private var ticking: Task<Void, Never>?
    private var pushing: Task<Void, Never>?

    init() {
        // a previous run that was killed can leave its activity behind
        for stale in Activity<SessionsActivity>.activities.map(\.id) {
            Task { await Self.end(stale, content: nil) }
        }
    }

    func watch() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            let changes = Observations { @MainActor in
                let app = AppModel.shared
                return Snapshot(
                    shells: app.sessions.sessions.map {
                        .init(name: $0.host.displayName, connected: $0.state == .connected)
                    },
                    tunnels: app.tunnels.runningCount)
            }
            for await snapshot in changes {
                guard let self else { return }
                self.snapshot = snapshot
                await self.push()
            }
        }
        // moves the garden's sun along; the sleep just waits while ios has the app suspended
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                let next = Self.clock(.now).addingTimeInterval(Self.tick)
                try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 1))
                guard let self else { return }
                await self.push()
            }
        }
    }

    private static let tick: TimeInterval = 5 * 60

    private static func clock(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / tick).rounded(.down) * tick)
    }

    /// `remaining` is the background task's grace period
    func enteredBackground(remaining: TimeInterval) {
        phase = .background
        deadline = remaining.isFinite ? .now.addingTimeInterval(remaining) : nil
        Task { await push() }
    }

    /// ios is about to suspend the app; connections are going away
    func pausing() async {
        phase = .paused
        deadline = nil
        await push()
    }

    func becameActive() {
        phase = .live
        deadline = nil
        Task { await push() }
    }

    private struct Snapshot: Equatable, Sendable {
        var shells: [SessionsActivity.ContentState.Shell]
        var tunnels: Int
    }

    private var snapshot = Snapshot(shells: [], tunnels: 0)

    /// for the activity's own disconnect button: ios may suspend the app again
    /// as soon as the intent returns, so the activity has to be gone by then
    func endNow() async {
        snapshot = Snapshot(shells: [], tunnels: 0)
        await push()
    }

    /// one at a time and in order: updates suspend, and two at once could
    /// land out of order or both start an activity
    private func push() async {
        let previous = pushing
        let task = Task {
            await previous?.value
            await pushNow()
        }
        pushing = task
        await task.value
    }

    private func pushNow() async {
        let state = SessionsActivity.ContentState(
            shells: snapshot.shells, tunnels: snapshot.tunnels, phase: phase, deadline: deadline,
            clock: Self.clock(.now))
        let empty = state.shells.isEmpty && state.tunnels == 0

        if empty {
            last = nil
            if let activityID {
                self.activityID = nil
                await Self.end(activityID, content: .init(state: state, staleDate: nil))
            }
            return
        }
        // `last` is only what an activity actually shows, so a state that couldn't
        // be shown (no activity from the background) is tried again
        guard state != last else { return }
        // past the deadline the widget shows the activity as paused, in case ios
        // suspends the app before it gets to say so
        let content = ActivityContent(state: state, staleDate: phase == .background ? deadline : nil)

        if let activityID {
            if await Self.update(activityID, content: content) {
                last = state
                return
            }
            // dismissed or ended by ios; make sure it's gone before replacing it
            self.activityID = nil
            await Self.end(activityID, content: nil)
        }
        // activities can only start from the foreground
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
            UIApplication.shared.applicationState == .active
        else { return }
        do {
            let attributes = SessionsActivity(
                started: .now, accentHex: UserDefaults.standard.string(forKey: "accentHex") ?? Accent.defaultHex)
            activityID = try Activity.request(attributes: attributes, content: content).id
            last = state
        } catch {
            log.error("live activity failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func update(
        _ id: String, content: ActivityContent<SessionsActivity.ContentState>
    ) async -> Bool {
        // stale is past its deadline but still on screen and updatable
        guard let activity = activity(id), [.active, .stale].contains(activity.activityState) else { return false }
        await activity.update(content)
        return true
    }

    private nonisolated static func end(
        _ id: String, content: ActivityContent<SessionsActivity.ContentState>?
    ) async {
        await activity(id)?.end(content, dismissalPolicy: .immediate)
    }

    private nonisolated static func activity(_ id: String) -> Activity<SessionsActivity>? {
        Activity<SessionsActivity>.activities.first { $0.id == id }
    }
}
