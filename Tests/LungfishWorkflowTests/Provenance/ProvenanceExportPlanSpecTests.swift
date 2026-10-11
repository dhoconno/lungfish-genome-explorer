// ProvenanceExportPlanSpecTests.swift - The package spec an export writes for each managed tool
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.6 lane P5a. `ProvenanceExportPlan` turns the managed environment a step ran in into the
// package spec an exported script, Snakefile or environment file installs. The first group below
// pins what the plan writes at the lane's base, so each later change shows as a reviewed diff. The
// second group pins what the managed tool sites record for the ONT demux descriptors.

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

    private func plan(_ steps: StepExecution...) -> ProvenanceExportPlan {
        var run = WorkflowRun(name: "plan spec test", appVersion: "lungfish-cli 2026.10.10", hostOS: "macOS 26.6.2 (arm64)")
        run.steps = steps
        return ProvenanceExportPlan(run: run, replayArguments: { $0.durableReplayArgv ?? $0.command })
    }

    private func environment(_ name: String, in plan: ProvenanceExportPlan) throws -> ProvenanceManagedEnvironment {
        try XCTUnwrap(plan.environments.first { $0.name == name }, "no environment \(name) in \(plan.environments)")
    }

    /// The spec the plan writes for a step of `tool` that recorded `version` and no package.
    private func exportedSpec(_ tool: String, version: String, environment name: String, executable: String? = nil) throws -> String? {
        let plan = plan(managedStep(tool, version: version, environment: name, executable: executable))
        return try environment(name, in: plan).packageSpec
    }

    // MARK: - What the plan writes at the base of lane P5a

    func testPlanWritesEachLockToolWithoutItsBuild() throws {
        // The lock pins `bioconda::samtools=1.24=h36b3a25_1`, `bioconda::bbmap=40.02=he046917_0` and
        // `bioconda::minimap2=2.31=h6bd33b9_0`, and the plan drops every build.
        XCTAssertEqual(try exportedSpec("samtools", version: "1.24", environment: "samtools"), "bioconda::samtools=1.24")
        XCTAssertEqual(try exportedSpec("bbmap", version: "40.02", environment: "bbtools", executable: "bbmap.sh"), "bioconda::bbmap=40.02")
        XCTAssertEqual(try exportedSpec("minimap2", version: "2.31", environment: "minimap2"), "bioconda::minimap2=2.31")
        XCTAssertEqual(try exportedSpec("kraken2", version: "2.1.3", environment: "kraken2"), "bioconda::kraken2=2.1.3")
    }

    func testPlanWritesTheBiocondaChannelForCondaForgePackages() throws {
        // The lock installs these from conda-forge.
        XCTAssertEqual(try exportedSpec("openpyxl", version: "3.1.5", environment: "openpyxl"), "bioconda::openpyxl=3.1.5")
        XCTAssertEqual(try exportedSpec("pigz", version: "2.8", environment: "pigz"), "bioconda::pigz=2.8")
        XCTAssertEqual(try exportedSpec("mafft", version: "7.526", environment: "mafft"), "bioconda::mafft=7.526")
    }

    func testPlanWritesThePackToolEnvironmentNameAsThePackage() throws {
        // The lock installs `whatshap` in the `phasing` environment and `gatk4` in `gatk-core`.
        let phasing = plan(managedStep("whatshap", version: "2.3", environment: "phasing"))
        XCTAssertEqual(try environment("phasing", in: phasing).packageSpec, "bioconda::phasing=2.3")
        XCTAssertEqual(
            try environment("phasing", in: phasing).environmentFileContents,
            """
            # Written by Lungfish from the recorded package pin.
            name: lge-phasing
            channels:
              - conda-forge
              - bioconda
            dependencies:
              - bioconda::phasing=2.3

            """
        )
        XCTAssertEqual(
            try environment("phasing", in: phasing).micromambaCreateCommand,
            "micromamba create -y -n lge-phasing -c conda-forge -c bioconda bioconda::phasing=2.3"
        )
        XCTAssertEqual(
            try exportedSpec("gatk", version: "4.6.2.0", environment: "gatk-core"),
            "bioconda::gatk-core=4.6.2.0"
        )
    }

    func testPlanKeepsARecordedPackageAsRecorded() throws {
        let full = plan(managedStep("samtools", version: "1.24", environment: "samtools", package: "bioconda::samtools=1.24=h36b3a25_1"))
        XCTAssertEqual(try environment("samtools", in: full).packageSpec, "bioconda::samtools=1.24=h36b3a25_1")
        // Older records of the pack tools kept the native tool's source package, which is no conda spec.
        let bare = plan(managedStep("ivar", version: "1.4.4", environment: "ivar", package: "ivar"))
        XCTAssertEqual(try environment("ivar", in: bare).packageSpec, "ivar")
    }

    func testPlanWritesTheBarePackageForAnUnknownVersion() throws {
        XCTAssertEqual(try exportedSpec("samtools", version: "unknown", environment: "samtools"), "samtools")
        XCTAssertEqual(try exportedSpec("bbmap", version: "unknown", environment: "bbtools", executable: "bbmap.sh"), "bbmap")
    }

    func testPlanWritesPythonRuntimeAndSourceBuildToolsByTheirIdAtTheRecordedVersion() throws {
        XCTAssertEqual(try exportedSpec("primalscheme3", version: "3.3.0+lge.5", environment: "primalscheme3"), "bioconda::primalscheme3=3.3.0+lge.5")
        XCTAssertEqual(try exportedSpec("bracken", version: "1.0.0", environment: "bracken"), "bioconda::bracken=1.0.0")
    }

    func testTheFirstSpecOfAnEnvironmentWinsWhenTwoStepsDisagree() throws {
        let plan = plan(
            managedStep("samtools", version: "1.23", environment: "samtools", package: "bioconda::samtools=1.23=aaaaaaa_0"),
            managedStep("samtools", version: "1.24", environment: "samtools", package: "bioconda::samtools=1.24=h36b3a25_1")
        )
        XCTAssertEqual(plan.environments.map(\.name), ["samtools"])
        XCTAssertEqual(plan.environments.map(\.packageSpec), ["bioconda::samtools=1.23=aaaaaaa_0"])
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

    // MARK: - What the native tool sites record for the package today

    /// BAMPrimerTrimPipeline, ViralVariantCallingPipeline, ManagedMappingPipeline and Minimap2Pipeline
    /// each record `package <spec>` after a native tool's version. The spec is the lock `tools` entry
    /// whose id is the tool's environment name, else the tool's source package. Pack tools are not in
    /// `tools`, so the nine native tools below record their source package, which is no conda spec.
    func testNativePackToolsRecordTheirSourcePackageToday() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        func recordedToday(_ tool: NativeTool) -> String? {
            guard case .managed(let environment, _) = tool.location else { return nil }
            return lock.tool(named: environment)?.packageSpec ?? tool.sourcePackage
        }
        let expected: [(NativeTool, String)] = [
            (.blastn, "ncbi-blast"), (.ribodetector, "ribodetector"), (.lofreq, "lofreq"), (.ivar, "ivar"),
            (.medaka, "medaka"), (.medakaVariant, "medaka"), (.clair3, "clair3"), (.whatshap, "whatshap"),
            (.freyja, "freyja"),
        ]
        for (tool, package) in expected {
            XCTAssertEqual(recordedToday(tool), package, "\(tool)")
        }
        XCTAssertEqual(recordedToday(.samtools), "bioconda::samtools=1.24=h36b3a25_1")
        XCTAssertEqual(recordedToday(.bgzip), "bioconda::htslib=1.24=hd3c6ec9_0")
        XCTAssertEqual(recordedToday(.bbmap), "bioconda::bbmap=40.02=he046917_0")
        let bare = NativeTool.allCases.filter { recordedToday($0)?.contains("::") == false }
        XCTAssertEqual(Set(bare), Set(expected.map(\.0)))
    }
}
