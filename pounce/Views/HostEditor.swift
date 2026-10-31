import PounceCore
import SwiftUI

struct HostEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var host: Host
    @State private var password = ""
    @State private var hasPassword = false
    @State private var removePassword = false
    @State private var newTag = ""
    @State private var newSnippet: Snippet?
    private let isNew: Bool

    init(host: Host) {
        _host = State(initialValue: host)
        isNew = AppModel.shared.host(host.id) == nil
    }

    private var isValid: Bool {
        !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.username.trimmingCharacters(in: .whitespaces).isEmpty && (1...65535).contains(host.port)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $host.label, prompt: Text("Optional"))
                    IconPickerRow(icon: $host.icon, defaultSymbol: host.defaultSymbol, symbols: IconChoices.host)
                    TextField("Host", text: $host.hostname, prompt: Text("example.com"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                    TextField("User", text: $host.username, prompt: Text("root"))
                        .textContentType(.username)
                    PortField(title: "Port", value: $host.port)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Section {
                    Picker("Key", selection: $host.identityID) {
                        Text("Any Key").tag(UUID?.none)
                        ForEach(app.identities) { identity in
                            Label(identity.name, systemImage: identity.symbol).tag(UUID?.some(identity.id))
                        }
                    }
                    if hasPassword, !removePassword {
                        LabeledContent("Password") {
                            Button("Remove", role: .destructive) { withAnimation(.snappy) { removePassword = true } }
                        }
                    } else {
                        SecureField("Password", text: $password, prompt: Text("Asked when needed"))
                            .textContentType(.password)
                    }
                } header: {
                    Text("Sign In")
                } footer: {
                    Text(
                        host.identityID == nil
                            ? "Keys that don't need \(Biometry.current.name) are tried in turn, then the password."
                            : "The key is tried first, then the password.")
                }

                Section {
                    ForEach(host.jumpHostIDs, id: \.self) { id in
                        Text(app.host(id)?.displayName ?? "Missing host")
                    }
                    .onDelete { host.jumpHostIDs.remove(atOffsets: $0) }
                    .onMove { host.jumpHostIDs.move(fromOffsets: $0, toOffset: $1) }
                    let candidates = app.hosts.filter { $0.id != host.id && !host.jumpHostIDs.contains($0.id) }
                    if !candidates.isEmpty {
                        Menu {
                            ForEach(candidates) { candidate in
                                Button(candidate.displayName) {
                                    withAnimation(.snappy) { host.jumpHostIDs.append(candidate.id) }
                                }
                            }
                        } label: {
                            Label("Add Jump Host", systemImage: "plus")
                        }
                    }
                } header: {
                    Text("Jump Hosts")
                } footer: {
                    Text("Like ProxyJump: pounce connects through these, in order, to reach this host.")
                }

                Section("Tags") {
                    if !host.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(host.tags, id: \.self) { tag in
                                    Button {
                                        withAnimation(.snappy) { host.tags.removeAll { $0 == tag } }
                                    } label: {
                                        Label(tag, systemImage: "xmark")
                                            .labelStyle(TrailingIconLabelStyle())
                                            .font(.subheadline)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(.tint.opacity(0.15), in: .capsule)
                                    }
                                    .buttonStyle(.plain)
                                    .transition(.scale.combined(with: .opacity))
                                }
                            }
                        }
                    }
                    TextField("Add Tag", text: $newTag)
                        .textInputAutocapitalization(.never)
                        .onSubmit(addTag)
                        .submitLabel(.done)
                }

                Section {
                    // a menu rather than a picker, so it can also offer to make a new snippet.
                    LabeledContent("Startup Snippet") {
                        Menu {
                            Picker("Startup Snippet", selection: $host.startupSnippetID) {
                                Text("None").tag(UUID?.none)
                                ForEach(app.snippets) { snippet in
                                    Text(snippet.title).tag(UUID?.some(snippet.id))
                                }
                            }
                            Divider()
                            Button("New Snippet…", systemImage: "plus") {
                                newSnippet = Snippet(name: "", command: "")
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(app.snippet(host.startupSnippetID)?.title ?? "None")
                                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                            }
                        }
                    }
                    Picker("Theme", selection: $host.themeID) {
                        Text("Default").tag(String?.none)
                        ForEach(TerminalTheme.all) { theme in Text(theme.name).tag(String?.some(theme.id)) }
                    }
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("The startup snippet runs once the shell opens.")
                }
            }
            .editorToolbar(isNew ? "New Host" : host.displayName, disabled: !isValid, action: save)
            .sheet(item: $newSnippet) { snippet in
                SnippetEditor(snippet: snippet) { host.startupSnippetID = $0.id }
            }
            .task { hasPassword = Keychain.hasPassword(for: host.id) }
        }
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !host.tags.contains(tag) else { return }
        withAnimation(.snappy) { host.tags.append(tag) }
        newTag = ""
    }

    private func save() {
        addTag()
        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        host.username = host.username.trimmingCharacters(in: .whitespaces)
        if removePassword { Keychain.deletePassword(for: host.id) }
        if !password.isEmpty {
            do {
                try Keychain.savePassword(password, for: host.id)
            } catch {
                app.fail(error.localizedDescription)
                return
            }
        }
        app.save(host)
        dismiss()
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.imageScale(.small).foregroundStyle(.secondary)
        }
    }
}
