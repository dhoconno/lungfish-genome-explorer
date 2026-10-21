// ProvenanceExportPlanSpecTests.swift - The package spec an export writes for each managed tool
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 lane P5a. `ProvenanceExportPlan` turns the managed environment a step ran in into the
// package spec an exported script, Snakefile or environment file installs. The plan writes the lock
// entry's channel, package, version and build when the recorded version is the lock's version, the
// same without the build when it is not, and never a version other than the recorded one. The second
// group pins what the managed tool sites record, and the third what the plan does when two steps of
// one environment disagree.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ProvenanceExportPlanSpecTests: XCTestCase {

    // MARK: - Fixtures

    /// One managed tool step as the pipelines record it, with the runtime identity after the version.
    private func managedStep(
        _ tool: String,
        version: String,
        environment: String,
        executable: String? = nil,
        package: String? = nil
    ) -> StepExecution {
        let executable = executable ?? tool
        var note = "managed conda environment \(environment); executable \(executable)"
        if let package { note += "; package \(package)" }
        return StepExecution(
            toolName: tool,
            toolVersion: "\(version) (\(note))",
            command: [executable, "--run"],
            inputs: [],
            outputs: [],
            exitCode: 0,
            wallTime: 1
        )
    }

    private func run(_ steps: [StepExecution]) -> WorkflowRun {
        var run = WorkflowRun(name: "plan spec test", appVersion: "lungfish-cli 2026.10.10", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = steps
        return run
    }

    private func plan(_ steps: StepExecution..., lock: ManagedToolLock = .bundled) -> ProvenanceExportPlan {
        ProvenanceExportPlan(run: run(steps), replayArguments: { $0.durableReplayArgv ?? $0.command }, lock: lock)
    }

    private func environment(_ name: String, in plan: ProvenanceExportPlan) throws -> ProvenanceManagedEnvironment {
        try XCTUnwrap(plan.environments.first { $0.name == name }, "no environment \(name) in \(plan.environments)")
    }

    /// The spec the plan writes for a step of `tool` that recorded `version` and no package.
    private func exportedSpec(_ tool: String, version: String, environment name: String, executable: String? = nil) throws -> String? {
        let plan = plan(managedStep(tool, version: version, environment: name, executable: executable))
        return try environment(name, in: plan).packageSpec
    }

    // MARK: - The spec the plan writes

    func testPlanWritesTheLocksSpecWithItsBuildWhenTheRecordedVersionIsTheLocks() throws {
        XCTAssertEqual(try exportedSpec("samtools", version: "1.24", environment: "samtools"), "bioconda::samtools=1.24=h36b3a25_1")
        XCTAssertEqual(try exportedSpec("bbmap", version: "40.02", environment: "bbtools", executable: "bbmap.sh"), "bioconda::bbmap=40.02=he046917_0")
        XCTAssertEqual(try exportedSpec("minimap2", version: "2.31", environment: "minimap2"), "bioconda::minimap2=2.31=h6bd33b9_0")
        XCTAssertEqual(try exportedSpec("kraken2", version: "2.17.1", environment: "kraken2"), "bioconda::kraken2=2.17.1=pl5321h158e17b_0")
    }

    func testPlanWritesTheLocksChannelForCondaForgePackages() throws {
        XCTAssertEqual(try exportedSpec("openpyxl", version: "3.1.5", environment: "openpyxl"), "conda-forge::openpyxl=3.1.5=py312h2a925e6_3")
        XCTAssertEqual(try exportedSpec("pigz", version: "2.8", environment: "pigz"), "conda-forge::pigz=2.8=hfab5511_2")
        XCTAssertEqual(try exportedSpec("mafft", version: "7.526", environment: "mafft"), "conda-forge::mafft=7.526=h99b78c6_0")
    }

    func testPlanNamesThePackageOfAPackToolWithItsBuild() throws {
        // The lock installs `whatshap` in the `phasing` environment and `gatk4` in `gatk-core`.
        let phasing = plan(managedStep("whatshap", version: "2.3", environment: "phasing"))
        XCTAssertEqual(try environment("phasing", in: phasing).packageSpec, "bioconda::whatshap=2.3=py311h1457a19_3")
        XCTAssertEqual(
            try environment("phasing", in: phasing).environmentFileContents,
            """
            # Written by Lungfish from the recorded package pin.
            name: lge-phasing
            channels:
              - conda-forge
              - bioconda
            dependencies:
              - bioconda::whatshap=2.3=py311h1457a19_3

            """
        )
        XCTAssertEqual(
            try environment("phasing", in: phasing).micromambaCreateCommand,
            "micromamba create -y -n lge-phasing -c conda-forge -c bioconda bioconda::whatshap=2.3=py311h1457a19_3"
        )
        XCTAssertEqual(try exportedSpec("gatk", version: "4.6.2.0", environment: "gatk-core"), "bioconda::gatk4=4.6.2.0=py310hdfd78af_1")
        XCTAssertEqual(try exportedSpec("ivar", version: "1.4.4", environment: "ivar"), "bioconda::ivar=1.4.4=hda5e58c_0")
    }

    func testPlanWritesTheRecordedVersionWithoutABuildWhenItIsNotTheLocks() throws {
        // The lock cannot say which build of another version ran, and a version other than the recorded
        // one is never written. The channel and the package still come from the lock.
        XCTAssertEqual(try exportedSpec("kraken2", version: "2.1.3", environment: "kraken2"), "bioconda::kraken2=2.1.3")
        XCTAssertEqual(try exportedSpec("samtools", version: "1.23", environment: "samtools"), "bioconda::samtools=1.23")
        XCTAssertEqual(try exportedSpec("pigz", version: "2.7", environment: "pigz"), "conda-forge::pigz=2.7")
        XCTAssertEqual(try exportedSpec("whatshap", version: "2.2", environment: "phasing"), "bioconda::whatshap=2.2")
        XCTAssertEqual(try exportedSpec("gatk", version: "4.5.0.0", environment: "gatk-core"), "bioconda::gatk4=4.5.0.0")
    }

    func testPlanNeverWritesAVersionOtherThanTheRecordedOne() throws {
        let lock = ManagedToolLock.bundled
        var checked = 0
        for entry in lock.entries where entry.pythonRuntime == nil && entry.sourceBuild == nil {
            let lockVersion = try XCTUnwrap(entry.version, entry.id.rawValue)
            // A record that holds no package, and one that recorded the lock's own spec for the entry. A step
            // whose version is not the spec's ran something else, so the spec never reaches the export.
            for environment in [
                ProvenanceManagedEnvironment(name: entry.environment),
                ProvenanceManagedEnvironment(name: entry.environment, packageSpec: lock.packageSpec(of: entry)),
            ] {
                for version in [lockVersion, "9.9.9", "0.0.1"] {
                    let spec = try XCTUnwrap(ProvenanceExportPlan.pinned(environment, version: version).packageSpec)
                    let parsed = try XCTUnwrap(CondaSpec(spec: spec), "\(entry.id.rawValue) \(version): \(spec)")
                    XCTAssertEqual(parsed.version, version, "\(entry.id.rawValue): \(spec)")
                    XCTAssertEqual(parsed.build != nil, version == lockVersion, "\(entry.id.rawValue) \(version): \(spec)")
                    XCTAssertNotNil(parsed.channel, "\(entry.id.rawValue): \(spec)")
                }
                for version in ["unknown", "unresolved", "critical libmamba The given prefix does not exist"] {
                    let spec = try XCTUnwrap(ProvenanceExportPlan.pinned(environment, version: version).packageSpec)
                    XCTAssertFalse(spec.contains("="), "\(entry.id.rawValue) \(version): \(spec)")
                    XCTAssertFalse(spec.contains("::"), "\(entry.id.rawValue) \(version): \(spec)")
                }
            }
            checked += 1
        }
        XCTAssertEqual(checked, 44, "19 tools and 27 pack tools, and two of the pack tools have no conda spec")
    }

    /// A native pack tool and a conda-run mapper record the lock's spec whatever their probe printed, so a
    /// record can hold `2.2.1` beside `bioconda::minimap2=2.31=h6bd33b9_0`, or a probe error read as `unknown`
    /// beside `bioconda::bwa-mem2=2.3=hda5e58c_0`. A spec of another version is the lock the writer read and
    /// not what ran, so the plan keeps the recorded version and the lock's channel and package.
    func testPlanDropsARecordedSpecOfAnotherVersion() throws {
        let minimap2 = plan(managedStep("minimap2", version: "2.2.1", environment: "minimap2", package: "bioconda::minimap2=2.31=h6bd33b9_0"))
        XCTAssertEqual(try environment("minimap2", in: minimap2).packageSpec, "bioconda::minimap2=2.2.1")
        let bwa = plan(managedStep("bwa-mem2", version: "unknown", environment: "bwa-mem2", package: "bioconda::bwa-mem2=2.3=hda5e58c_0"))
        XCTAssertEqual(try environment("bwa-mem2", in: bwa).packageSpec, "bwa-mem2")
        // The lock does not hold this environment, so the recorded channel and package are all there is.
        let unknown = plan(managedStep("tool", version: "2.0", environment: "my-env", package: "bioconda::my-package=1.0=b_0"))
        XCTAssertEqual(try environment("my-env", in: unknown).packageSpec, "bioconda::my-package=2.0")
        let unversioned = plan(managedStep("tool", version: "unknown", environment: "my-env", package: "bioconda::my-package=1.0=b_0"))
        XCTAssertEqual(try environment("my-env", in: unversioned).packageSpec, "my-package")
        // At the recorded version the spec is what ran, whatever its build.
        let same = plan(managedStep("tool", version: "1.0", environment: "my-env", package: "bioconda::my-package=1.0=b_0"))
        XCTAssertEqual(try environment("my-env", in: same).packageSpec, "bioconda::my-package=1.0=b_0")
    }

    func testPlanWritesTheBarePackageForAnUnknownVersion() throws {
        XCTAssertEqual(try exportedSpec("samtools", version: "unknown", environment: "samtools"), "samtools")
        XCTAssertEqual(try exportedSpec("bbmap", version: "unknown", environment: "bbtools", executable: "bbmap.sh"), "bbmap")
        XCTAssertEqual(
            try exportedSpec("whatshap", version: "unknown", environment: "phasing"),
            "whatshap",
            "an unknown version writes the package and never the environment name"
        )
    }

    func testPlanKeepsARecordedFullSpecAsRecorded() throws {
        let same = plan(managedStep("samtools", version: "1.24", environment: "samtools", package: "bioconda::samtools=1.24=h36b3a25_1"))
        XCTAssertEqual(try environment("samtools", in: same).packageSpec, "bioconda::samtools=1.24=h36b3a25_1")
        // A recorded build that is not the lock's is what ran, so it stays.
        let other = plan(managedStep("samtools", version: "1.24", environment: "samtools", package: "bioconda::samtools=1.24=other_0"))
        XCTAssertEqual(try environment("samtools", in: other).packageSpec, "bioconda::samtools=1.24=other_0")
    }

    func testPlanReplacesARecordedBarePackageWithThePinFromTheLock() throws {
        // Older records of the pack tools kept the native tool's source package, which is no conda spec and
        // pins nothing. `ncbi-blast` is not even the package the lock installs.
        let ivar = plan(managedStep("ivar", version: "1.4.4", environment: "ivar", package: "ivar"))
        XCTAssertEqual(try environment("ivar", in: ivar).packageSpec, "bioconda::ivar=1.4.4=hda5e58c_0")
        let blast = plan(managedStep("blastn", version: "2.16.0", environment: "blast", package: "ncbi-blast"))
        XCTAssertEqual(try environment("blast", in: blast).packageSpec, "bioconda::blast=2.16.0=hb260f6e_5")
        let older = plan(managedStep("ivar", version: "1.4.3", environment: "ivar", package: "ivar"))
        XCTAssertEqual(try environment("ivar", in: older).packageSpec, "bioconda::ivar=1.4.3")
        // The lock does not hold this environment, so the recorded package is all there is.
        let unknown = plan(managedStep("tool", version: "1.0", environment: "my-env", package: "my-package"))
        XCTAssertEqual(try environment("my-env", in: unknown).packageSpec, "my-package")
    }

    func testPlanWritesPythonRuntimeAndSourceBuildToolsByTheirIdAtTheRecordedVersion() throws {
        // A conda spec cannot express either tool, and the pin gate treats both as unpinnable.
        XCTAssertEqual(try exportedSpec("primalscheme3", version: "3.3.0+lge.5", environment: "primalscheme3"), "bioconda::primalscheme3=3.3.0+lge.5")
        XCTAssertEqual(try exportedSpec("bracken", version: "1.0.0", environment: "bracken"), "bioconda::bracken=1.0.0")
        XCTAssertEqual(try exportedSpec("bracken", version: "unknown", environment: "bracken"), "bracken")
    }

    func testAnEnvironmentTheLockDoesNotHoldIsWrittenByItsName() throws {
        XCTAssertEqual(try exportedSpec("tool", version: "1.0", environment: "my-env"), "bioconda::my-env=1.0")
        XCTAssertEqual(try exportedSpec("tool", version: "unknown", environment: "my-env"), "my-env")
    }

    func testPlanReadsTheSpecFromTheLockItIsGiven() throws {
        let lock = ManagedToolLock(
            packID: "test",
            displayName: "Test",
            version: "1",
            tools: [.init(
                id: "samtools", environment: "samtools", packageSpec: "conda-forge::samtools=9.9=zzz_7",
                executables: ["samtools"], version: "9.9"
            )],
            managedData: [],
            packTools: [.init(
                packID: "extras", toolID: "tool-a", environment: "env-a", packageSpec: "bioconda::package-a=1.0=b_0",
                executables: ["a"], version: "1.0", license: nil, sourceUrl: nil
            )]
        )
        let samtools = plan(managedStep("samtools", version: "9.9", environment: "samtools"), lock: lock)
        XCTAssertEqual(try environment("samtools", in: samtools).packageSpec, "conda-forge::samtools=9.9=zzz_7")
        let older = plan(managedStep("samtools", version: "1.0", environment: "samtools"), lock: lock)
        XCTAssertEqual(try environment("samtools", in: older).packageSpec, "conda-forge::samtools=1.0")
        let pack = plan(managedStep("a", version: "1.0", environment: "env-a"), lock: lock)
        XCTAssertEqual(try environment("env-a", in: pack).packageSpec, "bioconda::package-a=1.0=b_0")
    }

    func testEnvironmentFileTextNamesThePackageOfAnEnvironmentWithNoPin() {
        let phasing = ProvenanceManagedEnvironment(name: "phasing")
        XCTAssertTrue(phasing.environmentFileContents.hasSuffix("dependencies:\n  - whatshap\n"))
        XCTAssertTrue(phasing.micromambaCreateCommand.hasSuffix("-c bioconda whatshap"))
        let unknown = ProvenanceManagedEnvironment(name: "my-env")
        XCTAssertTrue(unknown.environmentFileContents.hasSuffix("dependencies:\n  - my-env\n"))
        XCTAssertTrue(unknown.micromambaCreateCommand.hasSuffix("-c bioconda my-env"))
    }

    // MARK: - Two steps of one environment that disagree

    func testTwoStepsOfOneEnvironmentThatDisagreeKeepBothSpecs() throws {
        let plan = plan(
            managedStep("samtools", version: "1.23", environment: "samtools", package: "bioconda::samtools=1.23=aaaaaaa_0"),
            managedStep("samtools", version: "1.24", environment: "samtools", package: "bioconda::samtools=1.24=h36b3a25_1"),
            managedStep("samtools", version: "1.23", environment: "samtools", package: "bioconda::samtools=1.23=aaaaaaa_0")
        )
        XCTAssertEqual(plan.environments.map(\.name), ["samtools", "samtools"])
        guard plan.environments.count == 2 else { return }
        XCTAssertEqual(plan.environments.map(\.packageSpec), ["bioconda::samtools=1.23=aaaaaaa_0", "bioconda::samtools=1.24=h36b3a25_1"])
        XCTAssertEqual(plan.environments.map(\.variant), [1, 2])
        XCTAssertEqual(plan.environments.map(\.environmentFileName), ["envs/samtools.yaml", "envs/samtools_2.yaml"])
        XCTAssertEqual(
            plan.environments.map(\.micromambaCreateCommand),
            [
                "micromamba create -y -n lge-samtools -c conda-forge -c bioconda bioconda::samtools=1.23=aaaaaaa_0",
                "micromamba create -y -n lge-samtools_2 -c conda-forge -c bioconda bioconda::samtools=1.24=h36b3a25_1",
            ]
        )
        XCTAssertTrue(plan.environments[1].environmentFileContents.contains("name: lge-samtools_2\n"))
        // Each step names the entry that holds its own spec, so the third step shares the first one's.
        XCTAssertEqual(plan.steps.compactMap(\.environment), [plan.environments[0], plan.environments[1], plan.environments[0]])
    }

    func testTwoStepsWhoseSpecsComeFromDifferentVersionsKeepBothSpecs() throws {
        let plan = plan(
            managedStep("kraken2", version: "2.17.1", environment: "kraken2"),
            managedStep("kraken2", version: "2.1.3", environment: "kraken2")
        )
        XCTAssertEqual(
            plan.environments.map(\.packageSpec),
            ["bioconda::kraken2=2.17.1=pl5321h158e17b_0", "bioconda::kraken2=2.1.3"]
        )
        XCTAssertEqual(plan.environments.map(\.environmentFileName), ["envs/kraken2.yaml", "envs/kraken2_2.yaml"])
    }

    func testStepsWhoseSpecsAgreeShareOneEnvironment() throws {
        // One records the lock's spec and the other only its version, and both mean the same package.
        let plan = plan(
            managedStep("samtools", version: "1.24", environment: "samtools", package: "bioconda::samtools=1.24=h36b3a25_1"),
            managedStep("samtools", version: "1.24", environment: "samtools"),
            managedStep("bcftools", version: "1.24", environment: "bcftools")
        )
        XCTAssertEqual(plan.environments.map(\.name), ["samtools", "bcftools"])
        XCTAssertEqual(plan.environments.map(\.variant), [1, 1])
        XCTAssertEqual(plan.environments.map(\.environmentFileName), ["envs/samtools.yaml", "envs/bcftools.yaml"])
    }

    func testSnakemakeWritesAnEnvironmentFileForEachSpecAndEachRuleNamesItsOwn() throws {
        let steps = [
            managedStep("samtools", version: "1.23", environment: "samtools", package: "bioconda::samtools=1.23=aaaaaaa_0"),
            managedStep("samtools", version: "1.24", environment: "samtools", package: "bioconda::samtools=1.24=h36b3a25_1"),
        ]
        let envelope = ProvenanceEnvelope(
            workflowName: "plan spec test",
            toolName: "lungfish-cli",
            files: [],
            steps: steps.map { ProvenanceStep(stepExecution: $0) },
            legacyWorkflowRun: run(steps)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-spec-snakemake-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try ProvenanceExporter(signingProvider: nil).exportBundle(envelope, format: .snakemake, to: directory, sourceSidecarURL: nil)

        let first = try String(contentsOf: directory.appendingPathComponent("envs/samtools.yaml"), encoding: .utf8)
        let second = try String(contentsOf: directory.appendingPathComponent("envs/samtools_2.yaml"), encoding: .utf8)
        XCTAssertTrue(first.contains("  - bioconda::samtools=1.23=aaaaaaa_0\n"), first)
        XCTAssertTrue(second.contains("  - bioconda::samtools=1.24=h36b3a25_1\n"), second)
        let snakefile = try String(contentsOf: directory.appendingPathComponent("Snakefile"), encoding: .utf8)
        XCTAssertTrue(snakefile.contains("\"envs/samtools.yaml\""), snakefile)
        XCTAssertTrue(snakefile.contains("\"envs/samtools_2.yaml\""), snakefile)
    }

    func testShellAndNextflowCarryEachSpec() {
        let steps = [
            managedStep("samtools", version: "1.23", environment: "samtools", package: "bioconda::samtools=1.23=aaaaaaa_0"),
            managedStep("samtools", version: "1.24", environment: "samtools", package: "bioconda::samtools=1.24=h36b3a25_1"),
        ]
        let exporter = ProvenanceExporter(signingProvider: nil)
        let shell = exporter.exportShell(run(steps))
        XCTAssertTrue(shell.contains("-n lge-samtools -c conda-forge -c bioconda bioconda::samtools=1.23=aaaaaaa_0"), shell)
        XCTAssertTrue(shell.contains("-n lge-samtools_2 -c conda-forge -c bioconda bioconda::samtools=1.24=h36b3a25_1"), shell)
        let nextflow = exporter.exportNextflow(run(steps))
        XCTAssertTrue(nextflow.contains("conda 'bioconda::samtools=1.23=aaaaaaa_0'"), nextflow)
        XCTAssertTrue(nextflow.contains("conda 'bioconda::samtools=1.24=h36b3a25_1'"), nextflow)
    }

    // MARK: - What the ONT demux pipeline records for its managed tools

    func testONTDemuxDescriptorsAreTheLocksEntriesWithTheirBuildPinnedSpecs() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        let descriptors = ONTBarcodeDemuxGenotypingPipeline.managedToolDescriptors(
            ids: ["minimap2", "samtools", "pysam", "openpyxl", "bbtools", "not-a-tool"],
            manifest: lock
        )
        XCTAssertEqual(descriptors.compactMap { $0["id"] as? String }, ["minimap2", "samtools", "pysam", "openpyxl", "bbtools"])

        func descriptor(_ id: String) throws -> [String: Any] {
            try XCTUnwrap(descriptors.first { ($0["id"] as? String) == id }, id)
        }
        let minimap2 = try descriptor("minimap2")
        XCTAssertEqual(minimap2["packageSpec"] as? String, "bioconda::minimap2=2.31=h6bd33b9_0")
        XCTAssertEqual(minimap2["packID"] as? String, "read-mapping")
        XCTAssertEqual(minimap2["environment"] as? String, "minimap2")
        XCTAssertEqual(minimap2["version"] as? String, "2.31")
        XCTAssertEqual(Set(minimap2.keys), ["id", "packID", "environment", "packageSpec", "executables", "version", "license", "sourceUrl"])

        let samtools = try descriptor("samtools")
        XCTAssertEqual(samtools["packageSpec"] as? String, "bioconda::samtools=1.24=h36b3a25_1")
        XCTAssertNil(samtools["packID"], "a tool of the required pack names no pack")
        XCTAssertEqual(samtools["version"] as? String, "1.24")
        XCTAssertEqual(Set(samtools.keys), ["id", "environment", "packageSpec", "executables", "version", "license", "sourceUrl"])

        XCTAssertEqual(try descriptor("pysam")["packageSpec"] as? String, "bioconda::pysam=0.24.0=py310hf7cbfa5_1")
        XCTAssertEqual(try descriptor("openpyxl")["packageSpec"] as? String, "conda-forge::openpyxl=3.1.5=py312h2a925e6_3")
        XCTAssertEqual(try descriptor("bbtools")["packageSpec"] as? String, "bioconda::bbmap=40.02=he046917_0")
        XCTAssertEqual(try descriptor("bbtools")["environment"] as? String, "bbtools")
    }

    // MARK: - What the native tool sites record

    /// The lock's package spec for every lock id, read from the bundled lock file as plain JSON and not
    /// through the lock types under test.
    private static func lockSpecsByID() throws -> [String: String] {
        let url = try ManagedToolLock.resourceURL()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var specs: [String: String] = [:]
        for list in ["tools", "packTools"] {
            for entry in root[list] as? [[String: Any]] ?? [] {
                if let id = entry["id"] as? String, let spec = entry["packageSpec"] as? String { specs[id] = spec }
            }
        }
        return specs
    }

    /// BAMPrimerTrimPipeline, ViralVariantCallingPipeline, ManagedMappingPipeline and Minimap2Pipeline
    /// record `package <spec>` after a native tool's version. The spec is the lock entry found by the
    /// tool's `ManagedToolID`, so a pack tool such as iVar resolves. Looking the lock up through the tools
    /// list alone, as the sites did, left nine native pack tools recording their source package, which
    /// is no conda spec.
    func testEveryManagedNativeToolRecordsTheLocksSpecForItsManagedToolID() throws {
        let specs = try Self.lockSpecsByID()
        var checked = 0
        for tool in NativeTool.allCases {
            guard case .managed(let environment, let executable) = tool.location else { continue }
            let id = tool.managedToolID.rawValue
            let spec = try XCTUnwrap(specs[id], "the lock has no entry \(id) for \(tool)")
            XCTAssertEqual(
                ProvenanceManagedEnvironment.recordedRuntime(for: tool),
                "managed conda environment \(environment); executable \(executable); package \(spec)",
                "\(tool)"
            )
            checked += 1
        }
        XCTAssertEqual(checked, NativeTool.allCases.count)
    }

    func testPackToolsRecordTheirBuildPinnedSpec() {
        let expected: [(NativeTool, String)] = [
            (.ivar, "bioconda::ivar=1.4.4=hda5e58c_0"),
            (.lofreq, "bioconda::lofreq=2.1.5=py310h9cf5bfa_16"),
            (.medaka, "bioconda::medaka=2.2.2=py312h3bb865a_0"),
            (.medakaVariant, "bioconda::medaka=2.2.2=py312h3bb865a_0"),
            (.clair3, "bioconda::clair3=2.0.2=py311h9aa1f4a_0"),
            (.whatshap, "bioconda::whatshap=2.3=py311h1457a19_3"),
            (.freyja, "bioconda::freyja=2.0.3=pyhdfd78af_0"),
            (.ribodetector, "bioconda::ribodetector=0.3.3=pyhdfd78af_0"),
            (.blastn, "bioconda::blast=2.16.0=hb260f6e_5"),
        ]
        for (tool, spec) in expected {
            guard case .managed(let environment, let executable) = tool.location else { return XCTFail("\(tool) is not managed") }
            XCTAssertEqual(
                ProvenanceManagedEnvironment.recordedRuntime(for: tool),
                "managed conda environment \(environment); executable \(executable); package \(spec)",
                "\(tool)"
            )
        }
    }

    func testToolsOfTheRequiredPackStillRecordTheirSpec() {
        XCTAssertEqual(
            ProvenanceManagedEnvironment.recordedRuntime(for: .samtools),
            "managed conda environment samtools; executable samtools; package bioconda::samtools=1.24=h36b3a25_1"
        )
        XCTAssertEqual(
            ProvenanceManagedEnvironment.recordedRuntime(for: .tabix),
            "managed conda environment htslib; executable tabix; package bioconda::htslib=1.24=hd3c6ec9_0"
        )
        XCTAssertEqual(
            ProvenanceManagedEnvironment.recordedRuntime(for: .bbmap),
            "managed conda environment bbtools; executable bbmap.sh; package bioconda::bbmap=40.02=he046917_0"
        )
    }

    func testAPythonRuntimeOrSourceBuildToolRecordsNoLockPackage() {
        // The lock's spec for primalscheme3 is the Python it runs on, and for Bracken the conda fallback of a
        // source build, so neither names the tool.
        XCTAssertEqual(
            ProvenanceManagedEnvironment.recordedRuntime(environment: "primalscheme3", executableName: "primalscheme3"),
            "managed conda environment primalscheme3; executable primalscheme3"
        )
        XCTAssertEqual(
            ProvenanceManagedEnvironment.recordedRuntime(environment: "bracken", executableName: "bracken"),
            "managed conda environment bracken; executable bracken"
        )
    }

    func testAToolTheLockDoesNotKnowRecordsItsSourcePackage() {
        let empty = ManagedToolLock(packID: "x", displayName: "x", version: "x", tools: [], managedData: [])
        XCTAssertEqual(
            ProvenanceManagedEnvironment.recordedRuntime(for: .ivar, lock: empty),
            "managed conda environment ivar; executable ivar; package ivar"
        )
    }

    /// ManagedMappingPipeline and Minimap2Pipeline run minimap2, BWA-MEM2 and Bowtie2 through
    /// `micromamba run`, so they know an environment name and an executable and no `NativeTool`. The
    /// record carried no package for them, which dropped the build of minimap2.
    func testCondaRunMappersRecordTheLocksSpecForTheirEnvironment() {
        XCTAssertEqual(
            ProvenanceManagedEnvironment.recordedRuntime(environment: "minimap2", executableName: "minimap2"),
            "managed conda environment minimap2; executable minimap2; package bioconda::minimap2=2.31=h6bd33b9_0"
        )
        XCTAssertEqual(
            ProvenanceManagedEnvironment.recordedRuntime(environment: "bwa-mem2", executableName: "bwa-mem2"),
            "managed conda environment bwa-mem2; executable bwa-mem2; package bioconda::bwa-mem2=2.3=hda5e58c_0"
        )
        XCTAssertEqual(
            ProvenanceManagedEnvironment.recordedRuntime(environment: "bowtie2", executableName: "bowtie2-build"),
            "managed conda environment bowtie2; executable bowtie2-build; package bioconda::bowtie2=2.5.5=h9e91881_0"
        )
        XCTAssertEqual(
            ProvenanceManagedEnvironment.recordedRuntime(environment: "no-such-environment", executableName: "tool"),
            "managed conda environment no-such-environment; executable tool",
            "an environment the lock does not hold records no package"
        )
    }
}
