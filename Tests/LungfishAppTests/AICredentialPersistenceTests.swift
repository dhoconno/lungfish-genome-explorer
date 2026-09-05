import XCTest
@testable import LungfishApp

@MainActor
final class AICredentialPersistenceTests: XCTestCase {
    func testPasteThenImmediateDeparturePersistsLatestFieldValue() async {
        let storage = FakeAICredentialStorage()
        let editor = AICredentialPersistence { value, key in try await storage.write(value, key: key) }
        editor.edit("invented first", forKey: "provider")
        editor.edit("invented latest", forKey: "provider")
        editor.departed()
        await editor.flush()
        let actual = await storage.value(for: "provider")
        XCTAssertEqual(actual, "invented latest")
    }

    func testManualClearThenDepartureRemovesOnlyEditedKey() async {
        let storage = FakeAICredentialStorage(values: ["provider": "invented old", "unrelated": "retain"])
        let editor = AICredentialPersistence { value, key in try await storage.write(value, key: key) }
        editor.edit("", forKey: "provider")
        editor.departed()
        await editor.flush()
        let removed = await storage.value(for: "provider")
        let other = await storage.value(for: "unrelated")
        XCTAssertNil(removed)
        XCTAssertEqual(other, "retain")
    }

    func testClearAllAIKeysCannotResurrectPendingEditsOrDeleteUnrelatedSecret() async {
        let keys = AICredentialPersistence.aiKeys
        var values = Dictionary(uniqueKeysWithValues: keys.map { ($0, "invented old") })
        values["provenance.signing.privateKey"] = "invented retained signing material"
        let storage = FakeAICredentialStorage(values: values)
        let editor = AICredentialPersistence { value, key in try await storage.write(value, key: key) }
        editor.edit("invented replacement", forKey: keys[0])
        await editor.clearAIKeys()
        await editor.flush()
        for key in keys {
            let value = await storage.value(for: key)
            XCTAssertNil(value)
        }
        let unrelated = await storage.value(for: "provenance.signing.privateKey")
        XCTAssertEqual(unrelated, "invented retained signing material")
    }
    func testFailedWriteRemainsVisibleAcrossDepartureAndUnrelatedSuccessUntilRetried() async {
        let storage = FakeAICredentialStorage()
        await storage.setFailure(for: "provider", enabled: true)
        let editor = AICredentialPersistence { value, key in try await storage.write(value, key: key) }
        editor.edit("invented latest", forKey: "provider")
        editor.departed()
        await editor.flush()
        XCTAssertNotNil(editor.lastError)
        XCTAssertEqual(editor.unstoredValue(forKey: "provider"), "invented latest")
        editor.edit("invented other", forKey: "other")
        await editor.flush()
        XCTAssertNotNil(editor.lastError, "Saving another provider cannot hide the failed change")
        await storage.setFailure(for: "provider", enabled: false)
        editor.retryFailedWrites()
        await editor.flush()
        XCTAssertNil(editor.lastError)
        XCTAssertFalse(editor.isSaving)
        let value = await storage.value(for: "provider")
        XCTAssertEqual(value, "invented latest")
    }

    func testSettingsFieldsClearIntentSurvivesPartialFailureAndRetry() async {
        let keys = AICredentialPersistence.aiKeys
        let storage = FakeAICredentialStorage(values: Dictionary(uniqueKeysWithValues: keys.map { ($0, "invented old") }))
        await storage.setFailure(for: keys[0], enabled: true)
        let persistence = AICredentialPersistence { value, key in try await storage.write(value, key: key) }
        let fields = AICredentialFields()
        fields.openAIKey = "invented old"
        fields.anthropicKey = "invented old"
        fields.geminiKey = "invented old"
        await fields.clear(using: persistence).value
        XCTAssertEqual([fields.openAIKey, fields.anthropicKey, fields.geminiKey], ["", "", ""])
        XCTAssertNotNil(persistence.lastError)
        await storage.setFailure(for: keys[0], enabled: false)
        persistence.retryFailedWrites()
        await persistence.flush()
        XCTAssertEqual([fields.openAIKey, fields.anthropicKey, fields.geminiKey], ["", "", ""])
        XCTAssertNil(persistence.lastError)
        for key in keys {
            let stored = await storage.value(for: key)
            XCTAssertNil(stored)
        }
    }

    func testSettingsFieldsDisableEditingSynchronouslyForEntireClear() async {
        let storage = FakeAICredentialStorage()
        let persistence = AICredentialPersistence { value, key in try await storage.write(value, key: key) }
        let fields = AICredentialFields()
        fields.openAIKey = "invented old"
        let clearing = fields.clear(using: persistence)
        // No suspension is possible before the view observes this flag.
        XCTAssertTrue(fields.isClearing)
        await clearing.value
        XCTAssertFalse(fields.isClearing)
        XCTAssertEqual(fields.openAIKey, "")
    }

}

private actor FakeAICredentialStorage {
    var values: [String: String]
    private enum Failure: Error { case injected }
    private var failures: Set<String> = []
    func setFailure(for key: String, enabled: Bool) {
        if enabled { failures.insert(key) } else { failures.remove(key) }
    }
    init(values: [String: String] = [:]) { self.values = values }
    func write(_ value: String, key: String) throws {
        if failures.contains(key) { throw Failure.injected }
        if value.isEmpty { values.removeValue(forKey: key) } else { values[key] = value }
    }
    func value(for key: String) -> String? { values[key] }
}
