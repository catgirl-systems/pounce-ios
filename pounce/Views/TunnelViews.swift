import PounceCore
import SwiftUI

struct TunnelListView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: Tunnel?

    private var groups: [(Host, [Tunnel])] {
        app.hosts.compactMap { host in
            let tunnels = app.savedTunnels.filter { $0.hostID == host.id }
            return tunnels.isEmpty ? nil : (host, tunnels)
        }
    }

    var body: some View {
        let groups = groups
        List {
            ForEach(groups, id: \.0.id) { host, tunnels in
                Section(host.displayName) {
                    ForEach(tunnels) { tunnel in
                        TunnelRow(tunnel: tunnel)
                            .contentShape(.rect)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) { app.delete(tunnel) }
                                Button("Edit", systemImage: "pencil") { editing = tunnel }.tint(.gray)
                            }
                            .contextMenu {
                                Button("Edit", systemImage: "pencil") { editing = tunnel }
                                Button("Delete", systemImage: "trash", role: .destructive) { app.delete(tunnel) }
                            }
                    }
                }
            }
            if !groups.isEmpty {
                Section {
                } footer: {
                    Text(
                        "Tunnels run while pounce is open, and for a short while after you switch away. iOS stops them after that; they restart when you come back."
                    )
                }
            }
        }
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("No Tunnels", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text(
                        "Forward ports through your hosts: reach a database behind a bastion, or browse through a SOCKS proxy."
                    )
                } actions: {
                    if let host = app.hosts.first {
                        Button("Add Tunnel") { editing = newTunnel(on: host) }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
        }
        .navigationTitle("Tunnels")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") {
                    if let host = app.hosts.first { editing = newTunnel(on: host) }
                }
                .disabled(app.hosts.isEmpty)
            }
        }
        .sheet(item: $editing) { TunnelEditor(tunnel: $0) }
    }

    private func newTunnel(on host: Host) -> Tunnel {
        Tunnel(hostID: host.id, kind: .local, bindPort: 8080, targetHost: "localhost", targetPort: 80)
    }
}

private struct TunnelRow: View {
    let tunnel: Tunnel
    @Environment(TunnelManager.self) private var tunnels

    var body: some View {
        let status = tunnels.status[tunnel.id]
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tunnel.displayName).font(.body.weight(.medium)).lineLimit(1)
                Text(detail(status))
                    .font(.caption)
                    .foregroundStyle(isFailed(status) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                if case .running = status, let traffic = tunnels.traffic(tunnel) {
                    TrafficLine(traffic: traffic)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            Spacer()
            if status == .starting {
                ProgressView().controlSize(.small)
            }
            Toggle(
                tunnel.displayName,
                isOn: Binding(
                    get: { tunnels.isOn(tunnel) },
                    set: { $0 ? tunnels.start(tunnel) : tunnels.stop(tunnel) })
            )
            .labelsHidden()
        }
        .animation(.snappy, value: status)
        .sensoryFeedback(trigger: status) { _, new in
            switch new {
            case .running: .success
            case .failed: .error
            default: nil
            }
        }
    }

    private func isFailed(_ status: TunnelManager.Status?) -> Bool {
        if case .failed = status { true } else { false }
    }

    private func detail(_ status: TunnelManager.Status?) -> String {
        switch status {
        case .failed(let message): message
        case .running(let port):
            switch tunnel.kind {
            case .local: "localhost:\(port) → \(tunnel.targetHost):\(tunnel.targetPort)"
            case .remote: "server:\(port) → \(tunnel.targetHost):\(tunnel.targetPort)"
            case .dynamic: "SOCKS5 proxy on localhost:\(port)"
            }
        case .starting: "Connecting…"
        case nil: tunnel.name.isEmpty ? description : tunnel.summary
        }
    }

    private var description: String {
        switch tunnel.kind {
        case .local: "Local port \(tunnel.bindPort)"
        case .remote: "Server port \(tunnel.bindPort)"
        case .dynamic: "SOCKS proxy"
        }
    }
}

private struct TrafficLine: View {
    let traffic: TrafficCounter
    @State private var last = 0
    @State private var flowing = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let sent = traffic.bytesSent
            let received = traffic.bytesReceived
            HStack(spacing: 10) {
                Label(sent.byteCount, systemImage: "arrow.up")
                Label(received.byteCount, systemImage: "arrow.down")
                if traffic.openConnections > 0 {
                    Label("\(traffic.openConnections)", systemImage: "link")
                }
                FlowDots(active: flowing)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
            .onChange(of: context.date) { _, _ in
                let total = sent + received
                withAnimation(.snappy) { flowing = total != last }
                last = total
            }
        }
    }
}

private struct FlowDots: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(.tint)
                    .frame(width: 4, height: 4)
                    .opacity(active ? 1 : 0.25)
                    .phaseAnimator(active && !reduceMotion ? [0, 1] : [0]) { view, phase in
                        view.offset(y: phase == 1 ? -2 : 0)
                    } animation: { _ in
                        .easeInOut(duration: 0.35).delay(Double(index) * 0.12)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}

struct TunnelEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tunnel: Tunnel

    init(tunnel: Tunnel) { _tunnel = State(initialValue: tunnel) }

    private var isValid: Bool {
        (1...65535).contains(tunnel.bindPort)
            && (tunnel.kind == .dynamic
                || (!tunnel.targetHost.isEmpty && (1...65535).contains(tunnel.targetPort)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $tunnel.name, prompt: Text("Optional"))
                    Picker("Host", selection: $tunnel.hostID) {
                        ForEach(app.hosts) { Text($0.displayName).tag($0.id) }
                    }
                }
                Section {
                    Picker("Type", selection: $tunnel.kind) {
                        ForEach(Tunnel.Kind.allCases, id: \.self) { Text($0.label) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(explanation)
                        .contentTransition(.opacity)
                }
                Section {
                    PortField(title: tunnel.kind == .remote ? "Server Port" : "Local Port", value: $tunnel.bindPort)
                    if tunnel.kind != .dynamic {
                        TextField("Destination", text: $tunnel.targetHost, prompt: Text("localhost"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        PortField(title: "Destination Port", value: $tunnel.targetPort)
                    }
                } footer: {
                    Text(tunnel.summary).font(.system(.footnote, design: .monospaced))
                }
            }
            .animation(.snappy, value: tunnel.kind)
            .editorToolbar(app.savedTunnels[id: tunnel.id] == nil ? "New Tunnel" : "Edit Tunnel", disabled: !isValid) {
                let wasOn = app.tunnels.isOn(tunnel)
                if wasOn { app.tunnels.stop(tunnel) }
                app.save(tunnel)
                if wasOn { app.tunnels.start(tunnel) }
                dismiss()
            }
        }
    }

    private var explanation: String {
        switch tunnel.kind {
        case .local:
            "Connections to a port on this iPhone go through the host to the destination, as seen from the host. Like ssh -L."
        case .remote:
            "Connections to a port on the host come back through this iPhone to the destination, as seen from the iPhone. Like ssh -R."
        case .dynamic:
            "A SOCKS5 proxy on this iPhone; apps that use it reach the network from the host. Like ssh -D."
        }
    }
}

extension Tunnel.Kind {
    var label: String {
        switch self {
        case .local: "Local"
        case .remote: "Remote"
        case .dynamic: "SOCKS"
        }
    }
}
