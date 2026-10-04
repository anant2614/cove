import Foundation
import XCTest
@testable import CoveStore

final class SecretStoreTests: XCTestCase {
    func testInMemoryStore() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.secret(for: "k"))
        try store.setSecret("v1", for: "k")
        try store.setSecret("v2", for: "k")
        XCTAssertEqual(try store.secret(for: "k"), "v2")
        try store.deleteSecret(for: "k")
        try store.deleteSecret(for: "k")
        XCTAssertNil(try store.secret(for: "k"))
    }

    func testPassphraseRoundTripAndReencryption() throws {
        let base = InMemorySecretStore(["openai": "sk-plain"])
        let store = PassphraseSecretStore(wrapping: base, parameters: .testing)
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(try store.secret(for: "openai"), "sk-plain", "pass-through when not enabled")

        try store.enable(passphrase: "correct horse", reencrypting: ["openai", "absent"])
        XCTAssertTrue(store.isEnabled)
        XCTAssertFalse(store.isLocked)
        XCTAssertNotEqual(try base.secret(for: "openai"), "sk-plain", "stored encrypted")
        XCTAssertNotNil(try base.secret(for: PassphraseSecretStore.saltRef))
        XCTAssertNotNil(try base.secret(for: PassphraseSecretStore.verifierRef))
        XCTAssertEqual(try store.secret(for: "openai"), "sk-plain")

        try store.setSecret("sk-anthropic", for: "anthropic")
        XCTAssertNotEqual(try base.secret(for: "anthropic"), "sk-anthropic")
        XCTAssertEqual(try store.secret(for: "anthropic"), "sk-anthropic")

        // A new instance over the same base starts locked and unlocks with the passphrase.
        let reopened = PassphraseSecretStore(wrapping: base, parameters: .testing)
        XCTAssertTrue(reopened.isLocked)
        try reopened.unlock(passphrase: "correct horse")
        XCTAssertEqual(try reopened.secret(for: "anthropic"), "sk-anthropic")

        XCTAssertThrowsError(try store.enable(passphrase: "again")) {
            XCTAssertEqual($0 as? SecretStoreError, .alreadyEnabled)
        }
        XCTAssertThrowsError(try store.setSecret("x", for: PassphraseSecretStore.saltRef)) {
            XCTAssertEqual($0 as? SecretStoreError, .reservedRef(PassphraseSecretStore.saltRef))
        }

        try reopened.disable(decrypting: ["openai", "anthropic"])
        XCTAssertFalse(reopened.isEnabled)
        XCTAssertEqual(try base.secret(for: "openai"), "sk-plain")
        XCTAssertEqual(try base.secret(for: "anthropic"), "sk-anthropic")
    }

    func testWrongPassphraseAndLocking() throws {
        let base = InMemorySecretStore()
        let store = PassphraseSecretStore(wrapping: base, parameters: .testing)
        XCTAssertThrowsError(try store.unlock(passphrase: "x")) { XCTAssertEqual($0 as? SecretStoreError, .notEnabled) }
        XCTAssertThrowsError(try store.enable(passphrase: "")) { XCTAssertEqual($0 as? SecretStoreError, .emptyPassphrase) }
        try store.enable(passphrase: "s3cret")
        try store.setSecret("value", for: "ref")

        store.lock()
        XCTAssertTrue(store.isLocked)
        XCTAssertThrowsError(try store.secret(for: "ref")) { XCTAssertEqual($0 as? SecretStoreError, .locked) }
        XCTAssertThrowsError(try store.setSecret("v", for: "ref")) { XCTAssertEqual($0 as? SecretStoreError, .locked) }
        XCTAssertThrowsError(try store.unlock(passphrase: "wrong")) {
            XCTAssertEqual($0 as? SecretStoreError, .wrongPassphrase)
        }
        XCTAssertTrue(store.isLocked)
        try store.unlock(passphrase: "s3cret")
        XCTAssertEqual(try store.secret(for: "ref"), "value")
    }

    func testStandardParametersDeriveQuickly() throws {
        let store = PassphraseSecretStore(wrapping: InMemorySecretStore())
        let start = Date()
        try store.enable(passphrase: "standard params")
        print("scrypt N=2^15 enable took \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        store.lock()
        try store.unlock(passphrase: "standard params")
    }
}
