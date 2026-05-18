// Minimap2ResultSidecarTests.swift - Tests for Minimap2 alignment result persistence
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

private func jsonObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

final class Minimap2ResultSidecarTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-minimap2-sidecar-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeResult() -> Minimap2Result {
        Minimap2Result(
            bamURL: tempDir.appendingPathComponent("sample.sorted.bam"),
            baiURL: tempDir.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 10_000,
            mappedReads: 9_500,
            unmappedReads: 500,
            wallClockSeconds: 45.2
        )
    }

    func testExistsReturnsFalseForMissingFile() {
        XCTAssertFalse(Minimap2Result.exists(in: tempDir))
    }

    func testExistsReturnsTrueAfterSave() throws {
        let result = makeResult()
        try result.save(to: tempDir, toolVersion: "2.28")
        XCTAssertTrue(Minimap2Result.exists(in: tempDir))
    }

    func testSaveWritesJSONFile() throws {
        let result = makeResult()
        try result.save(to: tempDir, toolVersion: "2.28")
        let jsonURL = tempDir.appendingPathComponent("alignment-result.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))
        let data = try Data(contentsOf: jsonURL)
        XCTAssertGreaterThan(data.count, 0)
    }

    func testSaveAndLoadRoundTrip() throws {
        let result = makeResult()
        try result.save(to: tempDir, toolVersion: "2.28")
        XCTAssertTrue(Minimap2Result.exists(in: tempDir))
        let loaded = try Minimap2Result.load(from: tempDir)

        XCTAssertEqual(loaded.bamURL.lastPathComponent, "sample.sorted.bam")
        XCTAssertEqual(loaded.baiURL.lastPathComponent, "sample.sorted.bam.bai")
        XCTAssertEqual(loaded.totalReads, 10_000)
        XCTAssertEqual(loaded.mappedReads, 9_500)
        XCTAssertEqual(loaded.unmappedReads, 500)
        XCTAssertEqual(loaded.wallClockSeconds, 45.2, accuracy: 1e-9)
    }

    func testLoadedURLsAreRelativeToDirectory() throws {
        let result = makeResult()
        try result.save(to: tempDir, toolVersion: "2.28")
        let loaded = try Minimap2Result.load(from: tempDir)

        // Compare via path strings to avoid trailing-slash URL discrepancy from
        // deletingLastPathComponent(). Trim "/" as CharacterSet scalar.
        XCTAssertEqual(
            loaded.bamURL.deletingLastPathComponent().path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            tempDir.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        XCTAssertEqual(
            loaded.baiURL.deletingLastPathComponent().path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            tempDir.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
    }

    func testLoadThrowsWhenSidecarMissing() {
        XCTAssertThrowsError(try Minimap2Result.load(from: tempDir)) { error in
            XCTAssertTrue(error is Minimap2ResultLoadError)
        }
    }

    func testJSONContainsToolVersion() throws {
        let result = makeResult()
        try result.save(to: tempDir, toolVersion: "2.28-r1209")
        let jsonURL = tempDir.appendingPathComponent("alignment-result.json")
        let text = try String(contentsOf: jsonURL, encoding: .utf8)
        XCTAssertTrue(text.contains("2.28-r1209"), "JSON should contain the tool version")
    }

    func testPipelineRunWritesMappingProvenanceSidecar() async throws {
        let fixture = try Minimap2PipelineFixture(root: tempDir)

        let readsURL = tempDir.appendingPathComponent("reads.fastq")
        let referenceURL = tempDir.appendingPathComponent("reference.fa")
        let outputDirectory = tempDir.appendingPathComponent("mapping-output", isDirectory: true)
        try "@read-1\nACGT\n+\nIIII\n".write(to: readsURL, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let pipeline = Minimap2Pipeline(
            condaManager: fixture.condaManager,
            runner: fixture.runner
        )
        let result = try await pipeline.run(
            config: Minimap2Config(
                inputFiles: [readsURL],
                referenceURL: referenceURL,
                preset: .mapONT,
                threads: 4,
                includeSecondary: false,
                includeSupplementary: true,
                minMappingQuality: 0,
                isPairedEnd: false,
                outputDirectory: outputDirectory,
                sampleName: "sample",
                advancedArguments: ["--eqx"]
            )
        )

        let sidecarURL = outputDirectory.appendingPathComponent(MappingProvenance.filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        let provenance = try XCTUnwrap(MappingProvenance.load(from: outputDirectory))
        let micromambaPath = await fixture.condaManager.micromambaPath.path
        XCTAssertEqual(provenance.workflowName, "lungfish map")
        XCTAssertEqual(provenance.mapper, .minimap2)
        XCTAssertEqual(provenance.modeID, Minimap2Preset.mapONT.rawValue)
        XCTAssertEqual(provenance.sampleName, "sample")
        XCTAssertEqual(provenance.mapperVersion, "2.28")
        XCTAssertEqual(provenance.samtoolsVersion, "1.21")
        XCTAssertEqual(provenance.exitStatus, 0)
        XCTAssertEqual(provenance.advancedArguments, ["--eqx"])
        XCTAssertEqual(provenance.steps.map(\.toolName), ["minimap2", "samtools", "samtools", "samtools"])
        XCTAssertEqual(provenance.mapperInvocation.argv.first, micromambaPath)
        XCTAssertEqual(provenance.mapperInvocation.durableReplayArgv?.first, micromambaPath)
        XCTAssertEqual(provenance.steps.first?.command.first, micromambaPath)
        XCTAssertEqual(provenance.steps.first?.durableReplayArgv?.first, micromambaPath)
        XCTAssertTrue(provenance.steps.allSatisfy { $0.exitCode == 0 })
        XCTAssertTrue(provenance.steps.allSatisfy { $0.wallTime != nil })
        XCTAssertTrue(provenance.inputFiles.contains { $0.path == readsURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(provenance.inputFiles.contains { $0.path == referenceURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(provenance.outputFiles.contains { $0.path == result.bamURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertTrue(provenance.outputFiles.contains { $0.path == result.baiURL.path && $0.sha256 != nil && $0.sizeBytes != nil })

        let resolved = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: outputDirectory))
        XCTAssertEqual(resolved.sidecarURL.lastPathComponent, MappingProvenance.filename)
        XCTAssertEqual(resolved.envelope.workflowName, "lungfish map")
        XCTAssertEqual(resolved.envelope.toolName, "minimap2")
        XCTAssertEqual(resolved.envelope.exitStatus, 0)
        XCTAssertEqual(resolved.envelope.argv.first, micromambaPath)
        XCTAssertTrue(resolved.envelope.argv.contains("--eqx"))
        XCTAssertTrue(resolved.envelope.outputs.contains { $0.path == result.bamURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertTrue(resolved.envelope.outputs.contains { $0.path == result.baiURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil })
    }

    func testPipelineRunUsesDurableSourceInputsInProvenanceWhenExecutingResolvedFiles() async throws {
        let fixture = try Minimap2PipelineFixture(root: tempDir)

        let sourceBundleURL = tempDir.appendingPathComponent("source.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        let durableReadsURL = sourceBundleURL.appendingPathComponent("reads.fastq")
        let resolvedTempDir = tempDir.appendingPathComponent("resolved-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: resolvedTempDir, withIntermediateDirectories: true)
        let resolvedReadsURL = resolvedTempDir.appendingPathComponent("materialized.fastq")
        let referenceURL = tempDir.appendingPathComponent("reference.fa")
        let outputDirectory = tempDir.appendingPathComponent("mapping-output-durable", isDirectory: true)
        try "@read-1\nACGT\n+\nIIII\n".write(to: durableReadsURL, atomically: true, encoding: .utf8)
        try "@read-1\nACGT\n+\nIIII\n".write(to: resolvedReadsURL, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let pipeline = Minimap2Pipeline(
            condaManager: fixture.condaManager,
            runner: fixture.runner
        )
        _ = try await pipeline.run(
            config: Minimap2Config(
                inputFiles: [resolvedReadsURL],
                referenceURL: referenceURL,
                preset: .mapONT,
                threads: 2,
                includeSecondary: false,
                includeSupplementary: true,
                minMappingQuality: 0,
                isPairedEnd: false,
                outputDirectory: outputDirectory,
                sampleName: "sample",
                advancedArguments: [],
                provenanceInputFiles: [durableReadsURL]
            )
        )

        try FileManager.default.removeItem(at: resolvedTempDir)

        let provenance = try XCTUnwrap(MappingProvenance.load(from: outputDirectory))
        XCTAssertFalse(
            provenance.mapperInvocation.argv.contains(durableReadsURL.path),
            "Exact mapper argv must preserve the execution input, not substitute durable replay paths"
        )
        XCTAssertTrue(provenance.mapperInvocation.argv.contains(resolvedReadsURL.path))
        XCTAssertTrue(provenance.inputFASTQPaths.contains(durableReadsURL.path))
        XCTAssertFalse(provenance.inputFASTQPaths.contains(resolvedReadsURL.path))
        XCTAssertTrue(provenance.inputFiles.contains { $0.path == durableReadsURL.path && $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertFalse(
            provenance.inputFiles.contains { $0.path == resolvedReadsURL.path },
            "Final mapping provenance must not point at deleted materialized FASTQs"
        )
        XCTAssertTrue(provenance.steps.first?.inputs.contains { $0.path == durableReadsURL.path } == true)
        XCTAssertFalse(provenance.steps.first?.inputs.contains { $0.path == resolvedReadsURL.path } == true)
        XCTAssertTrue(
            provenance.steps.flatMap(\.command).contains(resolvedReadsURL.path),
            "Step command must preserve the exact execution input"
        )

        let provenanceJSON = try jsonObject(at: outputDirectory.appendingPathComponent(MappingProvenance.filename))
        let mapperInvocation = try XCTUnwrap(provenanceJSON["mapperInvocation"] as? [String: Any])
        let durableMapperArgv = try XCTUnwrap(mapperInvocation["durableReplayArgv"] as? [String])
        XCTAssertFalse(durableMapperArgv.contains(resolvedReadsURL.path))
        XCTAssertTrue(durableMapperArgv.contains(durableReadsURL.path))
        let stepsJSON = try XCTUnwrap(provenanceJSON["steps"] as? [[String: Any]])
        let durableStepArgv = try XCTUnwrap(stepsJSON.first?["durableReplayArgv"] as? [String])
        XCTAssertFalse(durableStepArgv.contains(resolvedReadsURL.path))
        XCTAssertTrue(durableStepArgv.contains(durableReadsURL.path))

        let resolved = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: outputDirectory))
        XCTAssertTrue(
            resolved.envelope.argv.contains(resolvedReadsURL.path),
            "Canonical mapping argv must preserve the exact execution input"
        )
        XCTAssertFalse(
            resolved.envelope.reproducibleCommand.contains(resolvedReadsURL.path),
            "Canonical mapping reproducible command must not expose deleted materialized FASTQ paths"
        )
        XCTAssertTrue(resolved.envelope.reproducibleCommand.contains(durableReadsURL.path))
        XCTAssertTrue(resolved.envelope.files.contains { $0.path == durableReadsURL.path && $0.role == .input })
        XCTAssertFalse(
            resolved.envelope.files.contains { $0.path == resolvedReadsURL.path && $0.role == .input },
            "Canonical provenance must preserve the durable scientific input, not the deleted execution copy"
        )
        XCTAssertFalse(
            resolved.envelope.steps.flatMap(\.argv).contains(durableReadsURL.path),
            "Canonical step argv must not substitute durable replay paths into exact execution argv"
        )
        XCTAssertTrue(resolved.envelope.steps.flatMap(\.argv).contains(resolvedReadsURL.path))
        XCTAssertFalse(
            resolved.envelope.steps.map(\.reproducibleCommand).contains { $0.contains(resolvedReadsURL.path) },
            "Canonical step reproducible commands must not expose deleted materialized FASTQ paths"
        )
        XCTAssertTrue(
            resolved.envelope.steps.map(\.reproducibleCommand).contains { $0.contains(durableReadsURL.path) },
            "Canonical minimap2 step reproducible command should use the durable scientific input path"
        )
    }

    func testPipelineRunWritesFailedProvenanceAndThrowsWhenFlagstatFails() async throws {
        let fixture = try Minimap2PipelineFixture(root: tempDir, flagstatExitCode: 9)

        let readsURL = tempDir.appendingPathComponent("reads.fastq")
        let referenceURL = tempDir.appendingPathComponent("reference.fa")
        let outputDirectory = tempDir.appendingPathComponent("mapping-output-flagstat-failure", isDirectory: true)
        try "@read-1\nACGT\n+\nIIII\n".write(to: readsURL, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let pipeline = Minimap2Pipeline(
            condaManager: fixture.condaManager,
            runner: fixture.runner
        )

        do {
            _ = try await pipeline.run(
                config: Minimap2Config(
                    inputFiles: [readsURL],
                    referenceURL: referenceURL,
                    preset: .mapONT,
                    threads: 2,
                    isPairedEnd: false,
                    outputDirectory: outputDirectory,
                    sampleName: "sample"
                )
            )
            XCTFail("Expected samtools flagstat failure")
        } catch Minimap2PipelineError.statsFailed {
            // Expected.
        }

        let provenance = try XCTUnwrap(MappingProvenance.load(from: outputDirectory))
        XCTAssertEqual(provenance.exitStatus, 9)
        XCTAssertEqual(provenance.steps.last?.toolName, "samtools")
        XCTAssertEqual(provenance.steps.last?.exitCode, 9)
        XCTAssertEqual(provenance.steps.last?.stderr, "flagstat failed\n")

        let resolved = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: outputDirectory))
        XCTAssertEqual(resolved.envelope.exitStatus, 9)
    }

    func testPipelineRunWritesFailedProvenanceWhenCondaLaunchThrows() async throws {
        let fixture = try Minimap2PipelineFixture(root: tempDir, installBundledMicromamba: false)

        let readsURL = tempDir.appendingPathComponent("reads.fastq")
        let referenceURL = tempDir.appendingPathComponent("reference.fa")
        let outputDirectory = tempDir.appendingPathComponent("mapping-output-conda-throw", isDirectory: true)
        try "@read-1\nACGT\n+\nIIII\n".write(to: readsURL, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let pipeline = Minimap2Pipeline(
            condaManager: fixture.condaManager,
            runner: fixture.runner
        )
        do {
            _ = try await pipeline.run(
                config: Minimap2Config(
                    inputFiles: [readsURL],
                    referenceURL: referenceURL,
                    preset: .mapONT,
                    threads: 2,
                    isPairedEnd: false,
                    outputDirectory: outputDirectory,
                    sampleName: "sample"
                )
            )
            XCTFail("Expected minimap2 conda launch failure")
        } catch Minimap2PipelineError.alignmentFailed {
            // Expected.
        }

        let provenance = try XCTUnwrap(MappingProvenance.load(from: outputDirectory))
        XCTAssertEqual(provenance.exitStatus, -1)
        XCTAssertEqual(provenance.steps.map(\.toolName), ["minimap2"])
        XCTAssertEqual(provenance.steps.first?.exitCode, -1)
        XCTAssertTrue(provenance.outputFiles.isEmpty)
        XCTAssertTrue(provenance.steps.first?.outputs.isEmpty == true)
        XCTAssertTrue(provenance.steps.first?.stderr?.contains("Micromamba") == true)
    }

    func testPipelineRunDoesNotRecordPartialSAMAfterMinimap2FailureCleanup() async throws {
        let fixture = try Minimap2PipelineFixture(root: tempDir, minimap2ExitCode: 7)

        let readsURL = tempDir.appendingPathComponent("reads.fastq")
        let referenceURL = tempDir.appendingPathComponent("reference.fa")
        let outputDirectory = tempDir.appendingPathComponent("mapping-output-minimap2-failure", isDirectory: true)
        try "@read-1\nACGT\n+\nIIII\n".write(to: readsURL, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let pipeline = Minimap2Pipeline(
            condaManager: fixture.condaManager,
            runner: fixture.runner
        )
        do {
            _ = try await pipeline.run(
                config: Minimap2Config(
                    inputFiles: [readsURL],
                    referenceURL: referenceURL,
                    preset: .mapONT,
                    threads: 2,
                    isPairedEnd: false,
                    outputDirectory: outputDirectory,
                    sampleName: "sample"
                )
            )
            XCTFail("Expected minimap2 failure")
        } catch Minimap2PipelineError.alignmentFailed {
            // Expected.
        }

        let partialSAM = outputDirectory.appendingPathComponent("aligned.sam")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialSAM.path))
        let provenance = try XCTUnwrap(MappingProvenance.load(from: outputDirectory))
        XCTAssertEqual(provenance.exitStatus, 7)
        XCTAssertEqual(provenance.steps.map(\.toolName), ["minimap2"])
        XCTAssertTrue(provenance.outputFiles.isEmpty)
        XCTAssertTrue(provenance.steps.first?.outputs.isEmpty == true)

        let resolved = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: outputDirectory))
        XCTAssertFalse(resolved.envelope.files.contains { $0.path == partialSAM.path })
        XCTAssertTrue(resolved.envelope.steps.first?.outputs.isEmpty == true)
    }

    func testPipelineRunUsesStoredReplayInputWhenDurableInputIsVirtualBundle() async throws {
        let fixture = try Minimap2PipelineFixture(root: tempDir)

        let sourceBundleURL = tempDir.appendingPathComponent("virtual-source.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        let manifestURL = sourceBundleURL.appendingPathComponent("derived-manifest.json")
        let rootReadsURL = tempDir.appendingPathComponent("root.fastq")
        let resolvedTempDir = tempDir.appendingPathComponent("resolved-virtual", isDirectory: true)
        try FileManager.default.createDirectory(at: resolvedTempDir, withIntermediateDirectories: true)
        let resolvedReadsURL = resolvedTempDir.appendingPathComponent("materialized.fastq")
        let referenceURL = tempDir.appendingPathComponent("reference.fa")
        let outputDirectory = tempDir.appendingPathComponent("mapping-output-virtual-replay", isDirectory: true)
        try "{}\n".write(to: manifestURL, atomically: true, encoding: .utf8)
        try "@read-root\nACGT\n+\nIIII\n".write(to: rootReadsURL, atomically: true, encoding: .utf8)
        try "@read-1\nACGT\n+\nIIII\n".write(to: resolvedReadsURL, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let pipeline = Minimap2Pipeline(
            condaManager: fixture.condaManager,
            runner: fixture.runner
        )
        _ = try await pipeline.run(
            config: Minimap2Config(
                inputFiles: [resolvedReadsURL],
                referenceURL: referenceURL,
                preset: .mapONT,
                threads: 2,
                isPairedEnd: false,
                outputDirectory: outputDirectory,
                sampleName: "sample",
                provenanceInputFiles: [sourceBundleURL],
                provenanceInputFileRecords: [
                    ProvenanceRecorder.fileRecord(url: manifestURL, role: .input),
                    ProvenanceRecorder.fileRecord(url: rootReadsURL, format: .fastq, role: .input),
                ]
            )
        )

        try FileManager.default.removeItem(at: resolvedTempDir)

        let provenance = try XCTUnwrap(MappingProvenance.load(from: outputDirectory))
        let durableArgv = try XCTUnwrap(provenance.mapperInvocation.durableReplayArgv)
        XCTAssertFalse(durableArgv.contains(sourceBundleURL.path))
        XCTAssertFalse(durableArgv.contains(resolvedReadsURL.path))
        let replayInput = try XCTUnwrap(durableArgv.first { $0.hasSuffix("materialized.fastq") })
        XCTAssertTrue(replayInput.contains("/provenance/intermediates/minimap2-inputs/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replayInput))
        XCTAssertTrue(provenance.inputFiles.contains { $0.path == replayInput && $0.sha256 != nil && $0.sizeBytes != nil })

        let resolved = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: outputDirectory))
        XCTAssertFalse(resolved.envelope.reproducibleCommand.contains(sourceBundleURL.path))
        XCTAssertFalse(resolved.envelope.reproducibleCommand.contains(resolvedReadsURL.path))
        XCTAssertTrue(resolved.envelope.reproducibleCommand.contains(replayInput))
        XCTAssertTrue(resolved.envelope.files.contains { $0.path == replayInput && $0.role == .input })
    }

    func testPipelineRunWritesFailedProvenanceWhenSamtoolsSortThrows() async throws {
        let fixture = try Minimap2PipelineFixture(root: tempDir, installSamtools: false)

        let readsURL = tempDir.appendingPathComponent("reads.fastq")
        let referenceURL = tempDir.appendingPathComponent("reference.fa")
        let outputDirectory = tempDir.appendingPathComponent("mapping-output-sort-throw", isDirectory: true)
        try "@read-1\nACGT\n+\nIIII\n".write(to: readsURL, atomically: true, encoding: .utf8)
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let pipeline = Minimap2Pipeline(
            condaManager: fixture.condaManager,
            runner: fixture.runner
        )
        do {
            _ = try await pipeline.run(
                config: Minimap2Config(
                    inputFiles: [readsURL],
                    referenceURL: referenceURL,
                    preset: .mapONT,
                    threads: 2,
                    isPairedEnd: false,
                    outputDirectory: outputDirectory,
                    sampleName: "sample"
                )
            )
            XCTFail("Expected samtools sort launch failure")
        } catch Minimap2PipelineError.sortFailed {
            // Expected.
        }

        let provenance = try XCTUnwrap(MappingProvenance.load(from: outputDirectory))
        XCTAssertEqual(provenance.exitStatus, -1)
        XCTAssertEqual(provenance.steps.map(\.toolName), ["minimap2", "samtools"])
        XCTAssertEqual(provenance.steps.last?.exitCode, -1)
        XCTAssertTrue(provenance.outputFiles.isEmpty)
        XCTAssertTrue(provenance.steps.last?.outputs.isEmpty == true)
        XCTAssertTrue(provenance.steps.last?.stderr?.contains("samtools") == true)
    }
}

private struct Minimap2PipelineFixture {
    let condaManager: CondaManager
    let runner: NativeToolRunner

    init(
        root: URL,
        flagstatExitCode: Int32 = 0,
        minimap2ExitCode: Int32 = 0,
        installBundledMicromamba: Bool = true,
        installSamtools: Bool = true
    ) throws {
        let fm = FileManager.default
        let condaRoot = root.appendingPathComponent("conda", isDirectory: true)
        let bundledMicromamba = root.appendingPathComponent("bundled-micromamba")
        if installBundledMicromamba {
            try Self.micromambaScript(minimap2ExitCode: minimap2ExitCode).write(to: bundledMicromamba, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledMicromamba.path)
        }

        let minimap2Dir = condaRoot.appendingPathComponent("envs/minimap2/bin", isDirectory: true)
        try fm.createDirectory(at: minimap2Dir, withIntermediateDirectories: true)
        let minimap2Executable = minimap2Dir.appendingPathComponent("minimap2")
        try "#!/bin/sh\nexit 0\n".write(to: minimap2Executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: minimap2Executable.path)

        condaManager = CondaManager(
            rootPrefix: condaRoot,
            bundledMicromambaProvider: { installBundledMicromamba ? bundledMicromamba : nil },
            bundledMicromambaVersionProvider: { "1.5.8" }
        )

        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let samtoolsDir = homeDirectory
            .appendingPathComponent(".lungfish/conda/envs/samtools/bin", isDirectory: true)
        try fm.createDirectory(at: samtoolsDir, withIntermediateDirectories: true)
        if installSamtools {
            let samtoolsExecutable = samtoolsDir.appendingPathComponent("samtools")
            try Self.samtoolsScript(flagstatExitCode: flagstatExitCode).write(to: samtoolsExecutable, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: samtoolsExecutable.path)
        }

        runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: homeDirectory)
    }

    private static func micromambaScript(minimap2ExitCode: Int32) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "1.5.8"
          exit 0
        fi

        if [ "$1" = "run" ]; then
          shift
          if [ "$1" = "-n" ]; then
            shift 2
          fi
          tool="$1"
          shift
          if [ "$tool" = "minimap2" ] && [ "$1" = "--version" ]; then
            echo "minimap2 2.28-r1209"
            exit 0
          fi
          if [ "$tool" = "minimap2" ]; then
            out=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then
                out="$2"
                shift 2
              else
                shift
              fi
            done
            if [ -n "$out" ]; then
              printf '@HD\\tVN:1.6\\tSO:unknown\\n' > "$out"
            fi
            if [ \(minimap2ExitCode) -ne 0 ]; then
              printf 'minimap2 failed\\n' >&2
              exit \(minimap2ExitCode)
            fi
            printf 'minimap2 completed\\n' >&2
            exit 0
          fi
        fi

        exit 0
        """
    }

    private static func samtoolsScript(flagstatExitCode: Int32) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "samtools 1.21"
          exit 0
        fi

        subcommand="$1"
        shift
        case "$subcommand" in
          sort)
            out=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then
                out="$2"
                shift 2
              else
                shift
              fi
            done
            if [ -n "$out" ]; then
              printf 'bam\\n' > "$out"
            fi
            ;;
          index)
            bam="$1"
            printf 'bai\\n' > "${bam}.bai"
            ;;
          flagstat)
            if [ \(flagstatExitCode) -ne 0 ]; then
              printf 'flagstat failed\\n' >&2
              exit \(flagstatExitCode)
            fi
            printf '%s\\n' '10 + 0 in total (QC-passed reads + QC-failed reads)'
            printf '%s\\n' '8 + 0 mapped (80.00% : N/A)'
            ;;
        esac

        exit 0
        """
    }
}
