import XCTest
@testable import LungfishWorkflow

final class DependencyPlannerTests: XCTestCase {
    private func manifest(set: String = "2026.2",
                          tools: [(env: String, spec: String)] = [("samtools", "bioconda::samtools=1.24=h36b3a25_1")],
                          packTools: [(pack: String, env: String, spec: String)] = [("read-mapping", "minimap2", "bioconda::minimap2=2.31=h6bd33b9_0")],
                          databases: [DatabaseSpec] = []) -> ManagedToolLock {
        ManagedToolLock(
            packID: "lungfish-tools", displayName: "T", version: "0",
            tools: tools.map { ManagedToolLock.ToolSpec(id: $0.env, environment: $0.env, packageSpec: $0.spec, executables: [$0.env], version: CondaSpec(spec: $0.spec)!.version) },
            managedData: [], dependencySet: set,
            packTools: packTools.map { PackToolSpec(packID: $0.pack, toolID: $0.env, environment: $0.env, packageSpec: $0.spec, executables: [$0.env], version: CondaSpec(spec: $0.spec)!.version, license: nil, sourceUrl: nil) },
            pipelines: [PipelineSpec(id: "taxtriage", repository: "r", revision: "abc", releaseVersion: "v1")],
            databases: databases,
            bootstrap: BootstrapSpec(micromamba: MicromambaSpec(version: "2.9.0-0", sha256: nil)))
    }
    private func meta(_ name: String, _ v: String, _ b: String) -> CondaMetaPackage { .init(name: name, version: v, build: b, subdir: "osx-arm64", channel: nil) }
    private func inputs(_ m: ManagedToolLock, receipt: DependencyReceipt = .empty(), envs: [String: [CondaMetaPackage]] = [:],
                        packs: Set<String> = [], regDB: [String: String] = [:], metaDB: [String: String] = [:], mm: String? = "2.9.0-0") -> DependencyPlannerInputs {
        .init(manifest: m, receipt: receipt, installedEnvironments: envs, installedPackIDs: packs,
              registryDatabaseVersions: regDB, metagenomicsDatabaseVersions: metaDB, installedMicromambaVersion: mm, estimatedEnvBytes: { _ in 100 })
    }

    func testFreshInstallPlansRequiredToolsOnly() {
        let plan = DependencyPlanner.plan(inputs(manifest()))
        XCTAssertEqual(plan.installEnvironments.map(\.environment), ["samtools"])
        XCTAssertTrue(plan.installEnvironments[0].isRequired)
        XCTAssertTrue(plan.reinstallEnvironments.isEmpty)     // minimap2 pack not installed -> not planned
        XCTAssertTrue(plan.hasRequiredWork)
    }

    func testNoOpWhenReceiptAndDiskMatchManifest() {
        var r = DependencyReceipt.empty(); r.dependencySet = "2026.2"
        r.environments["samtools"] = .init(packageSpec: "bioconda::samtools=1.24=h36b3a25_1", packID: "lungfish-tools", installedAt: Date(), state: .installed)
        let plan = DependencyPlanner.plan(inputs(manifest(), receipt: r, envs: ["samtools": [meta("samtools", "1.24", "h36b3a25_1")]]))
        XCTAssertTrue(plan.isEmpty, "\(plan)")
    }

    func testBuildStringOnlyChangeTriggersReinstall() {
        var r = DependencyReceipt.empty()
        r.environments["samtools"] = .init(packageSpec: "bioconda::samtools=1.24=h36b3a25_0", packID: "lungfish-tools", installedAt: Date(), state: .installed)
        let plan = DependencyPlanner.plan(inputs(manifest(), receipt: r, envs: ["samtools": [meta("samtools", "1.24", "h36b3a25_0")]]))
        XCTAssertEqual(plan.reinstallEnvironments.map(\.environment), ["samtools"])
        XCTAssertEqual(plan.reinstallEnvironments[0].reason, .buildChanged)
    }

    func testMetadataMismatchWinsOverReceipt() {
        // Receipt claims 1.24 but conda-meta says 1.23.1 (e.g. user tampered): plan reinstall.
        var r = DependencyReceipt.empty()
        r.environments["samtools"] = .init(packageSpec: "bioconda::samtools=1.24=h36b3a25_1", packID: "lungfish-tools", installedAt: Date(), state: .installed)
        let plan = DependencyPlanner.plan(inputs(manifest(), receipt: r, envs: ["samtools": [meta("samtools", "1.23.1", "hc612e98_0")]]))
        XCTAssertEqual(plan.reinstallEnvironments.first?.reason, .metadataMismatch)
    }

    func testRetiredNamedEnvIsRemovedAndHexEnvsIgnored() {
        let plan = DependencyPlanner.plan(inputs(manifest(), envs: [
            "samtools": [meta("samtools", "1.24", "h36b3a25_1")],
            "trim_galore": [meta("trim-galore", "2.3.0", "h48b4a6d_0")],
            "env-e09e297bc7c40f8b3a57d80c8b5390c6": [meta("python", "3.10", "x")],
        ]))
        XCTAssertEqual(plan.removeEnvironments, ["trim_galore"])
    }

