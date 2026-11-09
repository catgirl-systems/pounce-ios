import PounceCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("accentHex") private var accentHex = Accent.defaultHex
    @AppStorage("themeID") private var themeID = TerminalTheme.pounce.id
    @AppStorage("fontSize") private var fontSize = TerminalFont.defaultSize
    @AppStorage("appLock") private var appLock = false
    @AppStorage("keepAwake") private var keepAwake = true
    @AppStorage("keepAlive") private var keepAlive = false
    @AppStorage("showEndCard") private var showEndCard = true
    @AppStorage("savePasswords") private var savePasswords = true
    @AppStorage("fillNeedsBiometry") private var fillNeedsBiometry = false
    @AppStorage("programTitles") private var programTitles = true
    @AppStorage("modifierLock") private var modifierLock = ModifierLock.doubleTap
    @State private var confirmErase = false
    @State private var importing = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ThemePickerView()
                } label: {
                    LabeledContent("Theme", value: TerminalTheme.named(themeID).name)
                }
                Stepper(value: $fontSize, in: TerminalFont.sizes, step: 1) {
                    LabeledContent("Font Size") {
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .contentTransition(.numericText(value: fontSize))
                            .animation(.snappy, value: fontSize)
                    }
                }
                Toggle("Keep Screen On", isOn: $keepAwake)
                Toggle("Ask When a Session Ends", isOn: $showEndCard)
                Toggle("Let Programs Set the Title", isOn: $programTitles)
                Picker("Lock Ctrl and Alt With", selection: $modifierLock) {
                    ForEach(ModifierLock.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text(
                    "When a shell exits or its connection is lost, pounce offers to reconnect. Turned off, the session just closes. Programs like tmux and vim can rename a session; turned off, it keeps the host's name. A locked Ctrl or Alt stays on until tapped again."
                )
            }
            Section {
                NavigationLink {
                    SyncView()
                } label: {
                    LabeledContent(
                        "Sync",
                        value: app.sync.isOn ? app.sync.server.replacingOccurrences(of: "https://", with: "") : "Off")
                }
            } footer: {
                Text("End-to-end encrypted, through a pounce-sync server you choose.")
            }
            Section {
                Toggle("Stay Connected in Background", isOn: $keepAlive)
                    .onChange(of: keepAlive) { app.keeper.settingChanged() }
            } footer: {
                Text(
                    "Keeps sessions and tunnels open while pounce is in the background, using coarse location updates so iOS doesn't suspend it. Your location isn't stored or sent anywhere. Uses a little more battery. When this is off, connections pause about 30 seconds after you leave pounce."
                )
            }
            Section("Appearance") {
                NavigationLink {
                    AccentPickerView()
                } label: {
                    LabeledContent("Accent Color") {
                        HStack(spacing: 8) {
                            Text(Accent.name(for: accentHex))
                            Circle().fill(Accent.color(hex: accentHex)).frame(width: 14, height: 14)
                        }
                    }
                }
            }
            Section {
                Toggle(isOn: lockBinding) {
                    Label("Lock with \(biometryName)", systemImage: Biometry.current.symbol)
                }
                Toggle("Offer to Save Passwords", isOn: $savePasswords)
                Toggle(
                    "\(biometryName) to Fill Passwords",
                    isOn: authenticated($fillNeedsBiometry, reason: "\(biometryName) for filling passwords"))
                NavigationLink {
                    KnownHostsView()
                } label: {
                    LabeledContent("Known Hosts", value: "\(app.knownHosts.count)")
                }
            } header: {
                Text("Security")
            } footer: {
                Text(
                    "Keys and passwords stay in this iPhone's Keychain and aren't included in backups. They sync only if you turn that on for a key or host. When a session asks for a password the host has saved, pounce offers to fill it in."
                )
            }
            Section {
                Button("Import SSH Config", systemImage: "doc.text") { importing = true }
                Button("Erase All Data", systemImage: "trash", role: .destructive) { confirmErase = true }
            }
            Section {
                NavigationLink("Acknowledgements") { AcknowledgementsView() }
                LabeledContent("Version", value: version)
            }
        }
        .navigationTitle("Settings")
        .sensoryFeedback(.selection, trigger: fontSize)
        .sheet(isPresented: $importing) { ConfigImportView() }
        .confirmationDialog("Erase everything?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase All Data", role: .destructive) {
                app.eraseAll()
                app.notify("Everything erased")
            }
        } message: {
            Text(
                "Removes all hosts, keys, passwords, tunnels, snippets and known hosts from this iPhone. Keys made in the Secure Enclave can't be recovered."
            )
        }
    }

    /// asks for biometry first, so nobody locks themselves out.
    private var lockBinding: Binding<Bool> { authenticated($appLock, reason: "the app lock") }

    /// only changes after biometry (or the passcode) succeeds.
    private func authenticated(_ value: Binding<Bool>, reason: String) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue },
            set: { on in
                Task {
                    if await Biometry.authenticate(on ? "Turn on \(reason)" : "Turn off \(reason)") {
                        value.wrappedValue = on
                    }
                }
            })
    }

    private var biometryName: String { Biometry.current.name }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }
}

