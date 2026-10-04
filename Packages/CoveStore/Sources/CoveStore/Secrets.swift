import Crypto
import _CryptoExtras
import Foundation
#if canImport(Security)
import Security
#endif

/// Stores small secrets (API keys) by reference string.
public protocol SecretStore: Sendable {
    /// Stores `value` under `ref`, replacing any previous value.
    func setSecret(_ value: String, for ref: String) throws
    /// The value stored under `ref`, or nil.
    func secret(for ref: String) throws -> String?
    /// Removes the value under `ref`. Removing a missing value is not an error.
    func deleteSecret(for ref: String) throws
}

/// Errors thrown by secret stores.
public enum SecretStoreError: Error, Sendable, Equatable, LocalizedError {
    /// A Keychain call failed with this `OSStatus`.
    case keychain(status: Int32)
    /// The passphrase layer is enabled but locked.
    case locked
    /// The passphrase does not match.
    case wrongPassphrase
    /// The passphrase layer is not enabled.
    case notEnabled
    /// The passphrase layer is already enabled.
    case alreadyEnabled
    /// The passphrase is empty.
    case emptyPassphrase
    /// The ref is reserved for the passphrase layer's own bookkeeping.
    case reservedRef(String)
    /// A stored value could not be decrypted or decoded.
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .keychain(let status): "Keychain error \(status)."
        case .locked: "Secrets are locked. Enter your passphrase to unlock them."
        case .wrongPassphrase: "That passphrase is incorrect."
        case .notEnabled: "Passphrase protection is not enabled."
        case .alreadyEnabled: "Passphrase protection is already enabled."
        case .emptyPassphrase: "The passphrase must not be empty."
        case .reservedRef(let ref): "\(ref) is reserved."
        case .corrupt(let detail): "A stored secret is corrupt: \(detail)"
        }
    }
}

#if canImport(Security)
/// Stores secrets as generic-password Keychain items (service `app.cove.secrets`,
/// account = ref), accessible after first unlock and never synced off the device.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "app.cove.secrets") { self.service = service }

    private func query(_ ref: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: ref]
    }

    public func setSecret(_ value: String, for ref: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(ref) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query(ref).merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status: status) }
    }

    public func secret(for ref: String) throws -> String? {
        var q = query(ref)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status: status) }
        guard let data = item as? Data else { throw SecretStoreError.corrupt(ref) }
        return String(decoding: data, as: UTF8.self)
    }

    public func deleteSecret(for ref: String) throws {
        let status = SecItemDelete(query(ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status: status) }
    }
}
#endif

/// A process-local secret store for tests and platforms without a Keychain.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func setSecret(_ value: String, for ref: String) throws { lock.withLock { values[ref] = value } }
    public func secret(for ref: String) throws -> String? { lock.withLock { values[ref] } }
    public func deleteSecret(for ref: String) throws { _ = lock.withLock { values.removeValue(forKey: ref) } }

    /// All stored refs (for tests).
    public var refs: [String] { lock.withLock { Array(values.keys) } }
}

/// An optional passphrase layer over another ``SecretStore``.
///
/// Values are encrypted with AES-GCM using a 256-bit key derived from the
/// passphrase. The KDF salt/parameters and a verifier (an encrypted known
/// constant) are kept unencrypted in the underlying store under reserved refs.
/// When the layer is not enabled, calls pass straight through; when enabled
/// but locked, reads and writes throw ``SecretStoreError/locked``.
///
/// - Note: The PRD specifies Argon2id, which swift-crypto does not provide, so
///   scrypt (`KDF.Scrypt` from `_CryptoExtras`) is used as the memory-hard KDF.
public final class PassphraseSecretStore: SecretStore, @unchecked Sendable {
    /// scrypt cost parameters, persisted alongside the salt.
    public struct KDFParameters: Codable, Sendable, Hashable {
        /// CPU/memory cost N (a power of two).
        public var rounds: Int
        /// Block size r.
        public var blockSize: Int
        /// Parallelism p.
        public var parallelism: Int

        public init(rounds: Int, blockSize: Int, parallelism: Int) {
            self.rounds = rounds
            self.blockSize = blockSize
            self.parallelism = parallelism
        }

        /// N = 2^15, r = 8, p = 1 (32 MiB of memory; a fraction of a second per derivation).
        public static let standard = KDFParameters(rounds: 1 << 15, blockSize: 8, parallelism: 1)
        /// Cheap parameters for tests only.
        public static let testing = KDFParameters(rounds: 1 << 10, blockSize: 8, parallelism: 1)
    }

    /// Reserved ref holding the salt and KDF parameters (JSON).
    public static let saltRef = "cove.passphrase.salt"
    /// Reserved ref holding the encrypted verifier constant.
    public static let verifierRef = "cove.passphrase.verifier"
    private static let verifierPlaintext = Data("cove-passphrase-verifier-v1".utf8)

    private struct SaltRecord: Codable {
        var salt: Data
        var parameters: KDFParameters
    }

    private let base: any SecretStore
    private let parameters: KDFParameters
    private let keyLock = NSLock()
    private var key: SymmetricKey?

    /// - Parameters:
    ///   - base: The store that holds the (encrypted) values.
    ///   - parameters: scrypt parameters used when the layer is enabled. Unlocking
    ///     always uses the parameters stored at enable time.
    public init(wrapping base: any SecretStore, parameters: KDFParameters = .standard) {
        self.base = base
        self.parameters = parameters
    }

