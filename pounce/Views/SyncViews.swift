import PounceCore
import SwiftUI
import VisionKit

struct SyncView: View {
    @Environment(AppModel.self) private var app
    @State private var sheet: Sheet?
    @State private var removing: RosterDevice?
    @State private var confirmOff = false
    @State private var confirmDelete = false
    @State private var exposure = false

    enum Sheet: String, Identifiable {
        case create, join, recover, add
        var id: String { rawValue }
    }

    var body: some View {
        let sync = app.sync
        Form {
            if sync.isOn {
                status(sync)
                devices(sync)
                Section {
                    Button("Turn Off Sync on This iPhone", systemImage: "icloud.slash") { confirmOff = true }
                    Button("Delete Sync Account", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text(
                        "Turning sync off keeps everything on this iPhone. To also stop it from receiving updates, remove it on another device."
                    )
                }
            } else {
                Section {
                    Button("Create Sync Account", systemImage: "plus.circle") { sheet = .create }
                    Button("Join from Another Device", systemImage: "qrcode.viewfinder") { sheet = .join }
                    Button("Recover with Recovery Code", systemImage: "key.viewfinder") { sheet = .recover }
                } footer: {
                    Text(
                        "Sync keeps hosts, tunnels, snippets, known hosts and your keys' public halves the same on all your devices, through a pounce-sync server you choose. Everything is end-to-end encrypted: the server only stores ciphertext. Private keys and passwords sync only if you turn that on for each one."
                    )
                }
            }
        }
        .navigationTitle("Sync")
        .animation(.snappy, value: sync.isOn)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .create: CreateSyncView()
            case .join: JoinSyncView()
            case .recover: RecoverSyncView()
            case .add: AddDeviceView()
            }
        }
        .sheet(isPresented: $exposure) { ExposureView() }
        .confirmationDialog(
            "Remove “\(removing?.name ?? "")”?", isPresented: removingBinding, titleVisibility: .visible,
            presenting: removing
        ) { device in
            Button("Remove Device", role: .destructive) { remove(device) }
        } message: { _ in
            Text(
                "It stops receiving updates, and pounce changes the encryption key so it can't read anything new. Whatever it already has stays on it."
            )
        }
        .confirmationDialog("Turn off sync?", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("Turn Off", role: .destructive) {
                sync.turnOff()
                app.notify("Sync turned off")
            }
        }
        .confirmationDialog("Delete the sync account?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) {
                Task {
                    do {
                        try await sync.deleteAccount()
                        app.notify("Sync account deleted")
                    } catch {
                        app.fail("Couldn't delete the account", subtitle: error.localizedDescription)
                    }
                }
            }
        } message: {
            Text(
                "Removes everything from the server. Your devices keep their data, but stop syncing. The recovery code stops working."
            )
        }
    }

    private func status(_ sync: SyncController) -> some View {
        Section {
            LabeledContent("Server", value: sync.server)
            LabeledContent("Status") {
                if sync.isSyncing {
                    ProgressView().controlSize(.small)
                } else if let lastSynced = sync.lastSynced {
                    Text("Synced \(lastSynced, format: .relative(presentation: .named))")
                } else {
                    Text("Waiting")
                }
            }
            if let problem = sync.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { sync.syncNow() }
                .disabled(sync.isSyncing)
        }
    }

    private func devices(_ sync: SyncController) -> some View {
        Section {
            ForEach(sync.devices) { device in
                HStack {
                    Label(device.name, systemImage: symbol(for: device.name))
                    Spacer()
                    if device.id == sync.thisDevice {
                        Text("This iPhone").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    if device.id != sync.thisDevice {
                        Button("Remove", systemImage: "minus.circle", role: .destructive) { removing = device }
                    }
                }
            }
            Button("Add Device", systemImage: "plus") { sheet = .add }
                .disabled(sync.devices.count >= 32)
        } header: {
            Text("Devices")
        } footer: {
            Text("Device names are visible to the server. Swipe to remove one.")
        }
    }

    private var removingBinding: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    private func remove(_ device: RosterDevice) {
        Task {
            do {
                try await app.sync.remove(device)
                app.notify("“\(device.name)” removed")
                if !app.exposedIdentities.isEmpty || !app.hostsWithSyncedPasswords.isEmpty { exposure = true }
            } catch {
                app.fail("Couldn't remove the device", subtitle: error.localizedDescription)
            }
        }
    }

    private func symbol(for name: String) -> String {
        switch name.lowercased() {
        case let n where n.contains("ipad"): "ipad"
        case let n where n.contains("mac"): "laptopcomputer"
        default: "iphone"
        }
    }
}

