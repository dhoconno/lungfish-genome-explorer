// SPAdesAssemblyPipelineTests.swift - Tests for SPAdes assembly pipeline
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

final class SPAdesAssemblyPipelineTests: XCTestCase {

    // MARK: - SPAdesMode Tests

    func testAllModesHaveFlags() {
        for mode in SPAdesMode.allCases {
            XCTAssertFalse(mode.flag.isEmpty, "\(mode) should have a flag")
            XCTAssertTrue(mode.flag.hasPrefix("--"), "\(mode).flag should start with --")
        }
    }

    func testAllModesHaveDisplayNames() {
        for mode in SPAdesMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode) should have a display name")
        }
    }

    func testModeRawValues() {
        XCTAssertEqual(SPAdesMode.isolate.rawValue, "isolate")
        XCTAssertEqual(SPAdesMode.meta.rawValue, "meta")
        XCTAssertEqual(SPAdesMode.plasmid.rawValue, "plasmid")
        XCTAssertEqual(SPAdesMode.rna.rawValue, "rna")
        XCTAssertEqual(SPAdesMode.biosyntheticSPAdes.rawValue, "bio")
    }

    func testModeFlagMapping() {
        XCTAssertEqual(SPAdesMode.isolate.flag, "--isolate")
        XCTAssertEqual(SPAdesMode.meta.flag, "--meta")
        XCTAssertEqual(SPAdesMode.plasmid.flag, "--plasmid")
        XCTAssertEqual(SPAdesMode.rna.flag, "--rna")
        XCTAssertEqual(SPAdesMode.biosyntheticSPAdes.flag, "--bio")
    }

    func testModeCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for mode in SPAdesMode.allCases {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(SPAdesMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    // MARK: - SPAdesAssemblyConfig Tests

    func testDefaultConfig() {
        let config = SPAdesAssemblyConfig(
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            projectName: "test"
        )
        XCTAssertEqual(config.mode, .isolate)
        XCTAssertEqual(config.memoryGB, 16)
        XCTAssertEqual(config.threads, 4)
        XCTAssertEqual(config.minContigLength, 200)
        XCTAssertFalse(config.skipErrorCorrection)
        XCTAssertNil(config.kmerSizes)
        XCTAssertTrue(config.forwardReads.isEmpty)
        XCTAssertTrue(config.reverseReads.isEmpty)
        XCTAssertTrue(config.unpairedReads.isEmpty)
    }

    func testAllInputFiles() {
        let config = SPAdesAssemblyConfig(
            forwardReads: [URL(fileURLWithPath: "/R1.fq.gz")],
            reverseReads: [URL(fileURLWithPath: "/R2.fq.gz")],
            unpairedReads: [URL(fileURLWithPath: "/unpaired.fq.gz")],
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            projectName: "test"
        )
        XCTAssertEqual(config.allInputFiles.count, 3)
    }

    // MARK: - Command Construction Tests

    @available(macOS 26, *)
    func testBuildCommandIsolateMode() {
        let pipeline = SPAdesAssemblyPipeline()
        let config = SPAdesAssemblyConfig(
            mode: .isolate,
            forwardReads: [URL(fileURLWithPath: "/input/R1.fq.gz")],
            reverseReads: [URL(fileURLWithPath: "/input/R2.fq.gz")],
            memoryGB: 16,
            threads: 8,
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            projectName: "test"
        )
        let workspace = SPAdesWorkspace(
            tempDir: URL(fileURLWithPath: "/tmp/workspace"),
            inputDir: URL(fileURLWithPath: "/tmp/workspace/input"),
            outputDir: URL(fileURLWithPath: "/tmp/output"),
            mounts: [],
            fileNameMap: [:]
        )

        let command = pipeline.buildCommand(config: config, workspace: workspace)

        XCTAssertEqual(command[0], "spades.py")
        XCTAssertTrue(command.contains("--isolate"))
        XCTAssertTrue(command.contains("-1"))
        XCTAssertTrue(command.contains("/input/R1.fq.gz"))
        XCTAssertTrue(command.contains("-2"))
        XCTAssertTrue(command.contains("/input/R2.fq.gz"))
        XCTAssertTrue(command.contains("--memory"))
        XCTAssertTrue(command.contains("16"))
        XCTAssertTrue(command.contains("--threads"))
        XCTAssertTrue(command.contains("8"))
        XCTAssertTrue(command.contains("-o"))
        XCTAssertTrue(command.contains("/output"))
    }

    @available(macOS 26, *)
    func testBuildCommandMetaMode() {
        let pipeline = SPAdesAssemblyPipeline()
        let config = SPAdesAssemblyConfig(
            mode: .meta,
            unpairedReads: [URL(fileURLWithPath: "/input/reads.fq.gz")],
            memoryGB: 32,
            threads: 16,
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            projectName: "meta"
        )
        let workspace = SPAdesWorkspace(
            tempDir: URL(fileURLWithPath: "/tmp/workspace"),
            inputDir: URL(fileURLWithPath: "/tmp/workspace/input"),
            outputDir: URL(fileURLWithPath: "/tmp/output"),
            mounts: [],
            fileNameMap: [:]
        )

        let command = pipeline.buildCommand(config: config, workspace: workspace)

        XCTAssertTrue(command.contains("--meta"))
        XCTAssertTrue(command.contains("-s"))
        XCTAssertTrue(command.contains("/input/reads.fq.gz"))
        XCTAssertTrue(command.contains("32")) // memory
    }

    @available(macOS 26, *)
    func testBuildCommandCustomKmers() {
        let pipeline = SPAdesAssemblyPipeline()
        let config = SPAdesAssemblyConfig(
            kmerSizes: [21, 33, 55],
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            projectName: "test"
        )
        let workspace = SPAdesWorkspace(
            tempDir: URL(fileURLWithPath: "/tmp/workspace"),
            inputDir: URL(fileURLWithPath: "/tmp/workspace/input"),
            outputDir: URL(fileURLWithPath: "/tmp/output"),
            mounts: [],
            fileNameMap: [:]
        )

        let command = pipeline.buildCommand(config: config, workspace: workspace)

        XCTAssertTrue(command.contains("-k"))
        XCTAssertTrue(command.contains("21,33,55"))
    }

    @available(macOS 26, *)
    func testBuildCommandSkipErrorCorrection() {
        let pipeline = SPAdesAssemblyPipeline()
        let config = SPAdesAssemblyConfig(
            skipErrorCorrection: true,
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            projectName: "test"
        )
        let workspace = SPAdesWorkspace(
            tempDir: URL(fileURLWithPath: "/tmp/workspace"),
            inputDir: URL(fileURLWithPath: "/tmp/workspace/input"),
            outputDir: URL(fileURLWithPath: "/tmp/output"),
            mounts: [],
            fileNameMap: [:]
        )

        let command = pipeline.buildCommand(config: config, workspace: workspace)

        XCTAssertTrue(command.contains("--only-assembler"))
    }

    @available(macOS 26, *)
    func testBuildCommandNoErrorCorrectionFlag() {
        let pipeline = SPAdesAssemblyPipeline()
        let config = SPAdesAssemblyConfig(
            skipErrorCorrection: false,
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            projectName: "test"
        )
        let workspace = SPAdesWorkspace(
            tempDir: URL(fileURLWithPath: "/tmp/workspace"),
            inputDir: URL(fileURLWithPath: "/tmp/workspace/input"),
            outputDir: URL(fileURLWithPath: "/tmp/output"),
            mounts: [],
            fileNameMap: [:]
        )

        let command = pipeline.buildCommand(config: config, workspace: workspace)

        XCTAssertFalse(command.contains("--only-assembler"))
    }

    @available(macOS 26, *)
    func testCommandNeverContainsCareful() {
        let pipeline = SPAdesAssemblyPipeline()
        for mode in SPAdesMode.allCases {
            let config = SPAdesAssemblyConfig(
                mode: mode,
                outputDirectory: URL(fileURLWithPath: "/tmp"),
                projectName: "test"
            )
            let workspace = SPAdesWorkspace(
                tempDir: URL(fileURLWithPath: "/tmp/workspace"),
                inputDir: URL(fileURLWithPath: "/tmp/workspace/input"),
                outputDir: URL(fileURLWithPath: "/tmp/output"),
                mounts: [],
                fileNameMap: [:]
            )

            let command = pipeline.buildCommand(config: config, workspace: workspace)
            XCTAssertFalse(command.contains("--careful"), "--careful is deprecated in SPAdes 4.0")
        }
    }

    @available(macOS 26, *)
    func testBuildCommandMultiplePairedLibraries() {
        let pipeline = SPAdesAssemblyPipeline()
        let config = SPAdesAssemblyConfig(
            forwardReads: [
                URL(fileURLWithPath: "/input/lib1_R1.fq.gz"),
                URL(fileURLWithPath: "/input/lib2_R1.fq.gz"),
            ],
            reverseReads: [
                URL(fileURLWithPath: "/input/lib1_R2.fq.gz"),
                URL(fileURLWithPath: "/input/lib2_R2.fq.gz"),
            ],
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            projectName: "test"
        )
        let workspace = SPAdesWorkspace(
            tempDir: URL(fileURLWithPath: "/tmp/workspace"),
            inputDir: URL(fileURLWithPath: "/tmp/workspace/input"),
            outputDir: URL(fileURLWithPath: "/tmp/output"),
            mounts: [],
            fileNameMap: [:]
        )

        let command = pipeline.buildCommand(config: config, workspace: workspace)

        // Should have two -1/-2 pairs
        let r1Count = command.filter { $0 == "-1" }.count
        let r2Count = command.filter { $0 == "-2" }.count
        XCTAssertEqual(r1Count, 2)
        XCTAssertEqual(r2Count, 2)
    }

    // MARK: - SPAdesAssemblyResult Tests

    func testResultStructFields() {
        let stats = AssemblyStatisticsCalculator.computeFromLengths([1000, 500])
        let result = SPAdesAssemblyResult(
            contigsPath: URL(fileURLWithPath: "/output/contigs.fasta"),
            scaffoldsPath: URL(fileURLWithPath: "/output/scaffolds.fasta"),
            graphPath: URL(fileURLWithPath: "/output/assembly_graph.gfa"),
            logPath: URL(fileURLWithPath: "/output/spades.log"),
            paramsPath: URL(fileURLWithPath: "/output/params.txt"),
            statistics: stats,
            spadesVersion: "4.0.0",
            wallTimeSeconds: 120.5,
            commandLine: "spades.py --isolate -o /output",
            exitCode: 0
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.spadesVersion, "4.0.0")
        XCTAssertEqual(result.wallTimeSeconds, 120.5, accuracy: 0.1)
        XCTAssertNotNil(result.scaffoldsPath)
        XCTAssertNotNil(result.graphPath)
        XCTAssertNotNil(result.paramsPath)
        XCTAssertEqual(result.statistics.contigCount, 2)
    }

    // MARK: - SPAdesPipelineError Tests

    func testPipelineErrorDescriptions() {
        let errors: [SPAdesPipelineError] = [
            .noInputFiles,
            .inputFileNotFound(URL(fileURLWithPath: "/tmp/missing.fq.gz")),
            .pairedReadsMismatch(forwardCount: 2, reverseCount: 1),
            .runtimeUnavailable("No Apple Silicon"),
            .spadesError(exitCode: 1, message: "Out of memory", suggestion: "Increase memory"),
            .outputNotFound("contigs.fasta"),
            .cancelled,
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) should have a description")
        }
    }

    func testPipelineErrorRecoverySuggestions() {
        XCTAssertNotNil(SPAdesPipelineError.noInputFiles.recoverySuggestion)
        XCTAssertNotNil(SPAdesPipelineError.runtimeUnavailable("test").recoverySuggestion)
        XCTAssertNil(SPAdesPipelineError.cancelled.recoverySuggestion)

        let mismatchErr = SPAdesPipelineError.pairedReadsMismatch(forwardCount: 3, reverseCount: 1)
        XCTAssertNotNil(mismatchErr.recoverySuggestion)
        XCTAssertTrue(mismatchErr.errorDescription?.contains("3") ?? false)
        XCTAssertTrue(mismatchErr.errorDescription?.contains("1") ?? false)

        let spadesErr = SPAdesPipelineError.spadesError(
            exitCode: 137, message: "OOM killed", suggestion: "Reduce memory usage"
        )
        XCTAssertEqual(spadesErr.recoverySuggestion, "Reduce memory usage")
    }

    // MARK: - Image Reference Tests

    @available(macOS 26, *)
    func testSPAdesImageReference() {
        let ref = SPAdesAssemblyPipeline.spadesImageReference
        XCTAssertTrue(ref.contains("spades"), "Image reference should contain 'spades'")
        XCTAssertTrue(ref.contains("biocontainers"), "Image reference should be from biocontainers")
        XCTAssertTrue(ref.contains("4.0.0"), "Image reference should specify version")
    }

    // MARK: - DefaultContainerImages Integration

    func testSPAdesImageInCatalog() {
        let spadesImage = DefaultContainerImages.image(id: "spades")
        XCTAssertNotNil(spadesImage, "SPAdes should be in the image catalog")
        XCTAssertEqual(spadesImage?.name, "SPAdes")
        XCTAssertEqual(spadesImage?.category, .optional)
        XCTAssertEqual(spadesImage?.purpose, .assembly)
        XCTAssertEqual(spadesImage?.version, "4.0.0")
        XCTAssertTrue(spadesImage?.supportedExtensions.contains("fastq") ?? false)
    }

    func testAllImagesHaveRequiredFields() {
        for image in DefaultContainerImages.all {
            XCTAssertFalse(image.id.isEmpty, "Image \(image.name) should have an ID")
            XCTAssertFalse(image.name.isEmpty, "Image ID \(image.id) should have a name")
            XCTAssertFalse(image.reference.isEmpty, "Image \(image.name) should have a reference")
        }
    }

    func testCoreImagesExist() {
        let coreImages = DefaultContainerImages.coreImages
        XCTAssertGreaterThanOrEqual(coreImages.count, 5)

        let coreIds = Set(coreImages.map(\.id))
        XCTAssertTrue(coreIds.contains("samtools"))
        XCTAssertTrue(coreIds.contains("bcftools"))
        XCTAssertTrue(coreIds.contains("htslib"))
    }

    func testBaseImageIsMiniforge3() {
        XCTAssertTrue(
            DefaultContainerImages.baseImage.contains("miniforge3"),
            "Base image should be miniforge3 (not mambaforge)"
        )
    }

    // MARK: - SPAdesWorkspace Tests

    func testWorkspaceStructure() {
        let workspace = SPAdesWorkspace(
            tempDir: URL(fileURLWithPath: "/tmp/ws"),
            inputDir: URL(fileURLWithPath: "/tmp/ws/input"),
            outputDir: URL(fileURLWithPath: "/tmp/output"),
            mounts: [
                MountBinding(source: URL(fileURLWithPath: "/tmp/ws/input"), destination: "/input", readOnly: true),
                MountBinding(source: URL(fileURLWithPath: "/tmp/output"), destination: "/output", readOnly: false),
            ],
            fileNameMap: [:]
        )

        XCTAssertEqual(workspace.mounts.count, 2)
        XCTAssertTrue(workspace.mounts[0].readOnly)
        XCTAssertFalse(workspace.mounts[1].readOnly)
    }
}
