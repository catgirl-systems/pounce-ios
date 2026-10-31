import PounceCore
import SwiftUI

extension View {
    /// only one place in the hierarchy should be active at a time.
    func prompts(active: Bool) -> some View { modifier(PromptPresenter(active: active)) }
}

private struct PromptPresenter: ViewModifier {
    let active: Bool
    @Environment(PromptCenter.self) private var prompts

    func body(content: Content) -> some View {
        content
            .sheet(item: hostKeyPrompt) { prompt in
                HostKeySheet(prompt: prompt)
            }
            .alert(passwordTitle, isPresented: passwordPresented) {
                PasswordAlert()
            } message: {
                Text("The server asked for a password.")
            }
    }

    private var hostKeyPrompt: Binding<PromptCenter.Prompt?> {
        Binding(
            get: {
                guard active, let current = prompts.current, case .hostKey = current.kind else { return nil }
                return current
            },
            set: { new in
                // swiping the sheet away counts as "don't trust".
                if new == nil, let current = prompts.current, case .hostKey = current.kind { prompts.answer(.reject) }
            })
    }

    private var passwordPresented: Binding<Bool> {
        Binding(
            get: {
                guard active, let current = prompts.current, case .password = current.kind else { return false }
                return true
            },
            set: { _ in })
    }

    private var passwordTitle: String {
        if case .password(let endpoint, _) = prompts.current?.kind { return "Password for \(endpoint)" }
        return "Password"
    }
}

struct HostKeySheet: View {
    let prompt: PromptCenter.Prompt
    @Environment(PromptCenter.self) private var prompts
    @State private var confirmReplace = false
    /// measured so a new host's sheet opens just tall enough.
    @State private var contentHeight: CGFloat = 520

    var body: some View {
        if case .hostKey(let endpoint, let key, let previous) = prompt.kind {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 22) {
                        header(endpoint: endpoint, changed: previous != nil)
                        VStack(spacing: 14) {
                            RandomartView(lines: key.randomart)
                            FingerprintText(fingerprint: key.fingerprint)
                                .multilineTextAlignment(.center)
                            Text("\(key.kind.label) · \(key.bits) bits")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 18))
                        if let previous, let old = try? SSHPublicKey(blob: previous.key) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    "Key on file since \(previous.added.formatted(date: .abbreviated, time: .omitted))"
                                )
                                .font(.caption.weight(.semibold))
                                FingerprintText(fingerprint: old.fingerprint)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        buttons(changed: previous != nil)
                    }
                    .padding()
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        contentHeight = $0
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { prompts.answer(.reject) }
                    }
                }
            }
            .interactiveDismissDisabled(previous != nil)
            // 64 pt of room for the navigation bar above the content.
            .presentationDetents(previous == nil ? [.height(contentHeight + 64), .large] : [.large])
        }
    }

    private func header(endpoint: SSHEndpoint, changed: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: changed ? "exclamationmark.shield.fill" : "questionmark.key.filled")
                .font(.system(size: 40))
                .foregroundStyle(changed ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                .symbolEffect(.bounce, options: .nonRepeating)
            Text(changed ? "Host Key Changed" : "New Host")
                .font(.title2.bold())
            Text(
                changed
                    ? "\(endpoint.host) presented a different key than last time. This can happen after a reinstall, but it's also what an attack looks like. Only continue if you know why it changed."
                    : "pounce hasn't connected to \(endpoint.host) before. Check that this fingerprint matches the server's before trusting it."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
    }

    private func buttons(changed: Bool) -> some View {
        VStack(spacing: 10) {
            if changed {
                Button {
                    prompts.answer(.reject)
                } label: {
                    Text("Don't Connect").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Button("Replace Key and Connect", role: .destructive) { confirmReplace = true }
                    .confirmationDialog(
                        "Replace the saved key?", isPresented: $confirmReplace, titleVisibility: .visible
                    ) {
                        Button("Replace Key", role: .destructive) { prompts.answer(.accept) }
                    }
            } else {
                Button {
                    prompts.answer(.accept)
                } label: {
                    Text("Trust and Connect").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(.top, 4)
        .sensoryFeedback(changed ? .warning : .selection, trigger: prompt.id)
    }
}

struct PasswordAlert: View {
    @Environment(PromptCenter.self) private var prompts
    @State private var password = ""
    @AppStorage("savePasswords") private var save = true

    var body: some View {
        SecureField("Password", text: $password)
            .textContentType(.password)
        if case .password(_, let canSave) = prompts.current?.kind, canSave {
            Button(save ? "Sign In and Save" : "Sign In") { prompts.answer(.password(password, save: save)) }
            Button(save ? "Sign In Without Saving" : "Sign In and Save") {
                prompts.answer(.password(password, save: !save))
            }
        } else {
            Button("Sign In") { prompts.answer(.password(password, save: false)) }
        }
        Button("Cancel", role: .cancel) { prompts.answer(.reject) }
    }
}
