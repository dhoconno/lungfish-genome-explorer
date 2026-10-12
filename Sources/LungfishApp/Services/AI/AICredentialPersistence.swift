import Foundation
import LungfishCore
import Observation

/// Owns credential writes separately from the lifetime of a settings tab.
@MainActor
@Observable
package final class AICredentialPersistence {
    typealias Store = @Sendable (_ value: String, _ key: String) async throws -> Void
    package static let shared = AICredentialPersistence(store: persistInKeychain)
    nonisolated private static func persistInKeychain(_ value: String, _ key: String) async throws {
        try await KeychainSecretStorage.shared.store(secret: value, forKey: key)
    }
    package static let aiKeys = [KeychainSecretStorage.openAIAPIKey, KeychainSecretStorage.anthropicAPIKey,
                         KeychainSecretStorage.geminiAPIKey]
    package var lastError: String? {
        failedValues.isEmpty ? nil : "Could not save API key changes to Keychain. Retry before using the new credentials."
    }
    package var isSaving: Bool { pendingCount > 0 }
    @ObservationIgnored private let store: Store
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    private var pendingCount = 0
    private var failedValues: [String: String] = [:]

    init(store: @escaping Store) { self.store = store }

    package func edit(_ value: String, forKey key: String) {
        let preceding = pendingTask
        pendingCount += 1
        // Each committed field value owns its write independently of the view.
        // Ordering also prevents a late write from resurrecting a cleared key.
        pendingTask = Task {
            await preceding?.value
            do {
                try await store(value, key)
                failedValues.removeValue(forKey: key)
            } catch {
                failedValues[key] = value
            }
            pendingCount -= 1
        }
    }

    /// Departure cancels presentation/validation work, never accepted writes.
    package func departed() {}
    package func flush() async { await pendingTask?.value }
    package func unstoredValue(forKey key: String) -> String? { failedValues[key] }
    package func retryFailedWrites() {
        for (key, value) in failedValues { edit(value, forKey: key) }
    }
    func clearAIKeys() async {
        for key in Self.aiKeys { edit("", forKey: key) }
        await flush()
    }
}
