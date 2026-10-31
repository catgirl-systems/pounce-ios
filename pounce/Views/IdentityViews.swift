import CoreImage.CIFilterBuiltins
import CryptoKit
import PounceCore
import SwiftUI
import UniformTypeIdentifiers

struct IdentityListView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var generating = false

    var body: some View {
        List {
            ForEach(app.identities) { identity in
                NavigationLink(value: identity.id) {
                    IdentityRow(identity: identity)
                }
            }
            .onDelete { offsets in
                for index in offsets { app.delete(app.identities[index]) }
            }
        }
        .navigationDestination(for: UUID.self) { id in
            if let identity = app.identity(id) { IdentityDetail(identity: identity) }
        }
        .overlay {
            if app.identities.isEmpty {
                ContentUnavailableView {
                    Label("No Keys", systemImage: "key.horizontal")
                } description: {
                    Text(
                        "Generate a key on this iPhone, or import one by pasting it, from a file, or by scanning a QR code."
                    )
                } actions: {
                    Button("Generate Key") { generating = true }
                        .buttonStyle(.glassProminent)
                    Button("Import Key") { importing = true }
                }
            }
        }
        .animation(.snappy, value: app.identities)
        .navigationTitle("Keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Generate Key", systemImage: "sparkles") { generating = true }
                    Button("Import Key", systemImage: "square.and.arrow.down") { importing = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $generating) { GenerateKeyView() }
        .sheet(isPresented: $importing) { ImportKeyView() }
    }
}

private struct IdentityRow: View {
    let identity: Identity

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: identity.symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.name).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(identity.kind.label)
                    if identity.requiresBiometry {
                        Image(systemName: Biometry.current.symbol)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct IdentityDetail: View {
    let identity: Identity
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var icon: String?
    @State private var showQR = false
    @State private var confirmDelete = false
    @State private var copied = 0

    init(identity: Identity) {
        self.identity = identity
        _name = State(initialValue: identity.name)
        _icon = State(initialValue: identity.icon)
    }

    /// creates `authorized_keys` with the right permissions if it's missing.
    private var installCommand: String {
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '\(identity.publicKey)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }

    var body: some View {
        let publicKey = try? SSHPublicKey(authorizedKeysLine: identity.publicKey)
        Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit { app.rename(identity, to: name) }
                IconPickerRow(icon: $icon, defaultSymbol: identity.kind.symbol, symbols: IconChoices.key)
                    .onChange(of: icon) { app.setIcon(identity, to: icon) }
                LabeledContent("Type", value: identity.kind.label)
                if let publicKey { LabeledContent("Size", value: "\(publicKey.bits) bits") }
                LabeledContent("Added", value: identity.created.formatted(date: .abbreviated, time: .omitted))
                if identity.requiresBiometry {
                    Label("\(Biometry.current.name) required to use", systemImage: Biometry.current.symbol)
                }
            }
            if let publicKey {
                Section("Fingerprint") {
                    VStack(spacing: 12) {
                        RandomartView(lines: publicKey.randomart)
                        FingerprintText(fingerprint: publicKey.fingerprint)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
            }
            Section {
                Text(identity.publicKey)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
                Button("Copy Public Key", systemImage: "doc.on.doc") {
                    copied += 1
                    app.copy(identity.publicKey, notice: "Public key copied")
                }
                Button("Copy Install Command", systemImage: "terminal") {
                    copied += 1
                    app.copy(
                        installCommand, notice: "Install command copied",
                        subtitle: "Paste it into a shell on the server")
                }
                ShareLink(item: identity.publicKey + "\n", preview: SharePreview("\(identity.name).pub")) {
                    Label("Share Public Key", systemImage: "square.and.arrow.up")
                }
                Button("Show QR Code", systemImage: "qrcode") { showQR = true }
            } header: {
                Text("Public Key")
            } footer: {
                Text(
                    "Add the public key to ~/.ssh/authorized_keys on a server to sign in with this key. The private key never leaves this iPhone."
                )
            }
            Section {
                Button("Delete Key", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(identity.name)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: copied)
        .sheet(isPresented: $showQR) {
            QRCodeSheet(title: identity.name, text: identity.publicKey)
        }
        .confirmationDialog("Delete “\(identity.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Key", role: .destructive) {
                app.delete(identity)
                dismiss()
            }
        } message: {
            Text(
                identity.kind == .secureEnclaveP256
                    ? "This key lives only in this iPhone's Secure Enclave. Once deleted, it's gone for good."
                    : "Hosts using it will need another key or a password.")
        }
        .onDisappear { if name != identity.name, !name.isEmpty { app.rename(identity, to: name) } }
    }
}

struct QRCodeSheet: View {
    let title: String
    let text: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let image = Self.render(text) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .background(.white, in: .rect(cornerRadius: 20))
                        .frame(maxWidth: 320)
                        .accessibilityLabel("QR code of the public key")
                }
                Text("Scan to get the public key").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .dismissToolbar()
        }
        .presentationDetents([.medium, .large])
    }

    private static let context = CIContext()

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
            let cg = context.createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - generate

struct GenerateKeyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = "\(UIDevice.current.name)"
    @State private var secureEnclave = SecureEnclaveSupport.isAvailable
    @State private var requireBiometry = false
    @State private var created: Identity?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                Section {
                    Picker("Type", selection: $secureEnclave) {
                        if SecureEnclaveSupport.isAvailable {
                            Text("Secure Enclave").tag(true)
                        }
                        Text("Ed25519").tag(false)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text(
                        secureEnclave
                            ? "An ECDSA P-256 key made inside this iPhone's Secure Enclave. It can never be copied off the device, not even by pounce. Works with any OpenSSH server from the last decade."
                            : "A modern Ed25519 key, kept in the Keychain on this iPhone only.")
                }
                Section {
                    Toggle("Require \(Biometry.current.name)", isOn: $requireBiometry)
                } footer: {
                    Text("Asks for \(Biometry.current.name) each time the key signs in.")
                }
            }
            .animation(.snappy, value: secureEnclave)
            .editorToolbar("Generate Key", confirm: "Generate", action: generate)
            .navigationDestination(item: $created) { identity in
                KeyCreatedView(identity: identity) { dismiss() }
            }
        }
    }

    private func generate() {
        do {
            let material =
                secureEnclave
                ? try PrivateKeyMaterial.generateSecureEnclaveP256(comment: name, requireBiometry: requireBiometry)
                : PrivateKeyMaterial.generateEd25519(comment: name)
            created = try app.addIdentity(material, name: name, requireBiometry: requireBiometry)
        } catch {
            app.fail(error.localizedDescription)
        }
    }
}

