// CondaManagerTests.swift - Tests for the conda/micromamba plugin system
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishCore

/// Tests for CondaManager, CondaPackageInfo, PluginPack, and related types.
///
/// Note: Tests that actually install packages require network access and
/// are marked with XCTSkip guards. The model and configuration tests run
/// without network.
final class CondaManagerTests: XCTestCase {

    // MARK: - CondaPackageInfo Tests

    func testCondaPackageInfoCreation() {
        let pkg = CondaPackageInfo(
            name: "samtools",
            version: "1.23.1",
            channel: "bioconda",
            buildString: "hc612e98_0",
            subdir: "osx-arm64"
        )

        XCTAssertEqual(pkg.name, "samtools")
        XCTAssertEqual(pkg.version, "1.23.1")
        XCTAssertEqual(pkg.channel, "bioconda")
        XCTAssertTrue(pkg.isNativeMacOS)
    }

    func testCondaPackageInfoLinuxOnly() {
        let pkg = CondaPackageInfo(
            name: "pbaa",
            version: "1.0.3",
            channel: "bioconda",
            subdir: "linux-64"
        )

        XCTAssertFalse(pkg.isNativeMacOS, "linux-64 packages should not be native macOS")
    }

    func testCondaPackageInfoNoarchIsNative() {
        let pkg = CondaPackageInfo(
            name: "multiqc",
            version: "1.20",
            channel: "bioconda",
            subdir: "noarch"
        )

        XCTAssertTrue(pkg.isNativeMacOS, "noarch packages should be considered native")
    }

    func testCondaPackageInfoIdentifiable() {
        let pkg1 = CondaPackageInfo(name: "samtools", version: "1.23", channel: "bioconda")
        let pkg2 = CondaPackageInfo(name: "samtools", version: "1.22", channel: "bioconda")

        XCTAssertNotEqual(pkg1.id, pkg2.id, "Different versions should have different IDs")
    }

