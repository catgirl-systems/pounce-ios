import Foundation
import Observation
import PounceCore
import UIKit
import os

private let syncLog = Logger(category: "sync")

/// owns the sync engine and the loop that runs it while pounce is in front:
/// one round, then a long-poll until the server has news or a local edit lands
@MainActor @Observable final class SyncController {
    private(set) var engine: SyncEngine?
    private(set) var isSyncing = false
    private(set) var lastSynced: Date?
    private(set) var problem: String?
    private(set) var devices: [RosterDevice] = []
    private(set) var thisDevice: Data?
    private(set) var server = ""

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var waiting: Task<Void, any Error>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private let vault = KeychainSyncVault()

    private static let stateURL = Store.directory.appendingPathComponent("sync.json")

    private static let hooks = SyncHooks(
        snapshot: { await MainActor.run { AppModel.shared.sync.isOn ? AppModel.shared.data : nil } },
        mutate: { body in await MainActor.run { AppModel.shared.sync.isOn ? AppModel.shared.applySync(body) : [] } })

    init() {
        if let engine = SyncEngine.load(stateURL: Self.stateURL, vault: vault, hooks: Self.hooks) {
            adopt(engine)
        }
    }

    var isOn: Bool { engine != nil }

    static var defaultDeviceName: String { UIDevice.current.model }

    private func adopt(_ engine: SyncEngine) {
        self.engine = engine
        problem = nil
        Task { await refresh() }
    }

    private func refresh() async {
        guard let engine else { return }
        // runs after every round; unchanged values shouldn't redraw settings
        let (devices, thisDevice, server) = await (engine.devices, engine.deviceID, engine.origin)
        if devices != self.devices { self.devices = devices }
        if thisDevice != self.thisDevice { self.thisDevice = thisDevice }
        if server != self.server { self.server = server }
    }

    func start() {
        guard let engine, loop == nil else { return }
        loop = Task { await run(engine) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        waiting?.cancel()
    }

    private func run(_ engine: SyncEngine) async {
        var backoff: Double = 2
        while !Task.isCancelled {
            isSyncing = true
            do {
                let report = try await engine.sync()
                isSyncing = false
                lastSynced = .now
                problem =
                    report.rejected > 0
                    ? "\(report.rejected) synced \(report.rejected == 1 ? "item" : "items") didn't verify and were ignored. The server may have altered them."
                    : nil
                await refresh()
                backoff = 2
                if again {
                    again = false
                    continue
                }
                // stopped during the round: a restarted loop has its own wait by now
                guard !Task.isCancelled else { return }
                let wait = Task { try await engine.waitForChanges() }
                waiting = wait
                _ = try? await wait.value
                if waiting == wait { waiting = nil }
            } catch SyncError.removed {
                isSyncing = false
                syncLog.notice("this device was removed from sync")
                await engine.forget()
                self.engine = nil
                loop = nil
                AppModel.shared.fail("This \(Device.noun) was removed from sync", subtitle: "Your data stays on it.")
                return
            } catch {
                isSyncing = false
                if Task.isCancelled { return }
                problem = error.localizedDescription
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 60)
            }
        }
    }

    func localChanged() {
        guard let engine else { return }
        Task { await engine.noteLocalChanges() }
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            again = true
            waiting?.cancel()
        }
    }

    func syncNow() {
        again = true
        waiting?.cancel()
        start()
    }

    /// accepts a bare host name and assumes https
    private static func serverURL(_ text: String) throws(SyncError) -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)") else {
            throw .badServerURL
        }
        return url
    }

    func create(server: String, invite: String, name: String) async throws -> RecoveryCode {
        let (engine, code) = try await SyncEngine.create(
            origin: try Self.serverURL(server), invite: invite, deviceName: name, stateURL: Self.stateURL, vault: vault,
            hooks: Self.hooks)
        adopt(engine)
        start()
        return code
    }

    func recover(server: String, code: String, name: String) async throws {
        let engine = try await SyncEngine.recover(
            origin: try Self.serverURL(server), code: code, deviceName: name, stateURL: Self.stateURL, vault: vault,
            hooks: Self.hooks)
        adopt(engine)
        start()
    }

    func finish(_ joiner: SyncJoiner) async throws {
        let engine = try await joiner.finish(stateURL: Self.stateURL, vault: vault, hooks: Self.hooks)
        adopt(engine)
        start()
    }

    func remove(_ device: RosterDevice) async throws {
        guard let engine else { throw SyncError.notSetUp }
        try await engine.removeDevice(device.id)
        await refresh()
        AppModel.shared.markSyncedSecretsExposed()
    }

    /// synchronous on purpose: once it returns, no round can read the app's data
    func turnOff() {
        stop()
        debounce?.cancel()
        let engine = engine
        self.engine = nil
        devices = []
        Task { await engine?.forget() }
    }

    func deleteAccount() async throws {
        guard let engine else { throw SyncError.notSetUp }
        stop()
        do {
            try await engine.deleteAccount()
        } catch {
            start()
            throw error
        }
        self.engine = nil
        devices = []
    }

    func uploadKey(_ material: PrivateKeyMaterial, identity: UUID) async throws {
        guard let engine else { throw SyncError.notSetUp }
        try await engine.uploadKey(material, identity: identity)
    }

    func uploadPassword(_ password: String, host: UUID) async throws {
        guard let engine else { throw SyncError.notSetUp }
        try await engine.uploadPassword(password, host: host)
    }
}
