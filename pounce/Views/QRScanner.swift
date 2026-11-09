import PounceCore
import SwiftUI
import VisionKit

/// keys too big for one code (rsa) come as `pounce:<i>/<n>:<chunk>` parts,
/// which can be scanned in any order.
struct KeyScannerView: View {
    let onKey: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var assembler = KeyImport.QRAssembler()
    @State private var accepted = 0
    @State private var showHelp = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    Scanner(onPayload: handle)
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "Camera Unavailable", systemImage: "camera.fill",
                        description: Text("pounce needs camera access to scan QR codes. You can allow it in Settings."))
                }
                status
                    .padding(.bottom, 30)
            }
            .navigationTitle("Scan Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("How To", systemImage: "questionmark.circle") { showHelp = true }
                }
            }
            .sheet(isPresented: $showHelp) { QRHelpView() }
            .sensoryFeedback(.impact(weight: .light), trigger: accepted)
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 12) {
            if let progress = assembler.progress {
                ZStack {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(progress.received) / CGFloat(max(progress.total, 1)))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 26, height: 26)
                .animation(.spring(duration: 0.45, bounce: 0.3), value: progress.received)
                Text("Part \(progress.received) of \(progress.total)")
                    .contentTransition(.numericText(value: Double(progress.received)))
            } else {
                Image(systemName: "qrcode.viewfinder")
                Text("Point the camera at the key's QR code")
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
    }

    private func handle(_ payload: String) {
        if payload.hasPrefix("pounce:") {
            if assembler.add(payload) {
                withAnimation(.snappy) { accepted += 1 }
            }
            if let key = assembler.assembled { onKey(key) }
        } else if payload.contains("PRIVATE KEY-----") {
            onKey(payload)
        }
    }
}

private struct QRHelpView: View {
    private let single = "qrencode -t ansiutf8 < ~/.ssh/id_ed25519"
    private let multi = """
        base64 < ~/.ssh/id_rsa | tr -d '\\n' | fold -w 1200 > /tmp/parts
        n=$(wc -l < /tmp/parts | tr -d ' '); i=0
        while read -r p; do i=$((i+1))
          qrencode -t ansiutf8 "pounce:$i/$n:$p"; read -r _ </dev/tty
        done < /tmp/parts; rm /tmp/parts
        """

    var body: some View {
        NavigationStack {
            List {
                Section {
                    command(single)
                } header: {
                    Text("Small keys (Ed25519, ECDSA)")
                } footer: {
                    Text("Prints the key as a QR code in the terminal.")
                }
                Section {
                    command(multi)
                } header: {
                    Text("Large keys (RSA)")
                } footer: {
                    Text("Shows the key as a series of codes. Scan each one, then press return for the next.")
                }
                Section {
                    Label(
                        "Prefer a key with a passphrase: a photo of the screen is then useless on its own. Even better, generate a key on this iPhone and copy only its public key to your servers.",
                        systemImage: "lock.shield"
                    )
                    .font(.subheadline)
                }
            }
            .navigationTitle("Scanning a Key")
            .navigationBarTitleDisplayMode(.inline)
            .dismissToolbar()
        }
        .presentationDetents([.medium, .large])
    }

    private func command(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            }
    }
}

/// reports every qr payload it sees; callers dedupe.
struct Scanner: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .accurate,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: (String) -> Void

        init(onPayload: @escaping (String) -> Void) { self.onPayload = onPayload }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case .barcode(let code) = item, let payload = code.payloadStringValue { onPayload(payload) }
            }
        }
    }
}
