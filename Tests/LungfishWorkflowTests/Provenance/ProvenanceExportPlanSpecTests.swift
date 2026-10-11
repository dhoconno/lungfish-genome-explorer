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

    func testPlanNamesThePackageOfAPackToolAndNotItsEnvironment() throws {
        // The lock installs `whatshap` in the `phasing` environment and `gatk4` in `gatk-core`. The
        // build and the channel are still missing here, and the spec tests below fix them.
        let phasing = plan(managedStep("whatshap", version: "2.3", environment: "phasing"))
        XCTAssertEqual(try environment("phasing", in: phasing).packageSpec, "bioconda::whatshap=2.3")
        XCTAssertEqual(
            try environment("phasing", in: phasing).environmentFileContents,
            """
            # Written by Lungfish from the recorded package pin.
            name: lge-phasing
            channels:
              - conda-forge
              - bioconda
            dependencies:
              - bioconda::whatshap=2.3

            """
        )
        XCTAssertEqual(
            try environment("phasing", in: phasing).micromambaCreateCommand,
            "micromamba create -y -n lge-phasing -c conda-forge -c bioconda bioconda::whatshap=2.3"
        )
        XCTAssertEqual(
            try exportedSpec("gatk", version: "4.6.2.0", environment: "gatk-core"),
            "bioconda::gatk4=4.6.2.0"
        )
        XCTAssertEqual(
            try exportedSpec("whatshap", version: "unknown", environment: "phasing"),
            "whatshap",
            "an unknown version writes the bare package, never the environment name"
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