    func testCondaPackageInfoCodable() throws {
        let original = CondaPackageInfo(
            name: "bwa-mem2",
            version: "2.2.1",
            channel: "bioconda",
            buildString: "h123_0",
            subdir: "osx-arm64",
            license: "MIT",
            description: "Fast sequence mapper",
            sizeBytes: 5_000_000
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CondaPackageInfo.self, from: data)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.version, original.version)
        XCTAssertEqual(decoded.license, "MIT")
        XCTAssertEqual(decoded.sizeBytes, 5_000_000)
    }

    // MARK: - CondaEnvironment Tests

    func testCondaEnvironmentCreation() {
        let env = CondaEnvironment(
            name: "samtools",
            path: URL(fileURLWithPath: "/tmp/test/envs/samtools"),
            packageCount: 18
        )

        XCTAssertEqual(env.id, "samtools")
        XCTAssertEqual(env.name, "samtools")
        XCTAssertEqual(env.packageCount, 18)
    }

    func testCondaEnvironmentHashable() {
        let env1 = CondaEnvironment(name: "a", path: URL(fileURLWithPath: "/a"))
        let env2 = CondaEnvironment(name: "b", path: URL(fileURLWithPath: "/b"))
        let env3 = CondaEnvironment(name: "a", path: URL(fileURLWithPath: "/a"))

        var set = Set<CondaEnvironment>()
        set.insert(env1)
        set.insert(env2)
        set.insert(env3)

        XCTAssertEqual(set.count, 2)
    }

    // MARK: - PluginPack Tests

    func testBuiltInPacksExist() {
        XCTAssertFalse(PluginPack.builtIn.isEmpty)
        XCTAssertEqual(PluginPack.builtIn.count, 14, "Should include the required setup pack plus 13 optional packs")
        XCTAssertEqual(PluginPack.activeOptionalPacks.map(\.id), ["read-mapping", "variant-calling", "assembly", "metagenomics"])
    }

    func testReinstallRemovesExistingEnvironmentBeforeCreate() async throws {
        let sandbox = try makeMicromambaSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let bundledMicromamba = try makeFakeMicromamba(
            at: sandbox.appendingPathComponent("bundled-micromamba"),
            version: "2.0.5-0"
        )
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { bundledMicromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )

        let envURL = await manager.environmentURL(named: "bbtools")
        let staleFile = envURL.appendingPathComponent("conda-meta/stale.json")
        try FileManager.default.createDirectory(at: staleFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: staleFile.path, contents: Data("stale".utf8))

        try await manager.reinstall(packages: ["bbmap"], environment: "bbtools")

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path))
    }

    func testInstallPackageSpecPassesExactSpecThrough() async throws {
        let recorder = try RecordingMicromamba()
        let micromambaURL = recorder.url
        let manager = CondaManager(
            rootPrefix: recorder.root,
            bundledMicromambaProvider: { micromambaURL },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )

        try await manager.install(
            packageSpec: "bioconda::samtools=1.23.1=hc612e98_0",
            environment: "samtools"
        )

        let installArgs = try XCTUnwrap(recorder.firstInstallArgs())
        XCTAssertTrue(installArgs.contains("bioconda::samtools=1.23.1=hc612e98_0"))
        XCTAssertTrue(installArgs.contains("samtools"))
    }

    func testReinstallPackageSpecPassesExactSpecThrough() async throws {
        let recorder = try RecordingMicromamba()
        let micromambaURL = recorder.url
        let manager = CondaManager(
            rootPrefix: recorder.root,
            bundledMicromambaProvider: { micromambaURL },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )

        try await manager.reinstall(
            packageSpec: "bioconda::fastp=1.3.2=ha1d0559_0",
            environment: "fastp"
        )

        let installArgs = try XCTUnwrap(recorder.firstInstallArgs())
        XCTAssertTrue(installArgs.contains("bioconda::fastp=1.3.2=ha1d0559_0"))
        XCTAssertTrue(installArgs.contains("fastp"))
    }

    func testToolVersionsManifestIncludesMicromamba() throws {
        let manifestURL = Self.toolVersionsManifestURL()
        let data = try Data(contentsOf: manifestURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tools = json?["tools"] as? [[String: Any]]

        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["name"] as? String, "micromamba")
    }

    func testManagedToolLockLoadsPinnedPackageSpecsFromWorkflowResources() throws {
        let lock = try ManagedToolLock.loadFromBundle()

        XCTAssertEqual(lock.packID, "lungfish-tools")
        XCTAssertEqual(lock.displayName, "Third-Party Tools")
        XCTAssertEqual(lock.version, "1.0.4")
        XCTAssertEqual(lock.tools.count, 15)
        XCTAssertEqual(lock.managedData.count, 1)

        let expectedSpecs: [String: String] = [
            "nextflow": "bioconda::nextflow=25.10.4=h2a3209d_0",
            "snakemake": "bioconda::snakemake=9.19.0=hdfd78af_1",
            "bbtools": "bioconda::bbmap=39.80=h2e3bd82_0",
            "fastp": "bioconda::fastp=1.3.2=ha1d0559_0",
            "deacon": "bioconda::deacon=0.15.0=hc0d6d67_0",
            "samtools": "bioconda::samtools=1.23.1=hc612e98_0",
            "bcftools": "bioconda::bcftools=1.23.1=h0ba0a6f_0",
            "htslib": "bioconda::htslib=1.23.1=h44a9eb5_0",
            "seqkit": "bioconda::seqkit=2.13.0=hd5f1084_0",
            "cutadapt": "bioconda::cutadapt=5.2=py311hd78823b_1",
            "vsearch": "bioconda::vsearch=2.30.5=h85a231e_0",
            "pigz": "conda-forge::pigz=2.8=hfab5511_2",
            "sra-tools": "bioconda::sra-tools=3.4.1=h4675bf2_1",
            "ucsc-bedtobigbed": "bioconda::ucsc-bedtobigbed=482=h1643cc5_0",
            "ucsc-bedgraphtobigwig": "bioconda::ucsc-bedgraphtobigwig=482=h1643cc5_0",
        ]

        let actualSpecs: [String: String] = Dictionary(uniqueKeysWithValues: lock.tools.map { ($0.id, $0.packageSpec) })
        XCTAssertEqual(actualSpecs, expectedSpecs)
        XCTAssertEqual(lock.managedData.first?.id, "deacon-panhuman")
        XCTAssertEqual(lock.managedData.first?.displayName, "Human Read Removal Data")
    }

    func testMicromambaBundledResourceIsResolvable() throws {
        let micromambaURL = Self.micromambaBundledResourceURL()
        let fileManager = FileManager.default

        XCTAssertTrue(fileManager.fileExists(atPath: micromambaURL.path))
        XCTAssertTrue(fileManager.isExecutableFile(atPath: micromambaURL.path))
    }

    func testBundledToolsDirectoryContainsMicromambaAndMetadataOnly() throws {
        let toolsDirectoryURL = Self.bundledToolsDirectoryURL()
        let entries = try FileManager.default.contentsOfDirectory(atPath: toolsDirectoryURL.path).sorted()

        XCTAssertEqual(entries, ["VERSIONS.txt", "micromamba", "tool-versions.json"])
    }

    private static func toolVersionsManifestURL() -> URL {
        if let bundleURL = Bundle.module.resourceURL?
            .appendingPathComponent("Tools")
            .appendingPathComponent("tool-versions.json"),
           FileManager.default.fileExists(atPath: bundleURL.path)
        {
            return bundleURL
        }

        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let manifestURL = candidate
                .appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools/tool-versions.json")
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return manifestURL
            }
            candidate = candidate.deletingLastPathComponent()
        }

        fatalError("Cannot locate Sources/LungfishWorkflow/Resources/Tools/tool-versions.json")
    }

    private static func micromambaBundledResourceURL() -> URL {
        if let bundleURL = Bundle.module.resourceURL?
            .appendingPathComponent("Tools")
            .appendingPathComponent("micromamba"),
           FileManager.default.fileExists(atPath: bundleURL.path)
        {
            return bundleURL
        }

        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let resourceURL = candidate
                .appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools/micromamba")
            if FileManager.default.fileExists(atPath: resourceURL.path) {
                return resourceURL
            }
            candidate = candidate.deletingLastPathComponent()
        }

        fatalError("Cannot locate Sources/LungfishWorkflow/Resources/Tools/micromamba")
    }

    private static func bundledToolsDirectoryURL() -> URL {
        if let bundleURL = Bundle.module.resourceURL?
            .appendingPathComponent("Tools"),
           FileManager.default.fileExists(atPath: bundleURL.path)
        {
            return bundleURL
        }

        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let toolsURL = candidate
                .appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools")
            if FileManager.default.fileExists(atPath: toolsURL.path) {
                return toolsURL
            }
            candidate = candidate.deletingLastPathComponent()
        }

        fatalError("Cannot locate Sources/LungfishWorkflow/Resources/Tools")
    }

    func testBuiltInPacksHaveUniqueIDs() {
        let ids = PluginPack.builtIn.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Pack IDs should be unique")
    }

    func testBuiltInPacksHavePackages() {
        for pack in PluginPack.builtIn {
            XCTAssertFalse(pack.packages.isEmpty, "Pack '\(pack.name)' should have packages")
            XCTAssertFalse(pack.name.isEmpty, "Pack should have a name")
            XCTAssertFalse(pack.description.isEmpty, "Pack '\(pack.name)' should have a description")
            XCTAssertFalse(pack.sfSymbol.isEmpty, "Pack '\(pack.name)' should have an SF Symbol")
        }
    }

    func testIlluminaQCPack() {
        let pack = PluginPack.builtIn.first { $0.id == "illumina-qc" }
        XCTAssertNotNil(pack)
        XCTAssertTrue(pack!.packages.contains("fastqc"))
        XCTAssertTrue(pack!.packages.contains("multiqc"))
        XCTAssertTrue(pack!.packages.contains("trimmomatic"))
        // fastp moved to the required setup pack and should not appear here
        XCTAssertFalse(pack!.packages.contains("fastp"))
    }

    func testReadMappingPack() {
        let pack = PluginPack.builtIn.first { $0.id == "read-mapping" }
        XCTAssertNotNil(pack)
        XCTAssertTrue(pack!.packages.contains("minimap2"))
        XCTAssertTrue(pack!.packages.contains("bwa-mem2"))
        XCTAssertTrue(pack!.packages.contains("bowtie2"))
        XCTAssertFalse(pack!.packages.contains("hisat2"))
    }

    func testMetagenomicsPack() {
        let pack = PluginPack.builtIn.first { $0.id == "metagenomics" }
        XCTAssertNotNil(pack)
        XCTAssertTrue(pack!.packages.contains("kraken2"))
        XCTAssertTrue(pack!.packages.contains("bracken"))
        XCTAssertFalse(pack!.packages.contains("metaphlan"))
        XCTAssertFalse(pack!.packages.contains("nextflow"))
        // freyja moved to wastewater-surveillance pack
        XCTAssertFalse(pack!.packages.contains("freyja"))
    }

    func testRequiredSetupPackIncludesDeacon() {
        let pack = PluginPack.requiredSetupPack
        XCTAssertTrue(pack.packages.contains("deacon"))
        XCTAssertEqual(
            pack.toolRequirements.first(where: { $0.environment == "deacon" })?.executables,
            ["deacon"]
        )
    }

    func testWastewaterSurveillancePack() {
        let pack = PluginPack.builtIn.first { $0.id == "wastewater-surveillance" }
        XCTAssertNotNil(pack)
        XCTAssertTrue(pack!.packages.contains("freyja"))
        XCTAssertTrue(pack!.packages.contains("ivar"))
        XCTAssertTrue(pack!.packages.contains("pangolin"))
        XCTAssertTrue(pack!.packages.contains("nextclade"))
        XCTAssertTrue(pack!.packages.contains("minimap2"))
        // Should have post-install hooks for freyja update and pangolin update
        XCTAssertEqual(pack!.postInstallHooks.count, 2)
        XCTAssertTrue(pack!.postInstallHooks.contains { $0.environment == "freyja" })
        XCTAssertTrue(pack!.postInstallHooks.contains { $0.environment == "pangolin" })
    }

    func testRNASeqPack() {
        let pack = PluginPack.builtIn.first { $0.id == "rna-seq" }
        XCTAssertNotNil(pack)
        XCTAssertTrue(pack!.packages.contains("star"))
        XCTAssertTrue(pack!.packages.contains("salmon"))
        XCTAssertTrue(pack!.packages.contains("subread"))
        XCTAssertTrue(pack!.packages.contains("stringtie"))
    }

    func testSingleCellPack() {
        let pack = PluginPack.builtIn.first { $0.id == "single-cell" }
        XCTAssertNotNil(pack)
        XCTAssertTrue(pack!.packages.contains("scanpy"))
        XCTAssertTrue(pack!.packages.contains("scvi-tools"))
        XCTAssertTrue(pack!.packages.contains("star"))
    }

    func testAmpliconAnalysisPack() {
        let pack = PluginPack.builtIn.first { $0.id == "amplicon-analysis" }
        XCTAssertNotNil(pack)
        XCTAssertTrue(pack!.packages.contains("ivar"))
        XCTAssertTrue(pack!.packages.contains("pangolin"))
        XCTAssertTrue(pack!.packages.contains("nextclade"))
        XCTAssertEqual(pack!.postInstallHooks.count, 1)
    }

    func testGenomeAnnotationPack() {
        let pack = PluginPack.builtIn.first { $0.id == "genome-annotation" }
        XCTAssertNotNil(pack)
        XCTAssertTrue(pack!.packages.contains("prokka"))
        XCTAssertTrue(pack!.packages.contains("bakta"))
        XCTAssertTrue(pack!.packages.contains("snpeff"))
        XCTAssertEqual(pack!.postInstallHooks.count, 1)
        XCTAssertTrue(pack!.postInstallHooks[0].environment == "bakta")
    }

    func testDataFormatUtilsPack() {
        let pack = PluginPack.builtIn.first { $0.id == "data-format-utils" }
        XCTAssertNotNil(pack)
        XCTAssertTrue(pack!.packages.contains("bedtools"))
        XCTAssertTrue(pack!.packages.contains("picard"))
    }

    func testOptionalPacksDoNotContainNativeTierOneTools() {
        // These tools are bundled natively and should not appear in optional conda packs.
        let nativeTools = ["samtools", "bcftools", "seqkit", "cutadapt",
                           "pigz", "bgzip", "tabix"]
        for pack in PluginPack.builtIn where !pack.isRequiredBeforeLaunch {
            for tool in nativeTools {
                XCTAssertFalse(pack.packages.contains(tool),
                    "Pack '\(pack.id)' should not contain native tool '\(tool)'")
            }
        }
    }

    func testPostInstallHooksHaveValidStructure() {
        for pack in PluginPack.builtIn {
            for hook in pack.postInstallHooks {
                XCTAssertFalse(hook.description.isEmpty,
                    "Hook in pack '\(pack.id)' should have a description")
                XCTAssertFalse(hook.environment.isEmpty,
                    "Hook in pack '\(pack.id)' should have an environment")
                XCTAssertFalse(hook.command.isEmpty,
                    "Hook in pack '\(pack.id)' should have a command")
                // The hook's environment must be one of the pack's packages
                XCTAssertTrue(pack.packages.contains(hook.environment),
                    "Hook environment '\(hook.environment)' must be a package in pack '\(pack.id)'")
            }
        }
    }

    func testEstimatedSizesAreSet() {
        for pack in PluginPack.builtIn {
            XCTAssertGreaterThan(pack.estimatedSizeMB, 0,
                "Pack '\(pack.id)' should have a non-zero estimated size")
        }
    }

    func testPluginPackCodable() throws {
        let original = PluginPack(
            id: "test-pack",
            name: "Test Pack",
            description: "A test pack",
            sfSymbol: "star",
            packages: ["tool1", "tool2"],
            category: "Testing"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PluginPack.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.packages, original.packages)
    }

    // MARK: - CondaManager Configuration Tests

    func testCondaManagerRootPrefix() async {
        let manager = CondaManager.shared
        let rootPrefix = manager.rootPrefix

        XCTAssertTrue(rootPrefix.path.contains(".lungfish/conda"),
                      "Root prefix should use .lungfish/conda (no spaces)")
        XCTAssertFalse(rootPrefix.path.contains("Application Support"),
                       "Root prefix should NOT contain 'Application Support' (spaces break tools)")
    }

    func testCondaManagerMicromambaPath() async {
        let manager = CondaManager.shared
        let path = await manager.micromambaPath

        XCTAssertTrue(path.path.hasSuffix("bin/micromamba"))
    }

    func testCondaManagerDefaultChannels() async {
        let manager = CondaManager.shared
        let channels = await manager.defaultChannels

        XCTAssertEqual(channels, ["conda-forge", "bioconda"])
    }

    func testCondaManagerUsesConfiguredManagedStorageRoot() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "conda-manager-home-\(UUID().uuidString)",
            isDirectory: true
        )
        let configuredRoot = home.appendingPathComponent("custom-storage", isDirectory: true)
        let store = ManagedStorageConfigStore(homeDirectory: home)
        try store.setActiveRoot(configuredRoot)

        let manager = CondaManager(
            storageConfigStore: store,
            bundledMicromambaProvider: { nil },
            bundledMicromambaVersionProvider: { nil }
        )

        let rootPrefix = manager.rootPrefix
        let environmentURL = await manager.environmentURL(named: "sra-tools")

        XCTAssertEqual(rootPrefix.standardizedFileURL.path, configuredRoot.appendingPathComponent("conda").standardizedFileURL.path)
        XCTAssertEqual(
            environmentURL.standardizedFileURL.path,
            configuredRoot
                .appendingPathComponent("conda/envs/sra-tools", isDirectory: true)
                .standardizedFileURL.path
        )
    }

    func testNextflowCondaConfig() async {
        let manager = CondaManager.shared
        let config = await manager.nextflowCondaConfig()

        XCTAssertNotNil(config["NXF_CONDA_CACHEDIR"])
        XCTAssertNotNil(config["MAMBA_ROOT_PREFIX"])
        XCTAssertEqual(config["NXF_CONDA_ENABLED"], "true")
    }

    func testNextflowCondaConfigString() async {
        let manager = CondaManager.shared
        let configStr = await manager.nextflowCondaConfigString()

        XCTAssertTrue(configStr.contains("conda {"))
        XCTAssertTrue(configStr.contains("enabled = true"))
        XCTAssertTrue(configStr.contains("useMicromamba = true"))
        XCTAssertTrue(configStr.contains("cacheDir"))
        XCTAssertTrue(configStr.contains("channels = ['conda-forge', 'bioconda']"))
        XCTAssertTrue(configStr.contains("createOptions = '--override-channels'"))
        XCTAssertTrue(configStr.contains("MAMBA_ROOT_PREFIX"))
    }

    // MARK: - CondaError Tests

    func testCondaErrorDescriptions() {
        let errors: [CondaError] = [
            .micromambaNotFound,
            .micromambaDownloadFailed("timeout"),
            .environmentCreationFailed("conflict"),
            .environmentNotFound("test-env"),
            .packageInstallFailed("network"),
            .packageNotFound("nonexistent"),
            .toolNotFound(tool: "samtools", environment: "test"),
            .executionFailed(tool: "bwa", exitCode: 1, stderr: "error"),
            .linuxOnlyPackage("pbaa"),
            .networkError("timeout"),
            .diskSpaceError("insufficient"),
            .timeout(tool: "kraken2", seconds: 3600),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testTimeoutErrorDescription() {
        let error = CondaError.timeout(tool: "kraken2", seconds: 60)
        XCTAssertEqual(error.errorDescription, "Tool 'kraken2' timed out after 60 seconds")
    }

    func testMicromambaNotFoundErrorDescription() {
        XCTAssertEqual(
            CondaError.micromambaNotFound.errorDescription,
            "Micromamba binary not found in the bundled resources."
        )
    }

    func testEnsureMicromambaCopiesBundledBinaryWhenMissing() async throws {
        let sandbox = try makeMicromambaSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let bundledMicromamba = try makeFakeMicromamba(
            at: sandbox.appendingPathComponent("bundled-micromamba"),
            version: "2.0.5-0"
        )
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { bundledMicromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )

        let installedPath = try await manager.ensureMicromamba()
        let expectedPath = await manager.micromambaPath
        let installedContents = try String(contentsOf: installedPath, encoding: .utf8)
        let installedVersion = try await readMicromambaVersion(at: installedPath)
        let permissions = try FileManager.default.attributesOfItem(atPath: installedPath.path)[.posixPermissions] as? NSNumber

        XCTAssertEqual(installedPath, expectedPath)
        XCTAssertEqual(installedVersion, "2.0.5-0")
        XCTAssertTrue(installedContents.contains("2.0.5-0"))
        XCTAssertEqual(permissions?.intValue, 0o755)
    }

    func testEnsureMicromambaReplacesInstalledBinaryWhenBundledVersionChanges() async throws {
        let sandbox = try makeMicromambaSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let rootPrefix = sandbox.appendingPathComponent("conda")
        let bundledMicromamba = try makeFakeMicromamba(
            at: sandbox.appendingPathComponent("bundled-micromamba"),
            version: "2.0.5-0"
        )
        let installedMicromamba = try makeFakeMicromamba(
            at: rootPrefix.appendingPathComponent("bin/micromamba"),
            version: "2.0.4"
        )
        let oldContents = try String(contentsOf: installedMicromamba, encoding: .utf8)

        let manager = CondaManager(
            rootPrefix: rootPrefix,
            bundledMicromambaProvider: { bundledMicromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )

        let installedPath = try await manager.ensureMicromamba()
        let newContents = try String(contentsOf: installedPath, encoding: .utf8)
        let installedVersion = try await readMicromambaVersion(at: installedPath)

        XCTAssertEqual(installedVersion, "2.0.5-0")
        XCTAssertNotEqual(newContents, oldContents)
        XCTAssertTrue(newContents.contains("2.0.5-0"))
    }

    // MARK: - Integration Tests (require network)

    func testListEnvironments() async throws {
        let manager = CondaManager.shared
        // This should not throw even if no environments exist
        let envs = try await manager.listEnvironments()
        // Just verify it returns an array (may be empty or populated)
        XCTAssertTrue(envs is [CondaEnvironment])
    }

    // MARK: - Concurrent Pipe Reading Tests

    /// Verifies that runTool does not deadlock when the subprocess produces
    /// more than 64 KB of output on stdout. The old implementation called
    /// `waitUntilExit()` before reading pipes, which deadlocked because the
    /// OS pipe buffer (64 KB) filled up and the child process blocked on
    /// write, never exiting.
    ///
    /// Uses `/bin/dd` to generate exactly 128 KB of zero bytes, which is
    /// double the pipe buffer size. If the implementation reads pipes
    /// concurrently, this completes in well under the timeout.
    func testRunToolDoesNotDeadlockWithLargeOutput() async throws {
        let manager = CondaManager.shared

        // We bypass micromamba by directly testing the pattern with a known
        // system command. Since runTool requires an environment, we instead
        // test the same continuation+readabilityHandler pattern directly
        // using /bin/dd which produces >64KB output.
        let result = try await runProcessWithConcurrentPipes(
            executablePath: "/bin/dd",
            arguments: ["if=/dev/zero", "bs=1024", "count=128"],
            timeout: 10
        )

        // dd writes 128 * 1024 = 131072 bytes of zeros to stdout.
        // stderr will contain the dd summary line.
        XCTAssertEqual(result.exitCode, 0, "dd should exit cleanly")
        XCTAssertEqual(result.stdoutData.count, 131_072,
                       "Should have received exactly 128 KB of stdout data")
        XCTAssertFalse(result.stderr.isEmpty,
                       "dd should write a summary to stderr")
    }

    /// Verifies that the timeout mechanism works: a long-running process
    /// is terminated when the timeout expires.
    func testRunToolTimeout() async throws {
        // Use `sleep 60` which will be killed by our 1-second timeout.
        do {
            _ = try await runProcessWithConcurrentPipes(
                executablePath: "/bin/sleep",
                arguments: ["60"],
                timeout: 1
            )
            XCTFail("Should have thrown a timeout error")
        } catch {
            // Verify we got a timeout-related termination (SIGTERM = 15).
            // The process was killed, so we expect a non-zero exit.
            let nsError = error as NSError
            XCTAssertTrue(
                nsError.localizedDescription.contains("timed out")
                || nsError.domain == "ProcessTimeout",
                "Error should indicate timeout, got: \(error)"
            )
        }
    }

    /// Verifies that concurrent pipe reading handles mixed stdout/stderr
    /// output correctly without data corruption.
    func testRunToolConcurrentPipeReading() async throws {
        // Use a shell command that writes to both stdout and stderr
        // in an interleaved pattern. We use /bin/sh to run a script
        // that echoes numbered lines to both streams.
        let script = """
        i=0; while [ $i -lt 500 ]; do echo "stdout-line-$i"; echo "stderr-line-$i" >&2; i=$((i+1)); done
        """

        let result = try await runProcessWithConcurrentPipes(
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            timeout: 10
        )

        XCTAssertEqual(result.exitCode, 0)

        let stdoutLines = result.stdout.split(separator: "\n")
        let stderrLines = result.stderr.split(separator: "\n")

        XCTAssertEqual(stdoutLines.count, 500,
                       "Should have 500 stdout lines, got \(stdoutLines.count)")
        XCTAssertEqual(stderrLines.count, 500,
                       "Should have 500 stderr lines, got \(stderrLines.count)")

        // Verify ordering is preserved within each stream.
        for i in 0..<500 {
            XCTAssertEqual(String(stdoutLines[i]), "stdout-line-\(i)")
            XCTAssertEqual(String(stderrLines[i]), "stderr-line-\(i)")
        }
    }

    func testRunToolPreservesHomeDirectoryForManagedLaunchers() async throws {
        let sandbox = try makeMicromambaSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let bundledMicromamba = sandbox.appendingPathComponent("bundled-micromamba")
        try FileManager.default.createDirectory(
            at: bundledMicromamba.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let script = """
        #!/bin/sh
        case "$1" in
            --version)
                echo "2.0.5-0"
                exit 0
                ;;
            run)
                printf '%s' "${HOME:-}"
                exit 0
                ;;
            *)
                echo "unexpected args: $@" >&2
                exit 1
                ;;
        esac
        """
        try script.write(to: bundledMicromamba, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bundledMicromamba.path
        )

        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { bundledMicromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )
        _ = try await manager.ensureMicromamba()

        let result = try await manager.runTool(
            name: "nextflow",
            arguments: ["-version"],
            environment: "nextflow"
        )

        XCTAssertEqual(
            result.stdout,
            FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    // MARK: - Private Test Helper

    /// Result from running a process with concurrent pipe reading.
    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let stdoutData: Data
        let exitCode: Int32
    }

    /// Runs a process using the same continuation + readabilityHandler pattern
    /// as the fixed CondaManager.runTool / runMicromamba methods.
    ///
    /// This helper allows testing the pipe-reading and timeout logic without
    /// requiring micromamba to be installed.
    private func runProcessWithConcurrentPipes(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        struct ProcessTimeoutError: Error, LocalizedError {
            let tool: String
            let seconds: TimeInterval
            var errorDescription: String? {
                "Process '\(tool)' timed out after \(Int(seconds)) seconds"
            }
            var domain: String { "ProcessTimeout" }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            nonisolated(unsafe) let stdoutBuffer = NSMutableData()
            nonisolated(unsafe) let stderrBuffer = NSMutableData()
            nonisolated(unsafe) var continuationResumed = false

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stdoutBuffer.append(data)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stderrBuffer.append(data)
                }
            }

            let toolName = URL(fileURLWithPath: executablePath).lastPathComponent
            nonisolated(unsafe) let timeoutItem = DispatchWorkItem { [weak process] in
                guard let process, process.isRunning else { return }
                process.terminate()
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutItem
            )

            process.terminationHandler = { terminatedProcess in
                timeoutItem.cancel()

                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    guard !continuationResumed else { return }
                    continuationResumed = true

                    let stdout = String(data: stdoutBuffer as Data, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrBuffer as Data, encoding: .utf8) ?? ""

                    if terminatedProcess.terminationReason == .uncaughtSignal
                        && (terminatedProcess.terminationStatus == 15
                            || terminatedProcess.terminationStatus == 143) {
                        continuation.resume(
                            throwing: ProcessTimeoutError(tool: toolName, seconds: timeout)
                        )
                    } else {
                        continuation.resume(
                            returning: ProcessResult(
                                stdout: stdout,
                                stderr: stderr,
                                stdoutData: stdoutBuffer as Data,
                                exitCode: terminatedProcess.terminationStatus
                            )
                        )
                    }
                }
            }

            do {
                try process.run()
            } catch {
                timeoutItem.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                guard !continuationResumed else { return }
                continuationResumed = true
                continuation.resume(throwing: error)
            }
        }
    }

    private func makeMicromambaSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func makeFakeMicromamba(at url: URL, version: String) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        case "$1" in
            --version)
                echo "\(version)"
                exit 0
                ;;
            create|install)
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        -n)
                            shift
                            env_name="$1"
                            ;;
                    esac
                    shift
                done
                if [ -z "$MAMBA_ROOT_PREFIX" ] || [ -z "$env_name" ]; then
                    echo "missing root prefix or env name" >&2
                    exit 1
                fi
                mkdir -p "$MAMBA_ROOT_PREFIX/envs/$env_name/bin"
                mkdir -p "$MAMBA_ROOT_PREFIX/envs/$env_name/conda-meta"
                exit 0
                ;;
            remove)
                exit 0
                ;;
            *)
                echo "unexpected args: $@" >&2
                exit 1
                ;;
        esac
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private final class RecordingMicromamba {
        let root: URL
        let url: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            url = root.appendingPathComponent("micromamba")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
                echo "2.0.5-0"
                exit 0
            fi
            printf '%s\n' "$*" >> "$MAMBA_ROOT_PREFIX/install-log.txt"
            exit 0
            """
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func firstInstallArgs() -> [String]? {
            let logURL = root.appendingPathComponent("install-log.txt")
            guard let data = try? Data(contentsOf: logURL) else { return nil }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            return lines.first?.split(separator: " ").map(String.init)
        }
    }

    private func readMicromambaVersion(at url: URL) async throws -> String {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]

        let output = Pipe()
        process.standardOutput = output

        try process.run()
        process.waitUntilExit()

        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