// MARK: - create

private struct CreateSyncView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var invite = ""
    @State private var name = SyncController.defaultDeviceName
    @State private var working = false
    @State private var code: RecoveryCode?

    var body: some View {
        NavigationStack {
            if let code {
                RecoveryCodeView(code: code) { dismiss() }
            } else {
                Form {
                    Section {
                        TextField("Server", text: $server, prompt: Text("sync.example.org"))
                            .keyboardType(.URL)
                            .textContentType(.URL)
                        TextField("Invite Code", text: $invite, prompt: Text("If the server needs one"))
                    } footer: {
                        Text("The address of a pounce-sync server. Ask its owner for an invite code.")
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Section {
                        TextField("Device Name", text: $name)
                    } footer: {
                        Text("Shown in your list of devices, and visible to the server.")
                    }
                }
                .disabled(working)
                .overlay { if working { ProgressView() } }
                .editorToolbar(
                    "Create Account", confirm: "Create", disabled: server.isEmpty || name.isEmpty || working,
                    action: create)
            }
        }
        .interactiveDismissDisabled(working || code != nil)
    }

    private func create() {
        working = true
        Task {
            defer { working = false }
            do {
                let code = try await app.sync.create(server: server, invite: invite, name: name)
                withAnimation(.snappy) { self.code = code }
            } catch {
                app.fail("Couldn't create the account", subtitle: error.localizedDescription)
            }
        }
    }
}

/// shown once: pounce doesn't keep the code.
private struct RecoveryCodeView: View {
    let code: RecoveryCode
    let done: () -> Void
    @Environment(AppModel.self) private var app
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Text(
                    code.text.split(separator: "-").chunked(4).map { $0.joined(separator: " ") }.joined(separator: "\n")
                )
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                Button("Copy Recovery Code", systemImage: "doc.on.doc") {
                    app.copy(code.text, notice: "Recovery code copied", subtitle: "Store it in a password manager")
                }
            } footer: {
                Text(
                    "If you lose all your devices, this code and the server address get your data back. Anyone with it can take over the account, so keep it somewhere safe. pounce won't show it again."
                )
            }
            Section {
                Toggle("I've Saved the Recovery Code", isOn: $saved)
            }
        }
        .navigationTitle("Recovery Code")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark", action: done).disabled(!saved)
            }
        }
        .sensoryFeedback(.selection, trigger: saved)
    }
}

extension Array {
    fileprivate func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

// MARK: - join

private struct JoinSyncView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.scanning
    @State private var task: Task<Void, Never>?

    enum Step: Equatable {
        case scanning
        case joining
        case compare(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .scanning:
                    ZStack(alignment: .bottom) {
                        if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                            Scanner(onPayload: scanned).ignoresSafeArea()
                        } else {
                            ContentUnavailableView(
                                "Camera Unavailable", systemImage: "camera.fill",
                                description: Text("Copy the pairing code on the other device and tap Paste."))
                        }
                        Label(
                            "On your other device, open Settings › Sync › Add Device", systemImage: "qrcode.viewfinder"
                        )
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect()
                        .padding(.bottom, 30)
                    }
                case .joining:
                    ProgressView("Waiting for the other device…")
                case .compare(let code):
                    VStack(spacing: 18) {
                        Text("Check that the other device shows").foregroundStyle(.secondary)
                        Text(code)
                            .font(.system(size: 44, weight: .semibold, design: .monospaced))
                            .contentTransition(.numericText())
                        Text("If it matches, tap Codes Match there. If it doesn't, cancel on both devices.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        ProgressView()
                    }
                    .padding()
                }
            }
            .navigationTitle("Join Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        task?.cancel()
                        dismiss()
                    }
                }
                if step == .scanning {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Paste", systemImage: "doc.on.clipboard") {
                            if let text = UIPasteboard.general.string { scanned(text) }
                        }
                    }
                }
            }
            .animation(.snappy, value: step)
        }
        .interactiveDismissDisabled(step != .scanning)
        .onDisappear { task?.cancel() }
    }

    private func scanned(_ payload: String) {
        guard step == .scanning, payload.hasPrefix("pounce-pair:") else { return }
        let joiner: SyncJoiner
        do {
            joiner = try SyncJoiner(code: payload, deviceName: SyncController.defaultDeviceName)
        } catch {
            return app.fail("Couldn't read the pairing code", subtitle: error.localizedDescription)
        }
        step = .joining
        task = Task {
            do {
                let code = try await joiner.join()
                step = .compare(code)
                try await app.sync.finish(joiner)
                app.notify("Sync turned on", subtitle: "This iPhone joined the account")
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                app.fail("Pairing didn't finish", subtitle: error.localizedDescription)
                dismiss()
            }
        }
    }
}

