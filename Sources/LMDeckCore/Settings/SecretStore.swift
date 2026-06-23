import Foundation
import Security
import os
import Combine

// Where the proxy/endpoint API keys live. Read once and cached in memory (the proxy reads keys per
// request, so this keeps that off the Keychain), written through on change. Two backends:
//
//  • data-protection Keychain — used by the signed release: encrypted at rest, no access prompts,
//    `AfterFirstUnlockThisDeviceOnly` (readable by the launch-at-login daemon while the screen is
//    locked) and never synced to iCloud.
//  • UserDefaults — the unsigned ad-hoc dev build can't use the data-protection Keychain (no
//    entitlement / Team), and the legacy Keychain would prompt on every rebuild, so dev keeps the
//    prior plaintext behavior. The security upgrade lands exactly where it ships.

protocol SecretBackend: Sendable {
    var name: String { get }
    func read(_ account: String) -> String?
    func write(_ account: String, _ value: String)   // empty value = delete
}

public final class SecretStore: @unchecked Sendable {
    public static let shared = SecretStore()

    private let backend: SecretBackend
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private static let logger = Logger(subsystem: "com.enclavum.lmdeck", category: "secrets")

    init(backend: SecretBackend? = nil) {
        self.backend = backend ?? (KeychainSecretBackend.isAvailable()
            ? KeychainSecretBackend() : UserDefaultsSecretBackend())
        Self.logger.log("SecretStore backend: \(self.backend.name, privacy: .public)")
    }

    // Cached read — "" when unset. Reads the backend at most once per account.
    public func get(_ account: String) -> String {
        lock.lock()
        if let cached = cache[account] { lock.unlock(); return cached }
        lock.unlock()
        let value = backend.read(account) ?? ""
        lock.lock(); cache[account] = value; lock.unlock()
        return value
    }

    // Write-through: update the cache and persist (empty deletes).
    public func set(_ account: String, _ value: String) {
        lock.lock(); cache[account] = value; lock.unlock()
        backend.write(account, value)
    }

    // Move any plaintext keys still in `defaults` into the backend, once. No-op when the backend
    // *is* UserDefaults (dev) — the value already lives there. Run before any read so the cache and
    // UI see migrated values.
    public func migrate(_ accounts: [String], from defaults: UserDefaults = .standard) {
        guard !(backend is UserDefaultsSecretBackend) else { return }
        for account in accounts {
            guard let legacy = defaults.string(forKey: account), !legacy.isEmpty else { continue }
            if backend.read(account) == nil { backend.write(account, legacy) }
            defaults.removeObject(forKey: account)
        }
    }

    // The engine + endpoint keys LMDeck stores (Ollama included for completeness — unused today).
    static let secretAccounts = [
        SettingsKeys.ollamaKey, SettingsKeys.omlxKey, SettingsKeys.lmstudioKey,
        SettingsKeys.llamaswapKey, SettingsKeys.endpointKey,
    ]

    // Migrate the known keys once at launch (called by @main before anything reads them).
    public func migrateLegacySecrets() { migrate(Self.secretAccounts) }
}

// MARK: - Backends

// macOS data-protection Keychain (one generic-password item per account).
struct KeychainSecretBackend: SecretBackend {
    let name = "data-protection keychain"
    private static let service = "com.enclavum.lmdeck.secrets"

    // Can this build use the data-protection Keychain? Ad-hoc/unsigned builds lack the entitlement and
    // get errSecMissingEntitlement. The probe never prompts (data-protection has no ACL UI).
    static func isAvailable() -> Bool {
        let account = "__availability_check__"
        let base = query(account)
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data("ok".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { return false }
        SecItemDelete(base as CFDictionary)
        return true
    }

    func read(_ account: String) -> String? {
        var q = Self.query(account)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ account: String, _ value: String) {
        let base = Self.query(account)
        guard !value.isEmpty else { SecItemDelete(base as CFDictionary); return }
        let data = Data(value.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,   // never iCloud
        ]
    }
}

// Dev fallback: the same plaintext UserDefaults storage LMDeck used before the Keychain migration.
struct UserDefaultsSecretBackend: SecretBackend {
    let name = "UserDefaults (dev)"
    func read(_ account: String) -> String? { UserDefaults.standard.string(forKey: account) }
    func write(_ account: String, _ value: String) {
        if value.isEmpty { UserDefaults.standard.removeObject(forKey: account) }
        else { UserDefaults.standard.set(value, forKey: account) }
    }
}

// MARK: - UI model

// SwiftUI-facing model for the key fields in Settings. Loads cached values on init and writes each
// edit through to the SecretStore (Keychain in the signed release, UserDefaults in dev).
@MainActor
public final class SecretsModel: ObservableObject {
    @Published public var omlxKey: String        { didSet { persist(SettingsKeys.omlxKey, omlxKey) } }
    @Published public var lmstudioKey: String     { didSet { persist(SettingsKeys.lmstudioKey, lmstudioKey) } }
    @Published public var llamaswapKey: String    { didSet { persist(SettingsKeys.llamaswapKey, llamaswapKey) } }
    @Published public var endpointKey: String     { didSet { persist(SettingsKeys.endpointKey, endpointKey) } }

    public init() {
        // didSet does not fire during init, so these loads don't write back.
        omlxKey = SecretStore.shared.get(SettingsKeys.omlxKey)
        lmstudioKey = SecretStore.shared.get(SettingsKeys.lmstudioKey)
        llamaswapKey = SecretStore.shared.get(SettingsKeys.llamaswapKey)
        endpointKey = SecretStore.shared.get(SettingsKeys.endpointKey)
    }

    private func persist(_ account: String, _ value: String) { SecretStore.shared.set(account, value) }
}
