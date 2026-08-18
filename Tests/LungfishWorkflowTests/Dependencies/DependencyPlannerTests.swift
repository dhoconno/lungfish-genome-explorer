import XCTest
@testable import LungfishWorkflow

final class DependencyPlannerTests: XCTestCase {
    private func manifest(set: String = "2026.2",
                          tools: [(env: String, spec: String)] = [("samtools", "bioconda::samtools=1.24=h36b3a25_1")],
                          packTools: [(pack: String, env: String, spec: String)] = [("read-mapping", "minimap2", "bioconda::minimap2=2.31=h6bd33b9_0")],
                          databases: [DatabaseSpec] = [],
                          retired: [String] = []) -> ManagedToolLock {
        ManagedToolLock(
            packID: "lungfish-tools", displayName: "T", version: "0",
            tools: tools.map { ManagedToolLock.ToolSpec(id: $0.env, environment: $0.env, packageSpec: $0.spec, executables: [$0.env], version: CondaSpec(spec: $0.spec)!.version) },
            managedData: [], dependencySet: set,
            packTools: packTools.map { PackToolSpec(packID: $0.pack, toolID: $0.env, environment: $0.env, packageSpec: $0.spec, executables: [$0.env], version: CondaSpec(spec: $0.spec)!.version, license: nil, sourceUrl: nil) },
            pipelines: [PipelineSpec(id: "taxtriage", repository: "r", revision: "abc", releaseVersion: "v1")],
            databases: databases,
            bootstrap: BootstrapSpec(micromamba: MicromambaSpec(version: "2.9.0-0", sha256: nil)),
            retiredEnvironments: retired)
    }
    private func meta(_ name: String, _ v: String, _ b: String) -> CondaMetaPackage { .init(name: name, version: v, build: b, subdir: "osx-arm64", channel: nil) }
    private func inputs(_ m: ManagedToolLock, receipt: DependencyReceipt = .empty(), envs: [String: [CondaMetaPackage]] = [:],
                        packs: Set<String> = [], regDB: [String: String] = [:], metaDB: [String: String] = [:], mm: String? = "2.9.0-0",
                        known: Set<String> = []) -> DependencyPlannerInputs {
        .init(manifest: m, receipt: receipt, installedEnvironments: envs, installedPackIDs: packs,
              registryDatabaseVersions: regDB, metagenomicsDatabaseVersions: metaDB, installedMicromambaVersion: mm, estimatedEnvBytes: { _ in 100 },
              knownEnvironmentNames: known)
    }

    /// A receipt entry marking `env` as one Lungfish installed (so it may be swept when dropped).
    private func lungfishOwned(_ env: String, spec: String) -> DependencyReceipt.EnvironmentEntry {
        .init(packageSpec: spec, packID: "lungfish-tools", installedAt: Date(), state: .installed)
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
        // trim_galore is retired because our own receipt shows Lungfish installed it.
        var r = DependencyReceipt.empty()
        r.environments["trim_galore"] = lungfishOwned("trim_galore", spec: "bioconda::trim-galore=2.3.0=h48b4a6d_0")
        let plan = DependencyPlanner.plan(inputs(manifest(), receipt: r, envs: [
            "samtools": [meta("samtools", "1.24", "h36b3a25_1")],
            "trim_galore": [meta("trim-galore", "2.3.0", "h48b4a6d_0")],
            "env-e09e297bc7c40f8b3a57d80c8b5390c6": [meta("python", "3.10", "x")],
        ]))
        XCTAssertEqual(plan.removeEnvironments, ["trim_galore"])
    }

    func testManifestRetiredEnvIsRemovedWithoutReceiptEntry() {
        // The sweep tooling names a dropped tool in retiredEnvironments; that alone licenses removal.
        let plan = DependencyPlanner.plan(inputs(manifest(retired: ["trimmomatic"]), envs: [
            "samtools": [meta("samtools", "1.24", "h36b3a25_1")],
            "trimmomatic": [meta("trimmomatic", "0.39", "hdfd78af_2")],
        ]))
        XCTAssertEqual(plan.removeEnvironments, ["trimmomatic"])
    }

