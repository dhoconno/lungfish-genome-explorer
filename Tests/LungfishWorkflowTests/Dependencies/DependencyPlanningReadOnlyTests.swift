import XCTest
@testable import LungfishWorkflow

final class DependencyPlanningReadOnlyTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func currentPlan(root: URL, registry: MetagenomicsDatabaseRegistry) async throws {
        var services = ReconcilerServices.live(condaManager: CondaManager(rootPrefix: root.appendingPathComponent("conda")),
                                               storageRoot: root, metagenomicsRegistry: registry)
        services.listEnvironments = { [:] }
        services.installedPackIDs = { [] }
        services.registryDatabaseVersions = { [:] }
        services.installedMicromambaVersion = { nil }
        let manifest = ManagedToolLock(packID: "test", displayName: "Test", version: "1", tools: [], managedData: [])
        let reconciler = DependencyReconciler(manifest: manifest, storageRoot: root, services: services,
                                             appVersion: "test", operationCenter: nil)
        _ = try await reconciler.currentPlan()
    }

    func testPlanDoesNotInitializeMissingDatabaseStorageOrReceipt() async throws {
        let root = try temporaryRoot()
        let base = root.appendingPathComponent("databases")
        try await currentPlan(root: root, registry: MetagenomicsDatabaseRegistry(baseDirectory: base))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("dependency-receipt.json").path))
    }

    func testPlanPreservesInterruptedUpdatePayloadsAndManifestBytes() async throws {
        let root = try temporaryRoot()
        let base = root.appendingPathComponent("databases")
        let installed = base.appendingPathComponent("viral")
        let retired = base.appendingPathComponent(".viral.old-1")
        let staged = base.appendingPathComponent(".viral.staging-2")
        for directory in [retired, staged] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(directory.lastPathComponent.utf8).write(to: directory.appendingPathComponent("sentinel"))
        }
        let record = MetagenomicsDatabaseInfo(name: "Interrupted fixture", tool: "kraken2", version: "1", sizeBytes: 1,
            catalogID: "viral", description: "Test", path: installed, status: .ready, recommendedRAM: 1)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(DatabaseManifest(version: 1, databases: [record]))
        let manifestURL = base.appendingPathComponent("metagenomics-db-registry.json")
        try bytes.write(to: manifestURL)

        let registry = MetagenomicsDatabaseRegistry(baseDirectory: base)
        try await currentPlan(root: root, registry: registry)
        let snapshot = try await registry.installedDatabaseSnapshot()
        XCTAssertEqual(snapshot.map(\.name), [record.name])
        XCTAssertEqual(ReconcilerServices.metagenomicsDatabaseVersions(from: snapshot), ["viral": "1"])
        XCTAssertEqual(try Data(contentsOf: manifestURL), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        for directory in [retired, staged] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sentinel").path))
        }
    }
}