// MARK: - add a device

private struct AddDeviceView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var invite: PairingInvite?
    @State private var request: PairingRequest?
    @State private var approving = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let request {
                    Image(systemName: "iphone.badge.checkmark")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce, value: request.code)
                    Text("“\(request.deviceName)” wants to join").font(.headline)
                    Text("Check that it shows").foregroundStyle(.secondary)
                    Text(request.code)
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    Button("Codes Match") { approve(request) }
                        .buttonStyle(.glassProminent)
                        .disabled(approving)
                    Text("If they differ, cancel: someone else may be trying to join.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let invite, let image = QRCodeSheet.render(invite.code) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .background(.white, in: .rect(cornerRadius: 20))
                        .frame(maxWidth: 320)
                        .accessibilityLabel("Pairing QR code")
                    Text("On the new device, open Settings › Sync › Join from Another Device and scan this code.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Copy Code Instead", systemImage: "doc.on.doc") {
                        app.copy(invite.code, notice: "Pairing code copied")
                    }
                    .font(.subheadline)
                } else {
                    ProgressView()
                }
            }
            .padding()
            .navigationTitle("Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        task?.cancel()
                        dismiss()
                    }
                }
            }
            .animation(.snappy, value: request?.code)
            .sensoryFeedback(.impact, trigger: request?.code)
        }
        .presentationDetents([.large])
        .task { start() }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        task = Task {
            guard let engine = app.sync.engine else { return }
            do {
                let invite = try await engine.startPairing()
                self.invite = invite
                request = try await engine.waitForJoiner(invite)
            } catch {
                guard !Task.isCancelled else { return }
                app.fail("Couldn't add the device", subtitle: error.localizedDescription)
                dismiss()
            }
        }
    }

    private func approve(_ request: PairingRequest) {
        approving = true
        Task {
            defer { approving = false }
            do {
                try await app.sync.engine?.approve(request)
                app.sync.syncNow()
                app.notify("“\(request.deviceName)” added")
                dismiss()
            } catch {
                app.fail("Couldn't add the device", subtitle: error.localizedDescription)
            }
        }
    }
}

// MARK: - recover

private struct RecoverSyncView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var code = ""
    @State private var name = SyncController.defaultDeviceName
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $server, prompt: Text("sync.example.org"))
                        .keyboardType(.URL)
                    TextField("Recovery Code", text: $code, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(3...6)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Section {
                    TextField("Device Name", text: $name)
                } footer: {
                    Text(
                        "Recovering signs out every other device in the account and makes this iPhone the only one. Your data comes back here."
                    )
                }
            }
            .disabled(working)
            .overlay { if working { ProgressView() } }
            .editorToolbar(
                "Recover", confirm: "Recover", disabled: server.isEmpty || code.isEmpty || name.isEmpty || working,
                action: recover)
        }
        .interactiveDismissDisabled(working)
    }

    private func recover() {
        working = true
        Task {
            defer { working = false }
            do {
                try await app.sync.recover(server: server, code: code, name: name)
                app.notify("Account recovered")
                dismiss()
            } catch {
                app.fail("Couldn't recover", subtitle: error.localizedDescription)
            }
        }
    }
}

// MARK: - after a removal

/// what the removed device may have kept, and what to do about it.
private struct ExposureView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(
                        "The removed device may still have these. Removing it can't take them back, so replace them: install a new key on your servers, then delete the old one; change the passwords on the servers."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                if !app.exposedIdentities.isEmpty {
                    Section("Keys") {
                        ForEach(app.exposedIdentities) { identity in
                            Label(identity.name, systemImage: "key.horizontal")
                        }
                    }
                }
                if !app.hostsWithSyncedPasswords.isEmpty {
                    Section("Passwords") {
                        ForEach(app.hostsWithSyncedPasswords) { host in
                            Label(host.displayName, systemImage: "server.rack")
                        }
                    }
                }
            }
            .navigationTitle("Replace These")
            .navigationBarTitleDisplayMode(.inline)
            .dismissToolbar()
        }
    }
}
