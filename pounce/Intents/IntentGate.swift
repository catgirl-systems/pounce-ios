import AppIntents
import Foundation
import PounceCore
import UIKit
import os

let intentLog = Logger(category: "intents")

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case missing
    case shortcutsOff
    case locked
    case syncOff
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .missing: "That item no longer exists in pounce."
        case .shortcutsOff:
            "Shortcuts can't use pounce's keys and passwords. Turn on Allow Shortcuts in pounce's settings."
        case .locked: "pounce stayed locked."
        case .syncOff: "Sync isn't set up in pounce."
        case .failed(let message): "\(message)"
        }
    }
}

extension UserDefaults {
    static var allowsShortcuts: Bool { standard.bool(forKey: "allowShortcuts", default: true) }
}

extension AppIntent {
    /// with the app lock on or a key that needs Face ID, pounce comes to the foreground
    /// first, since biometry can't prompt from the background
    @MainActor func unlockSecrets(for hosts: [Host] = []) async throws {
        guard UserDefaults.allowsShortcuts else { throw IntentError.shortcutsOff }
        let app = AppModel.shared
        let lock = app.lock
        let needsBiometry = hosts.contains { host in
            ((try? app.jumpChain(for: host)) ?? [host]).contains {
                app.identity($0.identityID)?.requiresBiometry == true
            }
        }
        guard lock.needsUnlock || needsBiometry else { return }
        if UIApplication.shared.applicationState != .active {
            try await continueInForeground(
                lock.needsUnlock ? "pounce is locked." : "A key for this host needs Face ID.", alwaysConfirm: false)
        }
        guard await lock.unlock() else { throw IntentError.locked }
    }

    /// tunnels outlive the shortcut only while pounce is allowed to stay running,
    /// so without that it opens the app
    @MainActor func stayAliveForConnections() async throws {
        guard !BackgroundKeeper.isEnabled, UIApplication.shared.applicationState != .active
        else { return }
        try await continueInForeground("Tunnels run while pounce is open.", alwaysConfirm: false)
    }
}

enum CommandRunner {
    /// failures land in the result instead of throwing, so one bad host doesn't
    /// stop a run across many
    @MainActor static func run(
        _ command: String, on host: Host, input: Data = Data(), timeout: Int
    ) async -> CommandResultEntity {
        // `@Property` setters don't mutate the struct itself
        let result = CommandResultEntity()
        result.host = host.displayName
        let start = ContinuousClock.now
        defer {
            let elapsed = (ContinuousClock.now - start).components
            result.duration = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
        do {
            // not interactive: an unknown host key fails instead of asking
            let connection = try await AppModel.shared.connect(host, interactive: false)
            defer { connection.close() }
            let output = try await connection.run(command, input: input, timeout: .seconds(max(timeout, 1)))
            result.output = String(decoding: output.stdout, as: UTF8.self)
            result.errorOutput = String(decoding: output.stderr, as: UTF8.self)
            result.exitStatus = output.exitStatus
            result.succeeded = output.exitStatus == 0
        } catch SSHError.hostKeyRejected {
            result.failure = host.untrustedKeyHint
        } catch SSHError.timedOut {
            result.failure = "Timed out after \(timeout) seconds."
        } catch {
            result.failure = error.localizedDescription
        }
        intentLog.info(
            "ran a command on \(host.address, privacy: .private): \(result.failure == nil ? "finished" : "failed", privacy: .public)"
        )
        return result
    }

    /// four hosts at a time, results keep the order of `hosts`
    @MainActor static func run(
        _ command: String, on hosts: [Host], input: Data = Data(), timeout: Int
    ) async -> [CommandResultEntity] {
        var results = [CommandResultEntity?](repeating: nil, count: hosts.count)
        await withTaskGroup(of: (Int, CommandResultEntity).self) { group in
            for (index, host) in hosts.enumerated() {
                if index >= 4, let finished = await group.next() { results[finished.0] = finished.1 }
                group.addTask {
                    let result = await run(command, on: host, input: input, timeout: timeout)
                    return (index, result)
                }
            }
            for await finished in group { results[finished.0] = finished.1 }
        }
        return results.compactMap(\.self)
    }
}

extension CommandResultEntity {
    var text: String {
        let text = output.isEmpty ? errorOutput : output
        return text.trimmingCharacters(in: .newlines)
    }
}

extension Snippet {
    func placeholderValues(_ values: [String]) throws -> [String: String] {
        let names = placeholders
        guard values.count >= names.count else {
            throw IntentError.failed("“\(name)” needs values for \(names.formatted()).")
        }
        return Dictionary(uniqueKeysWithValues: zip(names, values))
    }
}

extension String {
    func equalsIgnoringCase(_ other: String) -> Bool { localizedCaseInsensitiveCompare(other) == .orderedSame }
}