enum SecureEnclaveSupport {
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
            false
        #else
            SecureEnclave.isAvailable
        #endif
    }
}

struct KeyCreatedView: View {
    let identity: Identity
    let done: () -> Void
    @State private var sealed = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            if let key = try? SSHPublicKey(authorizedKeysLine: identity.publicKey) {
                RandomartView(lines: key.randomart)
            }
            ZStack {
                if sealed {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .transition(.symbolEffect(.drawOn))
                }
            }
            .frame(height: 50)
            VStack(spacing: 6) {
                Text(identity.name).font(.title2.bold())
                Text(identity.kind.label).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 10) {
                Button("Copy Public Key", systemImage: "doc.on.doc") {
                    AppModel.shared.copy(identity.publicKey, notice: "Public key copied")
                }
                .buttonStyle(.glass)
                Button("Done", action: done).buttonStyle(.glassProminent)
            }
            .buttonSizing(.flexible)
            .controlSize(.large)
        }
        .padding()
        .navigationBarBackButtonHidden()
        .sensoryFeedback(.success, trigger: sealed)
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeOut(duration: 0.4)) { sealed = true }
        }
    }
}

// MARK: - import

struct ImportKeyView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var name = ""
    @State private var passphrase = ""
    @State private var requireBiometry = false
    @State private var error: String?
    @State private var scanning = false
    @State private var pickingFile = false
    @State private var created: Identity?
    @State private var saving = false

    var body: some View {
        let needsPassphrase = KeyImport.needsPassphrase(text)
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Button("Paste", systemImage: "doc.on.clipboard") { load(UIPasteboard.general.string ?? "") }
                        Spacer()
                        Button("Scan", systemImage: "qrcode.viewfinder") { scanning = true }
                        Spacer()
                        Button("File", systemImage: "folder") { pickingFile = true }
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(VerticalLabelStyle())
                    .padding(.vertical, 4)
                }
                Section {
                    CodeEditor(
                        text: $text, placeholder: "-----BEGIN OPENSSH PRIVATE KEY-----",
                        font: .system(.caption, design: .monospaced), minHeight: 140)
                } header: {
                    Text("Private Key")
                } footer: {
                    Text("OpenSSH, PEM and PKCS#8 keys: Ed25519, ECDSA and RSA.")
                }
                if needsPassphrase {
                    Section("Passphrase") {
                        SecureField("Passphrase", text: $passphrase)
                            .textContentType(.password)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Section {
                    TextField("Name", text: $name, prompt: Text("From the key's comment"))
                    Toggle("Require \(Biometry.current.name)", isOn: $requireBiometry)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.snappy, value: needsPassphrase)
            .animation(.snappy, value: error)
            .editorToolbar(
                "Import Key", confirm: "Import",
                disabled: saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) { Task { await save() } }
            .sheet(isPresented: $scanning) {
                KeyScannerView { scanned in
                    scanning = false
                    load(scanned)
                }
            }
            .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.data, .text, .item]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), data.count < 64 * 1024,
                    let string = String(data: data, encoding: .utf8)
                {
                    load(string)
                    if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                } else {
                    error = "That file doesn't look like a key."
                }
            }
            .navigationDestination(item: $created) { identity in
                KeyCreatedView(identity: identity) { dismiss() }
            }
            .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
        }
    }

    private func load(_ string: String) {
        text = string
        error = nil
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let (text, passphrase) = (text, passphrase.isEmpty ? nil : passphrase)
        do {
            // an encrypted key's bcrypt rounds take a while.
            let material = try await Task.detached { try KeyImport.parse(text, passphrase: passphrase) }.value
            created = try app.addIdentity(material, name: name, requireBiometry: requireBiometry)
            // don't leave the private key lying around in memory or on the
            // pasteboard longer than needed.
            self.text = ""
            self.passphrase = ""
            if UIPasteboard.general.string?.contains("PRIVATE KEY") == true { UIPasteboard.general.string = "" }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct VerticalLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.title2)
            configuration.title.font(.caption)
        }
        .frame(minWidth: 64)
    }
}
