import Foundation
import LocalAuthentication
import Security

/// device-only items, never synced or backed up: `key.<identity id>` per private
/// key and `password.<host id>` per saved password.
public enum Keychain {
    static let service = "catgirl.engineering.pounce"

    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case cancelled
        case unavailable(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .cancelled: "Unlocking was cancelled."
            case .unavailable(let status):
                (SecCopyErrorMessageString(status, nil) as String?) ?? "The Keychain returned error \(status)."
            }
        }
    }

    // MARK: private keys

    public static func save(_ key: PrivateKeyMaterial, for identity: UUID, requireBiometry: Bool) throws(Failure) {
        let data: Data
        do { data = try JSONEncoder().encode(key) } catch { throw .unavailable(errSecParam) }
        try write(data, account: "key.\(identity)", requireBiometry: requireBiometry)
    }

    /// keys saved with biometry show the face id prompt with `reason`.
    public static func key(for identity: UUID, reason: String) throws(Failure) -> PrivateKeyMaterial? {
        guard let data = try read(account: "key.\(identity)", reason: reason) else { return nil }
        return try? JSONDecoder().decode(PrivateKeyMaterial.self, from: data)
    }

    public static func deleteKey(for identity: UUID) { delete(account: "key.\(identity)") }

    // MARK: passwords

    public static func savePassword(_ password: String, for host: UUID) throws(Failure) {
        try write(Data(password.utf8), account: "password.\(host)", requireBiometry: false)
    }

    public static func password(for host: UUID) -> String? {
        guard let data = try? read(account: "password.\(host)", reason: "") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func hasPassword(for host: UUID) -> Bool { exists(account: "password.\(host)") }

    public static func deletePassword(for host: UUID) { delete(account: "password.\(host)") }

    // MARK: plumbing

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func write(_ data: Data, account: String, requireBiometry: Bool) throws(Failure) {
        delete(account: account)
        var query = base(account)
        query[kSecValueData as String] = data
        if requireBiometry,
            let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, nil)
        {
            query[kSecAttrAccessControl as String] = access
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw .unavailable(status) }
    }

    private static func read(account: String, reason: String) throws(Failure) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.localizedReason = reason.isEmpty ? "Unlock your SSH key" : reason
        query[kSecUseAuthenticationContext as String] = context
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled, errSecAuthFailed: throw .cancelled
        default: throw .unavailable(status)
        }
    }

    private static func exists(account: String) -> Bool {
        var query = base(account)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private static func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    /// removes every stored secret, for `Erase All Data`.
    public static func deleteAll() {
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary)
    }
}
