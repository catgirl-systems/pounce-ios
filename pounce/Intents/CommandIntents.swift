import AppIntents
import Foundation
import PounceCore
import SwiftUI

struct RunCommandIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Run SSH Command"
    static let description = IntentDescription(
        "Runs a command on a host and returns its output: standard output, or standard error when there's none.",
        categoryName: "Commands")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "Command", inputOptions: String.IntentInputOptions(capitalizationType: .none, autocorrect: false))
    var command: String
    @Parameter(title: "Timeout (Seconds)", default: 60, inclusiveRange: (1, 3600)) var timeout: Int
    @Parameter(
        title: "Fail on Error", description: "Stops the shortcut when the command exits with a non-zero status.",
        default: false)
    var failOnError: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) on \(\.$host)") {
            \.$timeout
            \.$failOnError
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        guard let saved = AppModel.shared.host(host.id) else { throw IntentError.missing }
        try await unlockSecrets(for: [saved])
        let result = await CommandRunner.run(command, on: saved, timeout: timeout)
        if let failure = result.failure { throw IntentError.failed(failure) }
        if failOnError, let status = result.exitStatus, status != 0 {
            throw IntentError.failed("The command exited with status \(status).\n\(result.text)")
        }
        let status = result.exitStatus.map { $0 == 0 ? "Done" : "Exited with status \($0)" } ?? "Done"
        return .result(value: result.text, dialog: "\(status)", view: CommandOutputView(results: [result]))
    }
}

/// pounce has no sftp; piping into `cat > file` or `tar x` covers a lot of it
struct RunCommandWithInputIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Run SSH Command with Input"
    static let description = IntentDescription(
        "Runs a command with text or a file as its standard input, like `cat > notes.txt` or `tar xz`. Returns the output, error output and exit status.",
        categoryName: "Commands")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static let maxInput = 64 << 20

    @Parameter(title: "Input", supportedContentTypes: [.data]) var input: IntentFile
    @Parameter(title: "Host") var host: HostEntity
    @Parameter(
        title: "Command", inputOptions: String.IntentInputOptions(capitalizationType: .none, autocorrect: false))
    var command: String
    @Parameter(title: "Timeout (Seconds)", default: 300, inclusiveRange: (1, 3600)) var timeout: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$input) to \(\.$command) on \(\.$host)") { \.$timeout }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CommandResultEntity> & ShowsSnippetView {
        guard let saved = AppModel.shared.host(host.id) else { throw IntentError.missing }
        // checked on disk first, so a huge file isn't read just to be refused
        var size = (try? input.fileURL?.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let data = size > Self.maxInput ? Data() : input.data
        size = max(size, data.count)
        guard size <= Self.maxInput else {
            throw IntentError.failed(
                "The input is \(size.formatted(.byteCount(style: .file))); the most pounce sends is 64 MB.")
        }
        try await unlockSecrets(for: [saved])
        let result = await CommandRunner.run(command, on: saved, input: data, timeout: timeout)
        if let failure = result.failure { throw IntentError.failed(failure) }
        return .result(value: result, view: CommandOutputView(results: [result]))
    }
}

struct RunCommandOnHostsIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Run SSH Command on Hosts"
    static let description = IntentDescription(
        "Runs a command on several hosts, four at a time. Each result has the output, error output, exit status and duration. A host that can't be reached doesn't stop the others.",
        categoryName: "Commands")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Hosts") var hosts: [HostEntity]
    @Parameter(title: "Command", inputOptions: String.IntentInputOptions(capitalizationType: .none, autocorrect: false))
    var command: String
    @Parameter(title: "Timeout (Seconds)", default: 60, inclusiveRange: (1, 3600)) var timeout: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) on \(\.$hosts)") { \.$timeout }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[CommandResultEntity]> & ShowsSnippetView {
        let saved = hosts.compactMap { AppModel.shared.host($0.id) }
        guard !saved.isEmpty else { throw IntentError.missing }
        try await unlockSecrets(for: saved)
        let results = await CommandRunner.run(command, on: saved, timeout: timeout)
        return .result(value: results, view: CommandOutputView(results: results))
    }
}

struct RunSnippetOnHostIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Run Snippet on Host"
    static let description = IntentDescription(
        "Runs a saved snippet as a command. Values fill its {{placeholders}} in the order they first appear.",
        categoryName: "Commands")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Snippet") var snippet: SnippetEntity
    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "Values", default: []) var values: [String]
    @Parameter(title: "Timeout (Seconds)", default: 60, inclusiveRange: (1, 3600)) var timeout: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$snippet) on \(\.$host)") {
            \.$values
            \.$timeout
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<CommandResultEntity> & ShowsSnippetView {
        guard let saved = AppModel.shared.host(host.id), let snippet = AppModel.shared.snippet(snippet.id) else {
            throw IntentError.missing
        }
        let fills = try snippet.placeholderValues(values)
        try await unlockSecrets(for: [saved])
        let result = await CommandRunner.run(snippet.filled(fills), on: saved, timeout: timeout)
        if let failure = result.failure { throw IntentError.failed(failure) }
        return .result(value: result, view: CommandOutputView(results: [result]))
    }
}

struct TestConnectionIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let title: LocalizedStringResource = "Test SSH Connection"
    static let description = IntentDescription(
        "Connects and signs in to a host without running anything. Returns whether it worked.",
        categoryName: "Commands")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Host") var host: HostEntity

    static var parameterSummary: some ParameterSummary { Summary("Test the connection to \(\.$host)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        guard let saved = AppModel.shared.host(host.id) else { throw IntentError.missing }
        try await unlockSecrets(for: [saved])
        let start = ContinuousClock.now
        do {
            let connection = try await AppModel.shared.connect(saved, interactive: false)
            connection.close()
            let elapsed = (ContinuousClock.now - start).formatted(
                .units(allowed: [.seconds, .milliseconds], width: .narrow))
            return .result(value: true, dialog: "Signed in to \(saved.displayName) in \(elapsed).")
        } catch SSHError.hostKeyRejected {
            return .result(value: false, dialog: "\(saved.untrustedKeyHint)")
        } catch {
            return .result(value: false, dialog: "\(error.localizedDescription)")
        }
    }
}

struct CommandOutputView: View {
    let results: [CommandResultEntity]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                VStack(alignment: .leading, spacing: 4) {
                    if results.count > 1 {
                        Label(
                            result.host, systemImage: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(result.succeeded ? Color.secondary : Color.red)
                    }
                    let text = result.failure ?? result.text
                    let lines = results.count > 1 ? 6 : 20
                    if !text.isEmpty {
                        Text(
                            text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(
                                separator: "\n")
                        )
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(lines)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}
