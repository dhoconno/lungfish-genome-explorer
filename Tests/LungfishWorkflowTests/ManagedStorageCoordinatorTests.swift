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

    func testRemoveOldLocalCopiesDeletesPreviousRootAndClearsCleanupMetadata() async throws {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        let oldRoot = tempDir.appendingPathComponent("old-root", isDirectory: true)
        let newRoot = tempDir.appendingPathComponent("new-root", isDirectory: true)
        let configStore = ManagedStorageConfigStore(homeDirectory: home)
        try configStore.setActiveRoot(oldRoot)
        try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: oldRoot.appendingPathComponent("sentinel.txt").path,
            contents: Data("old-root".utf8)
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

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRoot.path))
        guard case .loaded(let config) = configStore.bootstrapConfigLoadState() else {
            return XCTFail("Expected bootstrap config to remain readable")
        }
        XCTAssertEqual(config.activeRootPath, newRoot.path)
        XCTAssertNil(config.previousRootPath)
        XCTAssertNil(config.migrationState)
    }
}
