// DependencyReconcilerTests.swift - Tests for the dependency reconciler actor
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class DependencyReconcilerTests: XCTestCase {
    actor Calls {
        var created: [String] = []
        var removed: [String] = []
        var dbs: [String] = []
        var metagenomicsDBs: [String] = []
        var bootstraps: [String] = []
        var pipelines: [String] = []

        func create(_ n: String) { created.append(n) }
        func remove(_ n: String) { removed.append(n) }
        func db(_ n: String) { dbs.append(n) }
        func metagenomicsDB(_ n: String) { metagenomicsDBs.append(n) }
        func bootstrap(_ n: String) { bootstraps.append(n) }
        func pipeline(_ n: String) { pipelines.append(n) }
    }

    private func tmpRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lge-recon-\(UUID().uuidString)")
    }

    private func databaseSpec(
        id: String,
        version: String,
        updatePolicy: DatabaseUpdatePolicy? = nil
    ) -> DatabaseSpec {
        DatabaseSpec(
            id: id, tool: "sra-human-scrubber", displayName: "HS", version: version,
            url: "u", filename: "f", md5: nil, sha256: nil, md5Sidecar: true, indexFormat: nil,
            minimumToolVersion: nil, sizeBytes: 1, sizeOnDisk: nil, recommendedRAM: nil,
            description: nil, releaseDate: nil, sourceUrl: nil, releasesUrl: nil,
            updatePolicy: updatePolicy, collection: nil
        )
    }

    private func manifest(
        databases: [DatabaseSpec]? = nil,
        pipelines: [PipelineSpec] = []
    ) -> ManagedToolLock {
        ManagedToolLock(
            packID: "lungfish-tools", displayName: "T", version: "0",
            tools: [.init(
                id: "samtools", environment: "samtools",
                packageSpec: "bioconda::samtools=1.24=h36b3a25_1",
                executables: ["samtools"], version: "1.24"
            )],
            managedData: [], dependencySet: "2026.2",
            pipelines: pipelines,
            databases: databases ?? [databaseSpec(id: "human-scrubber", version: "20260706v2")],
            bootstrap: BootstrapSpec(micromamba: .init(version: "2.9.0-0", sha256: nil))
        )
    }

    private func services(
        calls: Calls,
        envs: [String: [CondaMetaPackage]],
        failCreate: Set<String> = [],
        registryDatabaseVersions: [String: String] = ["human-scrubber": "20250916v2"],
        metagenomicsDatabaseVersions: [String: String] = [:],
        micromambaVersion: String? = "2.9.0-0",
        metagenomicsUpdateError: Error? = nil
    ) -> ReconcilerServices {
        // Start from live so any closure this test forgets to override is still a real one;
        // .live must not touch the filesystem at construction time for that to be safe.
        var s = ReconcilerServices.live(condaManager: .shared, storageRoot: FileManager.default.temporaryDirectory)
        s.createEnvironment = { name, _, _ in
            if failCreate.contains(name) { throw NSError(domain: "t", code: 1) }
            await calls.create(name)
        }
        s.removeEnvironment = { name in await calls.remove(name) }
        s.smokeTest = { _ in }
        s.installRegistryDatabase = { id, _ in
            await calls.db(id)
            return URL(fileURLWithPath: "/x")
        }
        s.updateMetagenomicsDatabase = { id, _ in
            await calls.metagenomicsDB(id)
            if let metagenomicsUpdateError { throw metagenomicsUpdateError }
        }
        s.installBootstrap = { version in await calls.bootstrap(version) }
        s.prefetchPipeline = { id, _ in await calls.pipeline(id) }
        s.listEnvironments = { envs }
        s.installedPackIDs = { [] }
        s.registryDatabaseVersions = { registryDatabaseVersions }
        s.metagenomicsDatabaseVersions = { metagenomicsDatabaseVersions }
        s.installedMicromambaVersion = { micromambaVersion }
        return s
    }

    // MARK: - Brief tests

    func testApplyInstallsRequiredAndWritesReceipt() async throws {
        let root = tmpRoot()
        let calls = Calls()
        let reconciler = DependencyReconciler(
            manifest: manifest(), storageRoot: root,
            services: services(calls: calls, envs: [:]),
            appVersion: "0.5.0-beta30", operationCenter: nil
        )
        let plan = try await reconciler.currentPlan()
        XCTAssertEqual(plan.installEnvironments.map(\.environment), ["samtools"])

        let result = try await reconciler.apply(plan, selection: .all(from: plan)) { _, _, _ in }
        let created = await calls.created
        let dbs = await calls.dbs
        XCTAssertEqual(created, ["samtools"])
        XCTAssertEqual(dbs, ["human-scrubber"])
        XCTAssertTrue(result.failed.isEmpty)

        let saved = try XCTUnwrap(try DependencyReceiptStore(storageRoot: root).load())
        XCTAssertEqual(saved.dependencySet, "2026.2")
        XCTAssertEqual(saved.environments["samtools"]?.packageSpec, "bioconda::samtools=1.24=h36b3a25_1")
        XCTAssertEqual(saved.databases["human-scrubber"]?.version, "20260706v2")
    }

    func testFailedInstallLeavesEntryFailedAndSetUnstamped() async throws {
        let root = tmpRoot()
        let calls = Calls()
        let reconciler = DependencyReconciler(
            manifest: manifest(), storageRoot: root,
            services: services(calls: calls, envs: [:], failCreate: ["samtools"]),
            appVersion: "x", operationCenter: nil
        )
        let plan = try await reconciler.currentPlan()
        let result = try await reconciler.apply(plan, selection: .all(from: plan)) { _, _, _ in }
        XCTAssertNotNil(result.failed["samtools"])

        let saved = try XCTUnwrap(try DependencyReceiptStore(storageRoot: root).load())
        XCTAssertEqual(saved.environments["samtools"]?.state, .failed)
        XCTAssertNil(saved.dependencySet, "set must not be stamped while required work failed")

        // Re-planning after failure still wants samtools.
        let again = try await reconciler.currentPlan()
        XCTAssertEqual(
            again.installEnvironments.map(\.environment) + again.reinstallEnvironments.map(\.environment),
            ["samtools"]
        )
    }

    func testRequiredOnlySelectionSkipsDatabases() async throws {
        let root = tmpRoot()
        let calls = Calls()
        let reconciler = DependencyReconciler(
            manifest: manifest(), storageRoot: root,
            services: services(calls: calls, envs: [:]),
            appVersion: "x", operationCenter: nil
        )
        let plan = try await reconciler.currentPlan()
        _ = try await reconciler.apply(plan, selection: .requiredOnly(from: plan)) { _, _, _ in }
        let dbs = await calls.dbs
        XCTAssertEqual(dbs, [])
    }

    func testMissingReceiptIsSynthesizedFromDisk() async throws {
        let root = tmpRoot()
        let reconciler = DependencyReconciler(
            manifest: manifest(), storageRoot: root,
            services: services(
                calls: Calls(),
                envs: ["samtools": [.init(
                    name: "samtools", version: "1.24", build: "h36b3a25_1",
                    subdir: "osx-arm64", channel: nil
                )]]
            ),
            appVersion: "x", operationCenter: nil
        )
        let receipt = try await reconciler.loadOrSynthesizeReceipt()
        XCTAssertTrue(receipt.synthesized)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("dependency-receipt.json").path),
            "a synthesized receipt is not persisted until the first successful apply/stamp"
        )

        let plan = try await reconciler.currentPlan()
        XCTAssertTrue(plan.installEnvironments.isEmpty && plan.reinstallEnvironments.isEmpty)
    }

    // MARK: - Controller-mandated tests

    func testSecondApplyWhileApplyingThrows() async throws {
        let root = tmpRoot()
        let calls = Calls()
        var svc = services(calls: calls, envs: [:])
        // Hold the first apply inside createEnvironment until the second apply has been attempted.
        let gate = Gate()
        svc.createEnvironment = { name, _, _ in
            await calls.create(name)
            await gate.wait()
        }
        let reconciler = DependencyReconciler(
            manifest: manifest(), storageRoot: root, services: svc,
            appVersion: "x", operationCenter: nil
        )
        let plan = try await reconciler.currentPlan()

        let first = Task { try await reconciler.apply(plan, selection: .all(from: plan)) { _, _, _ in } }
        await gate.waitUntilEntered()

        do {
            _ = try await reconciler.apply(plan, selection: .all(from: plan)) { _, _, _ in }
            XCTFail("a second concurrent apply must throw")
        } catch let error as DependencyReconcilerError {
            XCTAssertEqual(error, .alreadyApplying)
        }

        await gate.open()
        _ = try await first.value
    }

    func testUpdateNotSupportedIsRecordedAsFailure() async throws {
        let root = tmpRoot()
        let calls = Calls()
        let notSupported = MetagenomicsDatabaseRegistryError.updateNotSupported(
            name: "Standard-16", reason: "locally built databases are rebuilt by reinstalling"
        )
        let reconciler = DependencyReconciler(
            manifest: manifest(databases: [databaseSpec(id: "kraken2-standard-16", version: "20260706")]),
            storageRoot: root,
            services: services(
                calls: calls, envs: [:],
                registryDatabaseVersions: [:],
                metagenomicsDatabaseVersions: ["kraken2-standard-16": "20250916"],
                metagenomicsUpdateError: notSupported
            ),
            appVersion: "x", operationCenter: nil
        )
        let plan = try await reconciler.currentPlan()
        XCTAssertEqual(plan.databaseUpdates.map(\.managedBy), [.metagenomicsRegistry])

        let result = try await reconciler.apply(plan, selection: .all(from: plan)) { _, _, _ in }
        let attempted = await calls.metagenomicsDBs
        XCTAssertEqual(attempted, ["kraken2-standard-16"], "the update is attempted exactly once, no auto-reinstall")
        let message = try XCTUnwrap(result.failed["kraken2-standard-16"])
        XCTAssertTrue(message.contains("rebuilt by reinstalling"), "failure records the updateNotSupported reason: \(message)")

        let saved = try XCTUnwrap(try DependencyReceiptStore(storageRoot: root).load())
        XCTAssertNil(saved.databases["kraken2-standard-16"], "metagenomics databases keep their own registry")
        XCTAssertEqual(saved.dependencySet, "2026.2", "an advisory database failure does not block the set stamp")
    }

    func testStampCurrentSetRecordsPipelinesAndBootstrap() async throws {
        let root = tmpRoot()
        let pipelines = [PipelineSpec(
            id: "taxtriage", repository: "jhuapl-bio/taxtriage",
            revision: "v0.9.0", releaseVersion: "0.9.0"
        )]
        let reconciler = DependencyReconciler(
            manifest: manifest(pipelines: pipelines), storageRoot: root,
            services: services(calls: Calls(), envs: [:]),
            appVersion: "0.5.0-beta30", operationCenter: nil
        )
        try await reconciler.stampCurrentSet()

        let saved = try XCTUnwrap(try DependencyReceiptStore(storageRoot: root).load())
        XCTAssertEqual(saved.dependencySet, "2026.2")
        XCTAssertEqual(saved.appVersion, "0.5.0-beta30")
        XCTAssertEqual(saved.manifestHash, manifest(pipelines: pipelines).manifestHash)
        XCTAssertFalse(saved.synthesized)
        XCTAssertEqual(saved.pipelines["taxtriage"]?.revision, "v0.9.0")
        XCTAssertEqual(saved.bootstrap?.micromambaVersion, "2.9.0-0")
    }

    func testKnownEnvironmentNamesIncludeAllBuiltInPacks() {
        let names = DependencyReconciler.builtInPackEnvironmentNames()
        for expected in ["fastqc", "bedtools", "minimap2", "samtools"] {
            XCTAssertTrue(names.contains(expected), "missing pack environment '\(expected)'")
        }
    }

    // MARK: - Provenance

    func testApplyWritesDecodableProvenanceEnvelope() async throws {
        let root = tmpRoot()
        let reconciler = DependencyReconciler(
            manifest: manifest(), storageRoot: root,
            services: services(calls: Calls(), envs: [:]),
            appVersion: "0.5.0-beta30", operationCenter: nil
        )
        let plan = try await reconciler.currentPlan()
        _ = try await reconciler.apply(plan, selection: .all(from: plan)) { _, _, _ in }

        let directory = root.appendingPathComponent("provenance/dependencies", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".lungfish-provenance.json") }
        XCTAssertEqual(files.count, 1, "one envelope per apply")
        XCTAssertTrue(try XCTUnwrap(files.first).contains("2026.2"), "filename carries the dependency set")

        let data = try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(files.first)))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(ProvenanceEnvelope.self, from: data)
        XCTAssertEqual(envelope.workflowName, "dependency-reconcile")
        XCTAssertEqual(envelope.toolName, "lungfish")
        XCTAssertEqual(envelope.toolVersion, "0.5.0-beta30")
        XCTAssertEqual(envelope.steps.count, 2, "one step per applied item (env + database)")
    }

    func testRemovalsAreSkippedWhenARequiredItemFailed() async throws {
        let root = tmpRoot()
        let calls = Calls()
        // A receipt that records a Lungfish-created environment the manifest no longer pins
        // licenses its removal.
        var seeded = DependencyReceipt.empty()
        seeded.environments["retired-tool"] = .init(
            packageSpec: "bioconda::retired-tool=1.0=h0", packID: "lungfish-tools",
            installedAt: Date(), state: .installed
        )
        try DependencyReceiptStore(storageRoot: root).save(seeded)

        let reconciler = DependencyReconciler(
            manifest: manifest(), storageRoot: root,
            services: services(
                calls: calls,
                envs: ["retired-tool": [.init(
                    name: "retired-tool", version: "1.0", build: "h0", subdir: "osx-arm64", channel: nil
                )]],
                failCreate: ["samtools"]
            ),
            appVersion: "x", operationCenter: nil
        )
        let plan = try await reconciler.currentPlan()
        XCTAssertEqual(plan.removeEnvironments, ["retired-tool"])

        _ = try await reconciler.apply(plan, selection: .all(from: plan)) { _, _, _ in }
        let removed = await calls.removed
        XCTAssertFalse(removed.contains("retired-tool"), "removals wait until required work succeeds")
    }

    func testBootstrapRunsBeforeEnvironments() async throws {
        let root = tmpRoot()
        let calls = Calls()
        let order = Order()
        var svc = services(calls: calls, envs: [:], micromambaVersion: "2.8.0-0")
        svc.installBootstrap = { version in
            await calls.bootstrap(version)
            await order.record("bootstrap")
        }
        svc.createEnvironment = { name, _, _ in
            await calls.create(name)
            await order.record("env:\(name)")
        }
        let reconciler = DependencyReconciler(
            manifest: manifest(), storageRoot: root, services: svc,
            appVersion: "x", operationCenter: nil
        )
        let plan = try await reconciler.currentPlan()
        XCTAssertEqual(plan.bootstrapUpdate?.targetVersion, "2.9.0-0")

        _ = try await reconciler.apply(plan, selection: .all(from: plan)) { _, _, _ in }
        let recorded = await order.entries
        XCTAssertEqual(recorded.first, "bootstrap")
        XCTAssertTrue(recorded.contains("env:samtools"))

        let saved = try XCTUnwrap(try DependencyReceiptStore(storageRoot: root).load())
        XCTAssertEqual(saved.bootstrap?.micromambaVersion, "2.9.0-0")
    }

    func testOperationSinkReceivesParentAndChildOperations() async throws {
        let root = tmpRoot()
        let sink = RecordingSink()
        let reconciler = DependencyReconciler(
            manifest: manifest(), storageRoot: root,
            services: services(calls: Calls(), envs: [:]),
            appVersion: "x", operationCenter: sink
        )
        let plan = try await reconciler.currentPlan()
        _ = try await reconciler.apply(plan, selection: .all(from: plan)) { _, _, _ in }

        let titles = sink.startedTitles
        XCTAssertEqual(titles.first, "Update tools to 2026.2")
        XCTAssertTrue(titles.contains { $0.contains("samtools") })
        XCTAssertGreaterThanOrEqual(sink.completedCount, 2)
    }

    func testUnwritableReceiptDoesNotDiscardTheRun() async throws {
        // A regular file where the storage root should be makes every receipt save fail.
        let root = tmpRoot()
        try Data().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let calls = Calls()
        let reconciler = DependencyReconciler(
            manifest: manifest(), storageRoot: root,
            services: services(calls: calls, envs: [:]),
            appVersion: "x", operationCenter: nil
        )
        let plan = try await reconciler.currentPlan()
        let result = try await reconciler.apply(plan, selection: .all(from: plan)) { _, _, _ in }

        let created = await calls.created
        XCTAssertEqual(created, ["samtools"], "the install still ran")
        XCTAssertNotNil(result.failed["dependency-receipt"], "the unsaveable receipt is reported, not thrown")
    }

    // MARK: - Helpers

    private actor Gate {
        private var isOpen = false
        private var entered = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            entered = true
            for waiter in entryWaiters { waiter.resume() }
            entryWaiters.removeAll()
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    private actor Order {
        private(set) var entries: [String] = []
        func record(_ entry: String) { entries.append(entry) }
    }

    /// The sink protocol is synchronous, so recording has to be synchronous too: a
    /// `Task`-hopping actor would not have observed the calls by assertion time.
    private final class RecordingSink: DependencyOperationSink, @unchecked Sendable {
        private let lock = NSLock()
        private var titles: [String] = []
        private var completed = 0
        private var failed = 0

        var startedTitles: [String] { lock.withLock { titles } }
        var completedCount: Int { lock.withLock { completed } }
        var failedCount: Int { lock.withLock { failed } }

        func start(title: String, detail: String) -> UUID {
            lock.withLock { titles.append(title) }
            return UUID()
        }
        func update(id: UUID, progress: Double, detail: String) {}
        func log(id: UUID, message: String) {}
        func complete(id: UUID, detail: String) { lock.withLock { completed += 1 } }
        func fail(id: UUID, detail: String, error: String) { lock.withLock { failed += 1 } }
    }
}