    func testInstalledOptionalPackIsReinstalledWhenSpecChanges() {
        let plan = DependencyPlanner.plan(inputs(manifest(), envs: [
            "samtools": [meta("samtools", "1.24", "h36b3a25_1")],
            "minimap2": [meta("minimap2", "2.30", "hba9b596_0")],
        ], packs: ["read-mapping"]))
        XCTAssertEqual(plan.reinstallEnvironments.map(\.environment), ["minimap2"])
        XCTAssertFalse(plan.reinstallEnvironments[0].isRequired)
        XCTAssertFalse(plan.hasRequiredWork)
    }

    func testDatabaseAdvisoryVsRequired() {
        let dbs = [
            DatabaseSpec(id: "human-scrubber", tool: "sra-human-scrubber", displayName: "HS", version: "20260706v2", url: "u", filename: "f", md5: nil, sha256: nil, md5Sidecar: true, indexFormat: nil, minimumToolVersion: nil, sizeBytes: 5, sizeOnDisk: nil, recommendedRAM: nil, description: nil, releaseDate: nil, sourceUrl: nil, releasesUrl: nil, updatePolicy: nil, collection: nil),
            DatabaseSpec(id: "deacon-panhuman", tool: "deacon", displayName: "PH", version: "panhuman-2", url: nil, filename: "f2", md5: nil, sha256: nil, md5Sidecar: nil, indexFormat: 4, minimumToolVersion: nil, sizeBytes: 7, sizeOnDisk: nil, recommendedRAM: nil, description: nil, releaseDate: nil, sourceUrl: nil, releasesUrl: nil, updatePolicy: .required, collection: nil),
            DatabaseSpec(id: "kraken2-viral", tool: "kraken2", displayName: "Viral", version: "20260626", url: "u3", filename: nil, md5: nil, sha256: nil, md5Sidecar: nil, indexFormat: nil, minimumToolVersion: nil, sizeBytes: 9, sizeOnDisk: nil, recommendedRAM: nil, description: nil, releaseDate: nil, sourceUrl: nil, releasesUrl: nil, updatePolicy: nil, collection: "viral"),
        ]
        let plan = DependencyPlanner.plan(inputs(manifest(databases: dbs), envs: ["samtools": [meta("samtools", "1.24", "h36b3a25_1")]],
                                                 regDB: ["human-scrubber": "20250916v2", "deacon-panhuman": "panhuman-1"], metaDB: ["kraken2-viral": "20240904"]))
        XCTAssertEqual(Set(plan.databaseUpdates.map(\.id)), ["human-scrubber", "deacon-panhuman", "kraken2-viral"])
        XCTAssertEqual(plan.databaseUpdates.first { $0.id == "deacon-panhuman" }?.policy, .required)
        XCTAssertEqual(plan.databaseUpdates.first { $0.id == "kraken2-viral" }?.managedBy, .metagenomicsRegistry)
        XCTAssertTrue(plan.hasRequiredWork)
        XCTAssertEqual(plan.estimatedDownloadBytes, 5 + 7 + 9)
        // Not-installed databases are never planned.
        XCTAssertFalse(plan.databaseUpdates.contains { $0.id == "kraken2-standard" })
    }

    func testEnvironmentWithoutReadableMetadataIsReinstalled() {
        // Env directory exists but conda-meta yielded nothing: the install cannot be confirmed.
        var r = DependencyReceipt.empty()
        r.environments["samtools"] = .init(packageSpec: "bioconda::samtools=1.24=h36b3a25_1", packID: "lungfish-tools", installedAt: Date(), state: .installed)
        let plan = DependencyPlanner.plan(inputs(manifest(), receipt: r, envs: ["samtools": []]))
        XCTAssertEqual(plan.reinstallEnvironments.map(\.environment), ["samtools"])
        XCTAssertEqual(plan.reinstallEnvironments[0].reason, .metadataMismatch)
    }

    func testReceiptStuckPendingIsReinstalledEvenWhenDiskMatches() {
        // Disk satisfies the manifest, but the recorded install never reached .installed.
        var r = DependencyReceipt.empty()
        r.environments["samtools"] = .init(packageSpec: "bioconda::samtools=1.24=h36b3a25_1", packID: "lungfish-tools", installedAt: Date(), state: .pending)
        let plan = DependencyPlanner.plan(inputs(manifest(), receipt: r, envs: ["samtools": [meta("samtools", "1.24", "h36b3a25_1")]]))
        XCTAssertEqual(plan.reinstallEnvironments.map(\.environment), ["samtools"])
        XCTAssertEqual(plan.reinstallEnvironments[0].reason, .metadataMismatch)
    }

    func testPipelineNeverPrefetchedIsNotPlanned() {
        // No receipt entry means "not prefetched yet", which Nextflow resolves on first run --
        // only a recorded revision that drifted from the pin is planned.
        let plan = DependencyPlanner.plan(inputs(manifest(), envs: ["samtools": [meta("samtools", "1.24", "h36b3a25_1")]]))
        XCTAssertTrue(plan.pipelinePrefetch.isEmpty)
    }

    func testBootstrapAndPipelineChanges() {
        var r = DependencyReceipt.empty(); r.pipelines["taxtriage"] = .init(revision: "old", prefetchedAt: nil)
        let plan = DependencyPlanner.plan(inputs(manifest(), receipt: r, envs: ["samtools": [meta("samtools", "1.24", "h36b3a25_1")]], mm: "2.0.5-0"))
        XCTAssertEqual(plan.bootstrapUpdate?.targetVersion, "2.9.0-0")
        XCTAssertEqual(plan.pipelinePrefetch.map(\.targetRevision), ["abc"])
    }
}
