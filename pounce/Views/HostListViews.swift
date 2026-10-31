import PounceCore
import SwiftUI

struct HostListView: View {
    let namespace: Namespace.ID
    @Environment(AppModel.self) private var app
    @Environment(SessionManager.self) private var sessions
    @State private var search = ""
    @State private var editing: Host?
    @State private var importing = false
    @State private var tag: String?

    var body: some View {
        let quickConnect = quickConnect
        let (filtered, favorites, recents) = sections()
        let shown = Set((favorites + (search.isEmpty && tag == nil ? recents : [])).map(\.id))
        let others = filtered.filter { !shown.contains($0.id) }
        let tags = app.tags
        List {
            if let quick = quickConnect {
                Section {
                    Button {
                        connectQuick(quick)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connect to \(quick.description)").font(.body.weight(.medium))
                                Text("Quick connect, without saving").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "bolt.fill").foregroundStyle(.tint)
                        }
                    }
                    Button("Save as New Host…", systemImage: "plus") {
                        editing = Host(endpoint: quick)
                    }
                }
            }
            if !favorites.isEmpty {
                Section("Favorites") { rows(favorites) }
            }
            if search.isEmpty, tag == nil, !recents.isEmpty {
                Section("Recent") { rows(recents) }
            }
            if !others.isEmpty {
                Section(favorites.isEmpty && recents.isEmpty ? "" : (tag ?? "All Hosts")) { rows(others) }
            }
        }
        .animation(.snappy, value: filtered.map(\.id))
        .overlay {
            if app.hosts.isEmpty, quickConnect == nil {
                ContentUnavailableView {
                    Label("No Hosts", systemImage: "server.rack")
                } description: {
                    Text("Add a host, paste your ~/.ssh/config, or type user@host in search to connect right away.")
                } actions: {
                    Button("Add Host") { editing = Host(hostname: "", username: "") }
                        .buttonStyle(.glassProminent)
                    Button("Import SSH Config") { importing = true }
                }
            } else if !search.isEmpty, filtered.isEmpty, quickConnect == nil {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "Search or user@host")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) {
            if let quick = quickConnect, filtered.isEmpty { connectQuick(quick) }
        }
        .navigationTitle("Hosts")
        .toolbar {
            if !tags.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Tag", selection: $tag) {
                            Text("All Hosts").tag(String?.none)
                            ForEach(tags, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    } label: {
                        Label("Filter", systemImage: tag == nil ? "tag" : "tag.fill")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Host", systemImage: "plus") { editing = Host(hostname: "", username: "") }
                    Button("Import SSH Config", systemImage: "doc.text") { importing = true }
                } label: {
                    Label("Add", systemImage: "plus")
                } primaryAction: {
                    editing = Host(hostname: "", username: "")
                }
            }
        }
        .sheet(item: $editing) { host in
            HostEditor(host: host)
        }
        .sheet(isPresented: $importing) {
            ConfigImportView()
        }
        .sensoryFeedback(.selection, trigger: tag)
    }

    @ViewBuilder private func rows(_ hosts: [Host]) -> some View {
        ForEach(hosts) { host in
            Button {
                sessions.open(host)
            } label: {
                HostRow(host: host)
            }
            .buttonStyle(CrouchButtonStyle())
            .matchedTransitionSource(id: "host-\(host.id)", in: namespace)
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) { app.delete(host) }
                Button("Edit", systemImage: "pencil") { editing = host }
                    .tint(.gray)
            }
            .swipeActions(edge: .leading) {
                Button(
                    host.isFavorite ? "Unfavorite" : "Favorite", systemImage: host.isFavorite ? "star.slash" : "star"
                ) {
                    app.toggleFavorite(host)
                }
                .tint(.yellow)
            }
            .contextMenu {
                Button("Connect", systemImage: "terminal") { sessions.open(host) }
                Button("Edit", systemImage: "pencil") { editing = host }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    var copy = host
                    copy.id = UUID()
                    copy.label = host.label.isEmpty ? "" : "\(host.label) copy"
                    copy.lastConnected = nil
                    editing = copy
                }
                Button("Copy Address", systemImage: "doc.on.doc") { UIPasteboard.general.string = host.address }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) { app.delete(host) }
            }
        }
    }

    // MARK: filtering

    private func sections() -> (all: [Host], favorites: [Host], recents: [Host]) {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let all = app.hosts
            .filter { tag == nil || $0.tags.contains(tag!) }
            .filter {
                query.isEmpty
                    || [$0.label, $0.hostname, $0.username, $0.address].contains { $0.lowercased().contains(query) }
                    || $0.tags.contains { $0.lowercased().contains(query) }
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let recents = all.filter { !$0.isFavorite && $0.lastConnected != nil }
            .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
        return (all, all.filter(\.isFavorite), Array(recents.prefix(3)))
    }

    /// a search shaped like `user@host[:port]` offers a direct connect.
    private var quickConnect: SSHEndpoint? {
        let text = search.trimmingCharacters(in: .whitespaces)
        guard text.contains("@") || text.hasPrefix("ssh ") else { return nil }
        return QuickConnect.parse(text)
    }

    private func connectQuick(_ endpoint: SSHEndpoint) {
        sessions.open(Host(endpoint: endpoint))
        search = ""
    }
}

