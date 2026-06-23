import Testing
import Foundation
@testable import LMDeckCore

struct SecretStoreTests {
    // In-memory backend that counts reads, so we can assert the cache hits the backend at most once.
    private final class FakeBackend: SecretBackend, @unchecked Sendable {
        let name = "fake"
        var store: [String: String] = [:]
        private(set) var reads = 0
        func read(_ account: String) -> String? { reads += 1; return store[account] }
        func write(_ account: String, _ value: String) { store[account] = value.isEmpty ? nil : value }
    }

    @Test func getCachesAfterFirstRead() {
        let be = FakeBackend(); be.store["k"] = "v"
        let store = SecretStore(backend: be)
        #expect(store.get("k") == "v")
        #expect(store.get("k") == "v")
        #expect(be.reads == 1)              // second read served from cache
        #expect(store.get("missing") == "") // unset → "" (not nil)
    }

    @Test func setWritesThroughAndUpdatesCache() {
        let be = FakeBackend()
        let store = SecretStore(backend: be)
        store.set("k", "secret")
        #expect(be.store["k"] == "secret")  // persisted to the backend
        #expect(store.get("k") == "secret") // and visible without a backend read
        #expect(be.reads == 0)
        store.set("k", "")                  // empty value deletes
        #expect(be.store["k"] == nil)
        #expect(store.get("k") == "")
    }

    @Test func migrateMovesFromUserDefaultsThenClears() {
        let be = FakeBackend()
        let defaults = UserDefaults(suiteName: "secretstore-test-\(UUID().uuidString)")!
        defaults.set("legacy", forKey: "omlxKey")
        let store = SecretStore(backend: be)
        store.migrate(["omlxKey", "absent"], from: defaults)
        #expect(be.store["omlxKey"] == "legacy")           // moved into the backend
        #expect(defaults.string(forKey: "omlxKey") == nil) // and cleared from UserDefaults
    }

    @Test func migrateIsNoOpForUserDefaultsBackend() {
        // In dev the backend already *is* UserDefaults, so there's nothing to move (and we must not
        // delete the user's keys).
        let store = SecretStore(backend: UserDefaultsSecretBackend())
        let defaults = UserDefaults(suiteName: "secretstore-test-\(UUID().uuidString)")!
        defaults.set("x", forKey: "omlxKey")
        store.migrate(["omlxKey"], from: defaults)
        #expect(defaults.string(forKey: "omlxKey") == "x")
    }
}