struct ThemePickerView: View {
    @AppStorage("themeID") private var themeID = TerminalTheme.pounce.id
    @AppStorage("caretShape") private var caretShape = CaretShape.bar
    @AppStorage("caretAnimation") private var caretAnimation = CaretAnimation.pulse
    @AppStorage("caretGlide") private var caretGlide = true

    var body: some View {
        ScrollView {
            cursorSettings
                .padding([.horizontal, .top])
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 16) {
                ForEach(TerminalTheme.all) { theme in
                    Button {
                        withAnimation(.snappy) { themeID = theme.id }
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ThemePreview(theme: theme)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(.tint, lineWidth: themeID == theme.id ? 3 : 0)
                                }
                                .scaleEffect(themeID == theme.id ? 1.02 : 1)
                            HStack {
                                Text(theme.name).font(.subheadline.weight(.medium))
                                Spacer()
                                if themeID == theme.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                        .transition(.symbolEffect(.drawOn))
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.name)
                    .accessibilityAddTraits(themeID == theme.id ? .isSelected : [])
                }
            }
            .padding()
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: themeID)
        .sensoryFeedback(.selection, trigger: caretShape)
        .sensoryFeedback(.selection, trigger: caretAnimation)
    }

    private var cursorSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cursor").font(.headline)
            CaretPreview(
                theme: TerminalTheme.named(themeID),
                style: CaretStyle(shape: caretShape, animation: caretAnimation, glide: caretGlide))
            Picker("Shape", selection: $caretShape) {
                ForEach(CaretShape.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Animation", selection: $caretAnimation) {
                ForEach(CaretAnimation.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Smooth Movement", isOn: $caretGlide)
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
    }
}

struct KnownHostsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            ForEach(app.knownHosts, id: \.self) { known in
                VStack(alignment: .leading, spacing: 4) {
                    Text(known.port == 22 ? known.host : "[\(known.host)]:\(known.port)")
                        .font(.body.weight(.medium))
                    if let key = try? SSHPublicKey(blob: known.key) {
                        Text(key.fingerprint)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(key.kind.label) · added \(known.added.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { app.forget(app.knownHosts[index]) }
            }
        }
        .overlay {
            if app.knownHosts.isEmpty {
                ContentUnavailableView(
                    "No Known Hosts", systemImage: "checkmark.shield",
                    description: Text("Host keys you trust are listed here."))
            }
        }
        .navigationTitle("Known Hosts")
        .toolbar { if !app.knownHosts.isEmpty { EditButton() } }
    }
}

private struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                Text("pounce is built on these open source projects. Thank you to their authors.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            credit("SwiftNIO SSH", "Apple Inc. and the SwiftNIO project authors", "Apache License 2.0")
            credit("SwiftNIO", "Apple Inc. and the SwiftNIO project authors", "Apache License 2.0")
            credit("SwiftNIO Transport Services", "Apple Inc. and the SwiftNIO project authors", "Apache License 2.0")
            credit("Swift Crypto", "Apple Inc. and the Swift Crypto project authors", "Apache License 2.0")
            credit("SwiftTerm", "Miguel de Icaza, the xterm.js authors, SourceLair", "MIT License")
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func credit(_ name: String, _ authors: String, _ license: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.body.weight(.medium))
            Text(authors).font(.caption).foregroundStyle(.secondary)
            Text(license).font(.caption).foregroundStyle(.tertiary)
        }
    }
}