    /// Whether a passphrase has been set up.
    public var isEnabled: Bool { (try? base.secret(for: Self.saltRef)) != nil }

    /// Whether the layer is enabled and has no key in memory.
    public var isLocked: Bool { isEnabled && keyLock.withLock { key == nil } }

    /// Turns on passphrase protection, encrypting the existing values under
    /// `refs`, and leaves the store unlocked.
    public func enable(passphrase: String, reencrypting refs: [String] = []) throws {
        guard !passphrase.isEmpty else { throw SecretStoreError.emptyPassphrase }
        guard !isEnabled else { throw SecretStoreError.alreadyEnabled }
        try refs.forEach(Self.checkNotReserved)
        let plain = try refs.compactMap { ref in try base.secret(for: ref).map { (ref, $0) } }

        var salt = Data(count: 16)
        var rng = SystemRandomNumberGenerator()
        for i in salt.indices { salt[i] = UInt8.random(in: .min ... .max, using: &rng) }
        let newKey = try Self.deriveKey(passphrase: passphrase, salt: salt, parameters: parameters)

        for (ref, value) in plain {
            try base.setSecret(try Self.seal(Data(value.utf8), key: newKey), for: ref)
        }
        try base.setSecret(try Self.seal(Self.verifierPlaintext, key: newKey), for: Self.verifierRef)
        let record = String(decoding: try JSONEncoder().encode(SaltRecord(salt: salt, parameters: parameters)), as: UTF8.self)
        try base.setSecret(record, for: Self.saltRef)
        keyLock.withLock { key = newKey }
    }

    /// Turns passphrase protection off, decrypting the values under `refs` back
    /// to plain text in the underlying store. Requires the store to be unlocked.
    public func disable(decrypting refs: [String] = []) throws {
        guard isEnabled else { throw SecretStoreError.notEnabled }
        try refs.forEach(Self.checkNotReserved)
        let values = try refs.compactMap { ref in try secret(for: ref).map { (ref, $0) } }
        for (ref, value) in values { try base.setSecret(value, for: ref) }
        try base.deleteSecret(for: Self.verifierRef)
        try base.deleteSecret(for: Self.saltRef)
        keyLock.withLock { key = nil }
    }

    /// Derives the key from `passphrase` and keeps it in memory.
    /// Throws ``SecretStoreError/wrongPassphrase`` if it does not match.
    public func unlock(passphrase: String) throws {
        guard !passphrase.isEmpty else { throw SecretStoreError.wrongPassphrase }
        guard let saltText = try base.secret(for: Self.saltRef) else { throw SecretStoreError.notEnabled }
        guard let record = try? JSONDecoder().decode(SaltRecord.self, from: Data(saltText.utf8)),
              let verifier = try base.secret(for: Self.verifierRef) else {
            throw SecretStoreError.corrupt("passphrase metadata")
        }
        let candidate = try Self.deriveKey(passphrase: passphrase, salt: record.salt, parameters: record.parameters)
        guard let opened = try? Self.open(verifier, key: candidate), opened == Self.verifierPlaintext else {
            throw SecretStoreError.wrongPassphrase
        }
        keyLock.withLock { key = candidate }
    }

    /// Forgets the key. Reads and writes throw ``SecretStoreError/locked`` until ``unlock(passphrase:)``.
    public func lock() {
        keyLock.withLock { key = nil }
    }

    public func setSecret(_ value: String, for ref: String) throws {
        try Self.checkNotReserved(ref)
        guard isEnabled else { return try base.setSecret(value, for: ref) }
        try base.setSecret(try Self.seal(Data(value.utf8), key: try currentKey()), for: ref)
    }

    public func secret(for ref: String) throws -> String? {
        try Self.checkNotReserved(ref)
        guard isEnabled else { return try base.secret(for: ref) }
        let key = try currentKey()
        guard let sealed = try base.secret(for: ref) else { return nil }
        guard let data = try? Self.open(sealed, key: key) else { throw SecretStoreError.corrupt(ref) }
        return String(decoding: data, as: UTF8.self)
    }

    public func deleteSecret(for ref: String) throws {
        try Self.checkNotReserved(ref)
        try base.deleteSecret(for: ref)
    }

    // MARK: Helpers

    private func currentKey() throws -> SymmetricKey {
        guard let key = keyLock.withLock({ key }) else { throw SecretStoreError.locked }
        return key
    }

    private static func checkNotReserved(_ ref: String) throws {
        if ref == saltRef || ref == verifierRef { throw SecretStoreError.reservedRef(ref) }
    }

    private static func deriveKey(passphrase: String, salt: Data, parameters: KDFParameters) throws -> SymmetricKey {
        try KDF.Scrypt.deriveKey(from: Data(passphrase.utf8), salt: salt, outputByteCount: 32,
                                 rounds: parameters.rounds, blockSize: parameters.blockSize,
                                 parallelism: parameters.parallelism)
    }

    /// AES-GCM seal; returns base64 of nonce‖ciphertext‖tag.
    private static func seal(_ plaintext: Data, key: SymmetricKey) throws -> String {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw SecretStoreError.corrupt("seal")
        }
        return combined.base64EncodedString()
    }

    private static func open(_ text: String, key: SymmetricKey) throws -> Data {
        guard let combined = Data(base64Encoded: text) else { throw SecretStoreError.corrupt("base64") }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
    }
}
