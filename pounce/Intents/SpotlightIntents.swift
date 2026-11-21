import AppIntents
import CoreSpotlight
import Foundation
import PounceCore

// MARK: - spotlight

extension HostEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = defaultAttributeSet
        set.title = name
        set.contentDescription = address
        set.keywords = tags + [hostname, username]
        return set
    }
}

/// what a host found in spotlight opens.
struct OpenHostIntent: OpenIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Open Host"
    static let description = IntentDescription("Opens a terminal on a host.", categoryName: "Sessions")

    @Parameter(title: "Host") var target: HostEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let host = AppModel.shared.host(target.id) else { throw IntentError.missing }
        AppModel.shared.sessions.open(host)
        return .result()
    }
}

/// hosts stay out of spotlight while the app lock is on, so the lock hides them.
@MainActor final class SpotlightIndex {
    private var pending: Task<Void, Never>?

    func update() {
        pending?.cancel()
        // coalesces bursts of saves, like a sync round or an import.
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            // siri and spotlight only learn new names for shortcut phrases here.
            PounceShortcuts.updateAppShortcutParameters()
            let index = CSSearchableIndex.default()
            do {
                try await index.deleteAppEntities(ofType: HostEntity.self)
                guard !AppLock.isEnabled else { return }
                try await index.indexAppEntities(AppModel.shared.hosts.map(HostEntity.init))
            } catch {
                intentLog.error("couldn't update spotlight: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - focus

struct HostFocus: Equatable {
    var tags: [String] = []
    var keepFavorites = true

    var isActive: Bool { !tags.isEmpty }

    func shows(_ host: Host) -> Bool {
        !isActive || (keepFavorites && host.isFavorite)
            || host.tags.contains { tag in tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame } }
    }
}

struct HostFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Filter Hosts"
    static let description = IntentDescription("Shows only hosts with certain tags while this Focus is on.")

    @Parameter(title: "Tags", optionsProvider: TagOptions()) var tags: [String]?
    @Parameter(title: "Keep Favorites", description: "Favorites stay in the list whatever their tags.", default: true)
    var keepFavorites: Bool

    var displayRepresentation: DisplayRepresentation {
        guard let tags, !tags.isEmpty else { return DisplayRepresentation(title: "All hosts") }
        return DisplayRepresentation(
            title: "\(tags.formatted())", subtitle: keepFavorites ? "and favorites" : nil)
    }

    /// also runs with the defaults when the focus ends, which clears it.
    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.focus = HostFocus(tags: tags ?? [], keepFavorites: keepFavorites)
        return .result()
    }

    struct TagOptions: DynamicOptionsProvider {
        @MainActor func results() async throws -> [String] { AppModel.shared.tags }
    }
}