    func testUserCreatedEnvIsNeverRemoved() {
        // Unknown to the manifest AND absent from the receipt: the user made it, so leave it alone.
        let plan = DependencyPlanner.plan(inputs(manifest(), envs: [
            "samtools": [meta("samtools", "1.24", "h36b3a25_1")],
            "pbaa-env": [meta("pbaa", "1.0.3", "h9ee0642_0")],
            "test-env": [meta("python", "3.12", "h1234567_0")],
        ]))
        XCTAssertTrue(plan.removeEnvironments.isEmpty, "\(plan.removeEnvironments)")
    }

    func testKnownEnvironmentNameIsNeverRemovedEvenWhenRetired() {
        // Another part of the app still owns this environment; knownEnvironmentNames wins.
        let plan = DependencyPlanner.plan(inputs(manifest(retired: ["fastqc"]), envs: [
            "samtools": [meta("samtools", "1.24", "h36b3a25_1")],
            "fastqc": [meta("fastqc", "0.12.1", "hdfd78af_0")],
        ], known: ["fastqc"]))
        XCTAssertTrue(plan.removeEnvironments.isEmpty, "\(plan.removeEnvironments)")
    }

    func testHiddenEntriesAreNeverRemoved() {
        // `.env-<hex>.lock` is a bookkeeping file sitting beside the envs, not an environment.
        var r = DependencyReceipt.empty()
        r.environments[".env-e09e297bc7c40f8b3a57d80c8b5390c6.lock"] = lungfishOwned(".lock", spec: "x::y=1")
        let plan = DependencyPlanner.plan(inputs(manifest(retired: [".env-e09e297bc7c40f8b3a57d80c8b5390c6.lock"]), receipt: r, envs: [
            "samtools": [meta("samtools", "1.24", "h36b3a25_1")],
            ".env-e09e297bc7c40f8b3a57d80c8b5390c6.lock": [],
        ]))
        XCTAssertTrue(plan.removeEnvironments.isEmpty, "\(plan.removeEnvironments)")
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

    // MARK: - Bootstrap version comparison

    /// The probe prints the upstream version; the manifest pins the conda build. Those are the
    /// same micromamba, so a current machine must not be told to reinstall it forever.
    private func bootstrapManifest(target: String) -> ManagedToolLock {
        ManagedToolLock(
            packID: "lungfish-tools", displayName: "T", version: "0",
            tools: [], managedData: [], dependencySet: "2026.2", packTools: [],
            pipelines: [], databases: [],
            bootstrap: BootstrapSpec(micromamba: MicromambaSpec(version: target, sha256: nil)),
            retiredEnvironments: [])
    }

    func testBootstrapNotPlannedWhenProbeVersionMatchesPinnedBuild() {
        // The real shapes: `micromamba --version` says "2.0.5", the manifest pins "2.0.5-0".
        let plan = DependencyPlanner.plan(inputs(bootstrapManifest(target: "2.0.5-0"), mm: "2.0.5"))
        XCTAssertNil(plan.bootstrapUpdate, "a build suffix on the pin is not a version difference")
        XCTAssertTrue(plan.isEmpty)
    }

    func testBootstrapPlannedWhenProbeVersionIsGenuinelyOlder() {
        let plan = DependencyPlanner.plan(inputs(bootstrapManifest(target: "2.9.0-0"), mm: "2.0.5"))
        XCTAssertEqual(plan.bootstrapUpdate?.currentVersion, "2.0.5")
        XCTAssertEqual(plan.bootstrapUpdate?.targetVersion, "2.9.0-0")
    }

    func testBootstrapPlannedWhenMicromambaIsMissing() {
        let plan = DependencyPlanner.plan(inputs(bootstrapManifest(target: "2.0.5-0"), mm: nil))
        XCTAssertNil(plan.bootstrapUpdate?.currentVersion)
        XCTAssertEqual(plan.bootstrapUpdate?.targetVersion, "2.0.5-0")
    }

    func testBootstrapComparisonNormalisesOnlyNumericBuildSuffixes() {
        XCTAssertFalse(DependencyPlanner.needsBootstrapUpdate(installed: "2.0.5", target: "2.0.5-0"))
        XCTAssertFalse(DependencyPlanner.needsBootstrapUpdate(installed: "2.0.5", target: "2.0.5"))
        XCTAssertFalse(DependencyPlanner.needsBootstrapUpdate(installed: "2.0.5", target: "2.0.5-12"))
        XCTAssertTrue(DependencyPlanner.needsBootstrapUpdate(installed: "2.0.5", target: "2.9.0-0"))
        XCTAssertTrue(DependencyPlanner.needsBootstrapUpdate(installed: nil, target: "2.0.5-0"))
        XCTAssertTrue(DependencyPlanner.needsBootstrapUpdate(installed: "", target: "2.0.5-0"))
        // A dash that is part of the version itself must not be stripped away.
        XCTAssertTrue(DependencyPlanner.needsBootstrapUpdate(installed: "2.0.5", target: "2.0.5-rc1"))
    }

    // MARK: - Pack installation is read from the pack's own pins

    /// A pack is "installed" only on the evidence of the environments the manifest pins to it.
    /// Sharing a general-purpose tool with another pack must not license planning its tools.
    func testSharedEnvironmentDoesNotLicenseAnotherPack() {
        let sharedManifest = manifest(
            tools: [("samtools", "bioconda::samtools=1.24=h36b3a25_1")],
            packTools: [
                ("read-mapping", "minimap2", "bioconda::minimap2=2.31=h6bd33b9_0"),
                ("wastewater-surveillance", "freyja", "bioconda::freyja=2.0.0=pyhdfd78af_0"),
            ]
        )
        let onDisk: Set<String> = ["minimap2"]
        let packs = ReconcilerServices.installedPackIDs(
            manifest: sharedManifest,
            environmentExists: { onDisk.contains($0) }
        )

        XCTAssertTrue(packs.contains("read-mapping"), "its own pinned environment is present")
        XCTAssertFalse(
            packs.contains("wastewater-surveillance"),
            "minimap2 belongs to read-mapping; it must not make wastewater-surveillance look installed"
        )

        // And the plan built from that reading leaves freyja alone.
        let plan = DependencyPlanner.plan(inputs(
            sharedManifest,
            envs: ["samtools": [meta("samtools", "1.24", "h36b3a25_1")], "minimap2": [meta("minimap2", "2.31", "h6bd33b9_0")]],
            packs: packs
        ))
        XCTAssertFalse(
            plan.installEnvironments.contains { $0.environment == "freyja" }
                || plan.reinstallEnvironments.contains { $0.environment == "freyja" },
            "an uninstalled pack's tools are never planned: \(plan)"
        )
    }

    func testPackWithNoPinnedEnvironmentsIsNeverConsideredInstalled() {
        // `illumina-qc` pins no packTools in this fixture, so there is no evidence to read.
        let packs = ReconcilerServices.installedPackIDs(
            manifest: manifest(packTools: []),
            environmentExists: { _ in true }
        )
        XCTAssertFalse(packs.contains("illumina-qc"))
    }

    func testRequiredPackIsAlwaysInstalled() {
        let packs = ReconcilerServices.installedPackIDs(
            manifest: manifest(packTools: []),
            environmentExists: { _ in false }
        )
        XCTAssertTrue(
            packs.contains("lungfish-tools"),
            "the required pack is in scope whether or not its environments exist"
        )
    }
}
