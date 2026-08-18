import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class ManagedStorageCoordinatorTests: XCTestCase {
    private var tempDir: URL!

    private struct CopyRecord: Equatable, Sendable {
        let from: String
        let to: String
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-storage-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testChangeLocationCopiesDatabasesReinstallsToolsAndSwitchesRootAfterVerification() async throws {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let oldRoot = tempDir.appendingPathComponent("old-root", isDirectory: true)
        let newRoot = tempDir.appendingPathComponent("new-root", isDirectory: true)
        let configStore = ManagedStorageConfigStore(homeDirectory: home)
        try configStore.setActiveRoot(oldRoot)

        actor Recorder {
            private var copiedPairs: [CopyRecord] = []
            private var installedRoots: [String] = []
            private var verifiedRoots: [String] = []

            func recordCopy(from: URL, to: URL) {
                copiedPairs.append(CopyRecord(from: from.path, to: to.path))
            }

            func recordInstalledRoot(_ url: URL) {
                installedRoots.append(url.path)
            }

            func recordVerifiedRoot(_ url: URL) {
                verifiedRoots.append(url.path)
            }

            func snapshot() -> (copies: [CopyRecord], installs: [String], verifications: [String]) {
                (copiedPairs, installedRoots, verifiedRoots)
            }
        }

        let recorder = Recorder()
        let coordinator = ManagedStorageCoordinator(
            configStore: configStore,
            validator: { ManagedStorageLocation(rootURL: $0) },
            databaseMigrator: { from, to in
                await recorder.recordCopy(from: from, to: to)
                try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
            },
            toolInstaller: { condaRoot in
                await recorder.recordInstalledRoot(condaRoot)
                try FileManager.default.createDirectory(at: condaRoot, withIntermediateDirectories: true)
            },
            verifier: { location in
                await recorder.recordVerifiedRoot(location.rootURL)
            }
        )

        try await coordinator.changeLocation(to: newRoot)

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(configStore.currentLocation().rootURL.standardizedFileURL, newRoot.standardizedFileURL)
        XCTAssertEqual(snapshot.copies, [
            CopyRecord(
                from: oldRoot.appendingPathComponent("databases").path,
                to: newRoot.appendingPathComponent("databases").path
            )
        ])
        XCTAssertEqual(snapshot.installs, [newRoot.appendingPathComponent("conda").path])
        XCTAssertEqual(snapshot.verifications, [newRoot.path])

        guard case .loaded(let config) = configStore.bootstrapConfigLoadState() else {
            return XCTFail("Expected bootstrap config to be written")
        }
        XCTAssertEqual(config.activeRootPath, newRoot.path)
        XCTAssertEqual(config.previousRootPath, oldRoot.path)
        XCTAssertEqual(config.migrationState, .completed)
    }

    func testChangeLocationRestoresOriginalRootWhenVerificationFails() async throws {
        struct ExpectedFailure: Error {}

        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let oldRoot = tempDir.appendingPathComponent("old-root", isDirectory: true)
        let newRoot = tempDir.appendingPathComponent("new-root", isDirectory: true)
        let configStore = ManagedStorageConfigStore(homeDirectory: home)
        try configStore.setActiveRoot(oldRoot)

        let coordinator = ManagedStorageCoordinator(
            configStore: configStore,
            validator: { ManagedStorageLocation(rootURL: $0) },
            databaseMigrator: { _, _ in },
            toolInstaller: { _ in },
            verifier: { _ in throw ExpectedFailure() }
        )

        do {
            try await coordinator.changeLocation(to: newRoot)
            XCTFail("Expected verification failure")
        } catch is ExpectedFailure {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(configStore.currentLocation().rootURL.standardizedFileURL, oldRoot.standardizedFileURL)
        guard case .loaded(let config) = configStore.bootstrapConfigLoadState() else {
            return XCTFail("Expected bootstrap config to remain readable")
        }
        XCTAssertEqual(config.activeRootPath, oldRoot.path)
        XCTAssertNil(config.previousRootPath)
        XCTAssertNil(config.migrationState)
    }

    func testChangeLocationRejectsNestedRootRelationships() async throws {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let oldRoot = tempDir.appendingPathComponent("managed-root", isDirectory: true)
        let newRoot = oldRoot.appendingPathComponent("nested-child", isDirectory: true)
        let configStore = ManagedStorageConfigStore(homeDirectory: home)
        try configStore.setActiveRoot(oldRoot)

        let coordinator = ManagedStorageCoordinator(
            configStore: configStore,
            validator: { ManagedStorageLocation(rootURL: $0) },
            databaseMigrator: { _, _ in XCTFail("Migration should not start for nested roots") },
            toolInstaller: { _ in XCTFail("Install should not start for nested roots") },
            verifier: { _ in XCTFail("Verification should not start for nested roots") }
        )

        do {
            try await coordinator.changeLocation(to: newRoot)
            XCTFail("Expected nested-root migration to fail")
        } catch let error as ManagedStorageCoordinator.Error {
            guard case .nestedRootRelationship(let currentRoot, let requestedRoot) = error else {
                return XCTFail("Unexpected coordinator error: \(error)")
            }
            XCTAssertEqual(currentRoot.standardizedFileURL, oldRoot.standardizedFileURL)
            XCTAssertEqual(requestedRoot.standardizedFileURL, newRoot.standardizedFileURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemoveOldLocalCopiesDeletesOnlyManagedContentWhenPreviousRootContainsOtherFiles() async throws {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let oldRoot = tempDir.appendingPathComponent("old-root", isDirectory: true)
        let newRoot = tempDir.appendingPathComponent("new-root", isDirectory: true)
        let configStore = ManagedStorageConfigStore(homeDirectory: home)
        try configStore.setActiveRoot(oldRoot)
        try FileManager.default.createDirectory(at: oldRoot.appendingPathComponent("conda"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldRoot.appendingPathComponent("databases"), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: oldRoot.appendingPathComponent("notes.txt").path,
            contents: Data("keep-me".utf8)
        )

        let coordinator = ManagedStorageCoordinator(
            configStore: configStore,
            validator: { ManagedStorageLocation(rootURL: $0) },
            databaseMigrator: { _, _ in },
            toolInstaller: { _ in },
            verifier: { _ in }
        )

        try await coordinator.changeLocation(to: newRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))

        try await coordinator.removeOldLocalCopies()

        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent("conda").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent("databases").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent("notes.txt").path))
        guard case .loaded(let config) = configStore.bootstrapConfigLoadState() else {
            return XCTFail("Expected bootstrap config to remain readable")
        }
        XCTAssertEqual(config.activeRootPath, newRoot.path)
        XCTAssertNil(config.previousRootPath)
        XCTAssertNil(config.migrationState)
    }

    func testChangeLocationCarriesDependencyReceiptToTheNewRoot() async throws {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let oldRoot = tempDir.appendingPathComponent("old-root", isDirectory: true)
        let newRoot = tempDir.appendingPathComponent("new-root", isDirectory: true)
        let configStore = ManagedStorageConfigStore(homeDirectory: home)
        try configStore.setActiveRoot(oldRoot)
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        let receiptPayload = Data(#"{"schemaVersion":1}"#.utf8)
        FileManager.default.createFile(
            atPath: ManagedStorageLocation(rootURL: oldRoot).dependencyReceiptURL.path,
            contents: receiptPayload
        )

        let coordinator = ManagedStorageCoordinator(
            configStore: configStore,
            validator: { ManagedStorageLocation(rootURL: $0) },
            databaseMigrator: { _, _ in },
            toolInstaller: { _ in },
            verifier: { _ in }
        )

        try await coordinator.changeLocation(to: newRoot)

        let movedReceipt = ManagedStorageLocation(rootURL: newRoot).dependencyReceiptURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedReceipt.path))
        XCTAssertEqual(try Data(contentsOf: movedReceipt), receiptPayload)

        // Cleanup takes the stale copy with the rest of the managed content.
        try await coordinator.removeOldLocalCopies()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ManagedStorageLocation(rootURL: oldRoot).dependencyReceiptURL.path
            )
        )
    }

    func testRemoveOldLocalCopiesRejectsNestedRootRelationships() async throws {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let oldRoot = tempDir.appendingPathComponent("old-root", isDirectory: true)
        let activeRoot = oldRoot.appendingPathComponent("nested-active", isDirectory: true)
        let configStore = ManagedStorageConfigStore(homeDirectory: home)

        try FileManager.default.createDirectory(at: oldRoot.appendingPathComponent("conda"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldRoot.appendingPathComponent("databases"), withIntermediateDirectories: true)

        let config = ManagedStorageBootstrapConfig(
            activeRootPath: activeRoot.path,
            previousRootPath: oldRoot.path,
            migrationState: .completed
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: configStore.configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(config).write(to: configStore.configURL, options: [.atomic])

        let coordinator = ManagedStorageCoordinator(configStore: configStore)

        do {
            try await coordinator.removeOldLocalCopies()
            XCTFail("Expected nested-root cleanup to fail")
        } catch let error as ManagedStorageCoordinator.Error {
            guard case .nestedRootRelationship(let currentRoot, let requestedRoot) = error else {
                return XCTFail("Unexpected coordinator error: \(error)")
            }
            XCTAssertEqual(currentRoot.standardizedFileURL, activeRoot.standardizedFileURL)
            XCTAssertEqual(requestedRoot.standardizedFileURL, oldRoot.standardizedFileURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent("conda").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldRoot.appendingPathComponent("databases").path))
        guard case .loaded(let persisted) = configStore.bootstrapConfigLoadState() else {
            return XCTFail("Expected cleanup metadata to remain after rejection")
        }
        XCTAssertEqual(persisted.previousRootPath, oldRoot.path)
        XCTAssertEqual(persisted.migrationState, .completed)
    }
}