struct HostRow: View {
    let host: Host
    @Environment(AppModel.self) private var app
    @Environment(SessionManager.self) private var sessions

    var body: some View {
        let open = sessions.sessions(for: host)
        HStack(spacing: 12) {
            IconTile(symbol: host.symbol)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(host.displayName).font(.body.weight(.medium)).lineLimit(1)
                    if host.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let session = open.last {
                HStack(spacing: 5) {
                    if open.count > 1 {
                        Text("\(open.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    StatusDot(kind: session.state.dot)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .foregroundStyle(.primary)
        .animation(.snappy, value: open.map(\.state))
        .animation(.snappy, value: host.isFavorite)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens a terminal")
    }

    private var subtitle: String {
        var parts = [host.label.isEmpty ? nil : host.address]
        if let jump = host.jumpHostIDs.last.flatMap(app.host) { parts.append("via \(jump.displayName)") }
        if !host.tags.isEmpty { parts.append(host.tags.joined(separator: ", ")) }
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? host.address : text
    }
}

struct ConfigImportView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        let entries = SSHConfigImport.parse(text)
        NavigationStack {
            Form {
                Section {
                    CodeEditor(
                        text: $text,
                        placeholder:
                            "Host bastion\n    HostName bastion.example.com\n    User me\n\nHost db\n    ProxyJump bastion",
                        minHeight: 180)
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        text = UIPasteboard.general.string ?? text
                    }
                } footer: {
                    Text(
                        "Host, HostName, User, Port, ProxyJump and port forwards are imported. Keys aren't: import them in Keys."
                    )
                }
                if !entries.isEmpty {
                    Section("\(entries.count) Hosts") {
                        ForEach(entries, id: \.alias) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.alias).font(.body.weight(.medium))
                                Text(describe(entry)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .animation(.snappy, value: entries.count)
            .editorToolbar("Import SSH Config", confirm: "Import", disabled: entries.isEmpty) {
                let count = app.importConfig(text)
                app.notify("Imported \(count) host\(count == 1 ? "" : "s")")
                dismiss()
            }
        }
    }

    private func describe(_ entry: SSHConfigImport.Entry) -> String {
        var parts = ["\(entry.user.map { "\($0)@" } ?? "")\(entry.hostname)\(entry.port == 22 ? "" : ":\(entry.port)")"]
        if !entry.proxyJump.isEmpty { parts.append("via \(entry.proxyJump.joined(separator: ", "))") }
        if !entry.forwards.isEmpty {
            parts.append("\(entry.forwards.count) forward\(entry.forwards.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}
