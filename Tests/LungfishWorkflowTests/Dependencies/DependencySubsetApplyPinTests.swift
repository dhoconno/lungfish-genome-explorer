// DependencySubsetApplyPinTests.swift - What apply does with a chosen set of plan items
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A52 M1 (family L10, QA 1). The Update Tools sheet applies a `PlanSelection` it
// builds from the user's checkboxes, and lane A52 adds `tools update --only <id>` so the same
// selection can run from the command. This suite pins what `DependencyReconciler.apply` does
// today with a chosen set of items, so the command and the route are held to it: which items run,
// in which order, what always runs whatever the selection says, what a retired environment's
// removal depends on, and what the run records. It changes no source and passes at the base.

import XCTest
@testable import LungfishWorkflow

final class DependencySubsetApplyPinTests: XCTestCase {
    private actor Order {
        private(set) var entries: [String] = []
        func record(_ entry: String) { entries.append(entry) }
    }

    private func tmpRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lge-subset-\(UUID().uuidString)")
    }

    private func manifest() -> ManagedToolLock {
        ManagedToolLock(
            packID: "lungfish-tools", displayName: "T", version: "0",
            tools: [.init(
                id: "samtools", environment: "samtools",
                packageSpec: "bioconda::samtools=1.24=h36b3a25_1",
                executables: ["samtools"], version: "1.24"
            )],
            managedData: [], dependencySet: "2026.2",
            pipelines: [],
            databases: [],
            bootstrap: BootstrapSpec(micromamba: .init(version: "2.9.0-0", sha256: nil))
        )
    }

    private func environment(_ name: String, required: Bool, reinstall: Bool = false) -> ReconciliationPlan.EnvironmentChange {
        .init(
            environment: name, packID: "pack-\(name)",
            currentSpec: reinstall ? "bioconda::\(name)=1.0=h0" : nil,
            targetSpec: "bioconda::\(name)=2.0=h1",
            reason: reinstall ? .specChanged : .missing,
            isRequired: required
        )
    }

    private func database(
        _ id: String, policy: DatabaseUpdatePolicy, managedBy: ReconciliationPlan.DatabaseManager
    ) -> ReconciliationPlan.DatabaseChange {
        .init(
            id: id, displayName: id, installedVersion: "1", targetVersion: "2",
            policy: policy, estimatedBytes: 10, managedBy: managedBy
        )
    }

    /// Two required and three optional environments (one a reinstall), three databases, two
    /// retired environments, a pipeline and a micromamba upgrade.
    private func plan() -> ReconciliationPlan {
        ReconciliationPlan(
            installEnvironments: [
                environment("req-a", required: true),
                environment("req-z", required: true),
                environment("opt-b", required: false),
                environment("opt-d", required: false),
            ],
            reinstallEnvironments: [environment("opt-c", required: false, reinstall: true)],
            removeEnvironments: ["retired-x", "retired-y"],
            databaseUpdates: [
                database("db-required", policy: .required, managedBy: .databaseRegistry),
                database("db-advisory", policy: .advisory, managedBy: .metagenomicsRegistry),
                database("db-other", policy: .advisory, managedBy: .databaseRegistry),
            ],
            pipelinePrefetch: [.init(id: "pipeline-p", currentRevision: nil, targetRevision: "1.0")],
            bootstrapUpdate: .init(currentVersion: "2.8.0-0", targetVersion: "2.9.0-0"),
            targetDependencySet: "2026.2",
            estimatedDownloadBytes: 30
        )
    }

    private func reconciler(root: URL, order: Order) -> DependencyReconciler {
        var services = ReconcilerServices.live(condaManager: .shared, storageRoot: FileManager.default.temporaryDirectory)
        services.installBootstrap = { version in await order.record("bootstrap:\(version)") }
        services.createEnvironment = { name, _, _ in await order.record("create:\(name)") }
        services.removeEnvironment = { name in await order.record("remove:\(name)") }
        services.smokeTest = { _ in }
        services.installRegistryDatabase = { id, _ in
            await order.record("database:\(id)")
            return URL(fileURLWithPath: "/x")
        }
        services.updateMetagenomicsDatabase = { id, _ in await order.record("metagenomics:\(id)") }
        services.prefetchPipeline = { id, _ in await order.record("prefetch:\(id)") }
        services.listEnvironments = { ["opt-c": [], "retired-x": [], "retired-y": []] }
        services.installedPackIDs = { [] }
        services.registryDatabaseVersions = { [:] }
        services.metagenomicsDatabaseVersions = { [:] }
        services.installedMicromambaVersion = { "2.8.0" }
        return DependencyReconciler(
            manifest: manifest(), storageRoot: root, services: services,
            appVersion: "2026.10.0", operationCenter: nil
        )
    }

    func testAChosenSetRunsOnlyTheChosenItemsRequiredFirstThenByName() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let order = Order()
        let selection = PlanSelection(
            environments: ["req-a", "req-z", "opt-c", "opt-b"],
            databases: ["db-required", "db-advisory"],
            includeRemovals: false
        )

        let result = try await reconciler(root: root, order: order).apply(plan(), selection: selection) { _, _, _ in }

        let entries = await order.entries
        XCTAssertEqual(entries, [
            "bootstrap:2.9.0-0",
            "create:req-a", "create:req-z",
            "create:opt-b",
            "remove:opt-c", "create:opt-c",
            "database:db-required", "metagenomics:db-advisory",
            "prefetch:pipeline-p",
        ], "an unchosen environment, an unchosen database and every removal stay untouched")
        XCTAssertEqual(
            result.succeeded,
            ["micromamba", "req-a", "req-z", "opt-b", "opt-c", "db-required", "db-advisory", "pipeline-p"]
        )
        XCTAssertTrue(result.failed.isEmpty)
    }

    func testTheBootstrapAndThePipelinePrefetchRunWhateverTheSelectionHolds() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let order = Order()
        let selection = PlanSelection(environments: [], databases: [], includeRemovals: false)

        _ = try await reconciler(root: root, order: order).apply(plan(), selection: selection) { _, _, _ in }

        let entries = await order.entries
        XCTAssertEqual(entries, ["bootstrap:2.9.0-0", "prefetch:pipeline-p"])
    }

    func testIncludingRemovalsRemovesEveryRetiredEnvironmentOfThePlan() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let order = Order()
        let selection = PlanSelection(environments: ["req-a", "req-z"], databases: [], includeRemovals: true)

        _ = try await reconciler(root: root, order: order).apply(plan(), selection: selection) { _, _, _ in }

        let entries = await order.entries
        XCTAssertEqual(entries.filter { $0.hasPrefix("remove:") }, ["remove:retired-x", "remove:retired-y"])
    }

    func testASetThatLeavesRequiredWorkOutStillStampsTheDependencySet() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let order = Order()
        // `req-z` is required and is not chosen. The stamp waits only for a required item that
        // ran and failed, so the receipt claims the set is current although `req-z` never ran.
        // The Update Tools sheet cannot reach this state, because its selection always folds the
        // required work back in, and `tools update --only` has to do the same.
        let selection = PlanSelection(environments: ["req-a", "opt-b"], databases: [], includeRemovals: false)

        _ = try await reconciler(root: root, order: order).apply(plan(), selection: selection) { _, _, _ in }

        let saved = try XCTUnwrap(try DependencyReceiptStore(storageRoot: root).load())
        XCTAssertEqual(saved.dependencySet, "2026.2")
        XCTAssertNil(saved.environments["req-z"])
        XCTAssertEqual(saved.environments["opt-b"]?.state, .installed)
    }

    func testTheRunRecordsOneStepForEveryAttemptedItem() async throws {
        let root = tmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let order = Order()
        let selection = PlanSelection(
            environments: ["req-a", "opt-b"], databases: ["db-advisory"], includeRemovals: false
        )

        _ = try await reconciler(root: root, order: order).apply(plan(), selection: selection) { _, _, _ in }

        let directory = root.appendingPathComponent("provenance/dependencies", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".lungfish-provenance.json") }
        XCTAssertEqual(files.count, 1, "one record for the run")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(
            ProvenanceEnvelope.self, from: Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(files.first)))
        )
        XCTAssertEqual(envelope.workflowName, "dependency-reconcile")
        XCTAssertEqual(envelope.steps.map(\.toolName), ["micromamba", "req-a", "opt-b", "db-advisory"])
        XCTAssertEqual(envelope.exitStatus, 0)
    }
}
