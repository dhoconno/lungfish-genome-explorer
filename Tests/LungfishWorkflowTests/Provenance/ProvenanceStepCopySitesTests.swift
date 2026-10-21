// ProvenanceStepCopySitesTests.swift - What the Workflow step copies keep of a recorded step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane S4b, scope rows B6 and B8. Each test sends `StepCopyFacts.fullStep` through one site and
// states what the copy did to each fact. A fact missing from the expected changes is kept as it was. The
// App sites are in `ProvenanceStepCopySitesAppTests` and the markdup site is in `MarkdupEnvelopeCopyTests`.

import XCTest
@testable import LungfishCore
@testable import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ProvenanceStepCopySitesTests: XCTestCase {
    typealias Facts = StepCopyFacts

    // MARK: ReferenceBundleAnnotationImportService.replacingOutputDescriptor

    func testAnnotationImportDescriptorReplacementStepCopy() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let output = try ProvenanceCompatScenarios.write(
            "features\n", to: project.root.appendingPathComponent("Analysis/features.db")
        )
        let descriptor = try ProvenanceFileDescriptor.file(url: output, format: .unknown, role: .output)
        let step = Facts.fullStep(input: output, outputs: [descriptor])
        let envelope = ProvenanceEnvelope(
            workflowName: "annotation record", toolName: "lungfish-cli", outputs: [descriptor], steps: [step]
        )
        let replacement = try ProvenanceFileDescriptor.file(url: output, format: .sqlite, role: .output)

        let copy = try XCTUnwrap(envelope.replacingOutputDescriptor(replacement, matchingPath: output.path).steps.first)

        XCTAssertEqual(Facts.changes(from: step, in: copy), [:], "the copy keeps every fact of the step")
        XCTAssertEqual(copy.outputs, [replacement])
    }

    // MARK: PrimitiveProvenanceEnvelopeAdapter.stepsWithFallbackIO

    func testPrimitiveAdapterFallbackStepCopy() throws {
        let input = URL(fileURLWithPath: "/data/reads.fastq")
        let step = Facts.fullStep(input: input)
        let fallbackInput = ProvenanceFileDescriptor(path: input.path, role: .input)
        let fallbackOutput = ProvenanceFileDescriptor(path: "/data/reads.bam", role: .output)

        let copy = try XCTUnwrap(
            PrimitiveProvenanceEnvelopeAdapter.stepsWithFallbackIO(
                [step], inputs: [fallbackInput], outputs: [fallbackOutput]
            ).first
        )

        XCTAssertEqual(Facts.changes(from: step, in: copy), [:], "the fallback keeps every fact of the step")
        XCTAssertEqual(copy.inputs, [fallbackInput])
        XCTAssertEqual(copy.outputs, [fallbackOutput])
    }

    // MARK: PrimerAnalysisSelectionExportService.relocatedNativeStep

    func testPrimerExportNativeStepCopy() {
        let step = Facts.fullStep(input: URL(fileURLWithPath: "/staging/built/genome.fa"))
        let replay = ["samtools", "faidx", "/final/genome.fa"]

        let copy = PrimerAnalysisSelectionExportService.relocatedNativeStep(
            step, replay: replay, runtime: ProvenanceRuntimeIdentity(), inputs: [], outputs: []
        )

        XCTAssertEqual(Facts.changes(from: step, in: copy), ["durableReplayArgv": .changed])
        XCTAssertEqual(copy.durableReplayArgv, replay)
    }

    // MARK: ONTImportWorkflow.remapOptimizationStep

    func testONTOptimizationStepCopy() {
        let staged = URL(fileURLWithPath: "/project/.staging/run.lungfishfastq", isDirectory: true)
        let final = URL(fileURLWithPath: "/project/Imports/run.lungfishfastq", isDirectory: true)
        let step = Facts.fullStep(input: staged.appendingPathComponent("reads.fastq.gz"))

        let copy = ONTImportWorkflow().remapOptimizationStep(step, from: staged, to: final)

        XCTAssertEqual(Facts.changes(from: step, in: copy), ["durableReplayArgv": .changed, "resolvedOptions": .changed])
        XCTAssertEqual(copy.durableReplayArgv?.last, final.appendingPathComponent("reads.fastq.gz").path)
        XCTAssertEqual(Facts.filePath(of: "input", in: copy), final.appendingPathComponent("reads.fastq.gz").path)
        XCTAssertEqual(copy.resolvedOptions["threads"], .integer(4))
    }

    // MARK: FASTQBundleCopyImportWorkflow.rewriteStep, after ProvenanceRehydrator

    func testFASTQBundleCopyImportStepCopy() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let sourceBundle = try project.folder("Imports/source.lungfishfastq")
        let reads = try ProvenanceCompatScenarios.write(
            "@r1\nACGT\n+\n!!!!\n", to: sourceBundle.appendingPathComponent("reads.fastq")
        )
        let descriptor = try ProvenanceFileDescriptor.file(url: reads, format: .fastq, role: .output)
        let step = Facts.fullStep(input: reads, outputs: [descriptor])
        let record = ProvenanceEnvelope(
            workflowName: "source fastq import", toolName: "lungfish-cli", argv: ["lungfish-cli", "import", "fastq"],
            output: descriptor, outputs: [descriptor], steps: [step], exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(record, to: sourceBundle)
        let destination = project.root.appendingPathComponent("Imports/copied.lungfishfastq", isDirectory: true)

        _ = try FASTQBundleCopyImportWorkflow().importBundle(
            sourceBundleURL: sourceBundle,
            outputURL: destination,
            context: FASTQBundleCopyImportWorkflow.CommandContext(
                workflowName: "test fastq bundle import",
                toolName: "lungfish-cli",
                argv: ["lungfish", "fastq", "import-bundle", sourceBundle.path]
            )
        )

        let written = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: destination.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        )
        let copy = try XCTUnwrap(written.steps.first)
        XCTAssertEqual(Facts.changes(from: step, in: copy), ["durableReplayArgv": .changed, "resolvedOptions": .changed])
        XCTAssertEqual(copy.durableReplayArgv?.last, destination.appendingPathComponent("reads.fastq").path)
        XCTAssertEqual(Facts.filePath(of: "input", in: copy), destination.appendingPathComponent("reads.fastq").path)
    }

    // MARK: GUIImportedProvenanceRehydrator.rewriteOutputDescriptors, the in-place ingestion path

    /// The in-place ingestion replaces the FASTQ a record names, so the record goes through this rewrite.
    func testGUIImportInPlaceRewriteCopy() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let bundle = try project.folder("Imports/Sample.lungfishfastq")
        let imported = try ProvenanceCompatScenarios.write("@r\nACGT\n+\n!!!!\n", to: bundle.appendingPathComponent("Sample.fastq"))
        let final = try ProvenanceCompatScenarios.write("gz", to: bundle.appendingPathComponent("Sample.fastq.gz"))
        let source = try Self.preTwoFourRecord(output: imported)

        let copy = try GUIImportedProvenanceRehydrator.rewriteOutputDescriptors(
            in: source, pathMap: [imported.path: final.path]
        )

        let copiedStep = try XCTUnwrap(copy.steps.first)
        XCTAssertEqual(Facts.changes(from: source.steps[0], in: copiedStep), [
            "durableReplayArgv": .changed, "resolvedOptions": .changed,
        ])
        XCTAssertEqual(copiedStep.durableReplayArgv?.last, final.path)
        XCTAssertEqual(Facts.filePath(of: "input", in: copiedStep), final.path, "the option follows the replay command")
        Self.assertKeepsTheRecord(copy, of: source, nestedFileNow: final)
    }

    // MARK: GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar (selected outputs, then arguments)

    func testGUIImportFileSidecarCopy() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let result = try ProvenanceCompatScenarios.write("result\n", to: project.root.appendingPathComponent("Source/result.txt"))
        let sourceBytes = try Self.preTwoFourRecordBytes(output: result)
        try sourceBytes.write(to: ProvenanceRecorder.fileSidecarURL(for: result))
        let source = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: sourceBytes)
        let destination = project.root.appendingPathComponent("Imports/result.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: result, to: destination)

        try GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar(from: result, to: destination)

        let copy = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: destination)))
        let copiedStep = try XCTUnwrap(copy.steps.first)
        XCTAssertEqual(Facts.changes(from: source.steps[0], in: copiedStep), [
            "durableReplayArgv": .changed, "resolvedOptions": .changed,
        ])
        XCTAssertEqual(copiedStep.durableReplayArgv?.last, destination.path)
        XCTAssertEqual(Facts.filePath(of: "input", in: copiedStep), destination.path, "the option follows the replay command")
        XCTAssertEqual(copy.steps.last?.toolName, LungfishAppIdentity.recordedToolName, "the import step follows")
        Self.assertKeepsTheRecord(copy, of: source, nestedFileNow: destination)
    }

    // MARK: ProvenanceRehydrator.rehydrate

    func testGenericRehydratorCopy() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let sourceFolder = try project.folder("Staging/run")
        let output = try ProvenanceCompatScenarios.write("out\n", to: sourceFolder.appendingPathComponent("out.txt"))
        let finalFolder = try project.folder("Analyses/run")
        let finalOutput = finalFolder.appendingPathComponent("out.txt")
        try FileManager.default.copyItem(at: output, to: finalOutput)
        let sourceBytes = try Self.preTwoFourRecordBytes(output: output)
        try sourceBytes.write(to: sourceFolder.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        let source = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: sourceBytes)

        let copy = try ProvenanceRehydrator.rehydrate(
            sourceDirectory: sourceFolder, finalDirectory: finalFolder, pathMap: [output.path: finalOutput.path]
        )

        let copiedStep = try XCTUnwrap(copy.steps.first)
        XCTAssertEqual(Facts.changes(from: source.steps[0], in: copiedStep), [
            "durableReplayArgv": .changed, "resolvedOptions": .changed,
        ])
        XCTAssertEqual(Facts.filePath(of: "input", in: copiedStep), finalOutput.path, "the step's options follow its replay command")
        Self.assertKeepsTheRecord(copy, of: source, nestedFileNow: finalOutput)
    }

    // MARK: MetagenomicsImportService, the NVD auxiliary and NAO-MGS materialization steps

    func testNVDAuxiliaryStepConversion() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let staging = try project.folder("Imports/.lungfish-nvd-import-pin")
        let published = project.root.appendingPathComponent("Imports/run", isDirectory: true)
        let bam = try ProvenanceCompatScenarios.write("bam\n", to: staging.appendingPathComponent("bams/S1.bam"))
        let source = NvdAuxiliaryStep(
            toolName: "samtools", toolVersion: "1.22",
            argv: ["samtools", "view", "-c", bam.path], reproducibleCommand: "samtools view -c \(bam.path)",
            inputURLs: [bam], outputURLs: [], exitStatus: 0, wallTimeSeconds: 1, stderr: nil,
            startedAt: nil, completedAt: nil
        )
        func convert() throws -> ProvenanceStep {
            try XCTUnwrap(nvdAuxiliaryProvenanceSteps(from: [source], stagingRoot: staging, publishedRoot: published).first)
        }

        let first = try convert()
        let second = try convert()

        XCTAssertEqual(first.id, source.id, "the step keeps the id it got when samtools ran")
        XCTAssertEqual(second.id, source.id, "a second conversion names the same step")
        XCTAssertEqual(first.inputs.map(\.path), [published.appendingPathComponent("bams/S1.bam").path])
        XCTAssertEqual(first.durableReplayArgv?.last, published.appendingPathComponent("bams/S1.bam").path)
    }

    func testNAOMGSMaterializationStepConversion() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let result = try project.folder("Imports/naomgs")
        let database = try ProvenanceCompatScenarios.write("db\n", to: result.appendingPathComponent("hits.sqlite"))
        let bam = try ProvenanceCompatScenarios.write("bam\n", to: result.appendingPathComponent("bams/S1.bam"))
        let source = NaoMgsBamMaterializationStep(
            sample: "S1", toolName: "samtools", toolVersion: "1.22", argv: ["samtools", "index", bam.path],
            inputURLs: [bam], outputURLs: [bam], exitStatus: 0, wallTimeSeconds: 1
        )
        func convert() throws -> ProvenanceStep {
            try XCTUnwrap(
                naoMgsMaterializationProvenanceSteps(
                    from: [source], sourceURLs: [database], relocatedArtifacts: [:],
                    materializationReplayArgv: ["lungfish-cli", "import", "nao-mgs"]
                ).first
            )
        }

        let first = try convert()
        let second = try convert()

        XCTAssertEqual(first.id, source.id, "the step keeps the id it got when samtools ran")
        XCTAssertEqual(second.id, source.id, "a second conversion names the same step")
        XCTAssertEqual(first.inputs.map(\.path), [bam.path])
        XCTAssertEqual(first.durableReplayArgv, ["samtools", "index", bam.path])
    }

    // MARK: Helpers

    /// The copy keeps the record's release version, and the nested run's plan and file value reach the
    /// resolved defaults, the file value under the copy's path map.
    static func assertKeepsTheRecord(
        _ copy: ProvenanceEnvelope, of source: ProvenanceEnvelope, nestedFileNow expected: URL,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(copy.githubReleaseVersion, source.githubReleaseVersion, file: file, line: line)
        XCTAssertEqual(
            copy.options.resolvedDefaults["readSetPlan"], EnvelopeCopySources.readSetPlan,
            "the nested run's plan survives", file: file, line: line
        )
        XCTAssertEqual(
            copy.options.resolvedDefaults["copyPinNestedFile"]?.fileValue?.path, expected.path,
            "a nested file value takes the copy's path map", file: file, line: line
        )
        XCTAssertNil(copy.legacyRun, file: file, line: line)
    }

    /// A completed CLI record of one full step that read and wrote `output`, as a pre-2.4 build wrote it,
    /// with its plan, another parameter and a file value naming `output` only in the nested run.
    static func preTwoFourRecord(output: URL) throws -> ProvenanceEnvelope {
        try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: preTwoFourRecordBytes(output: output))
    }

    /// The bytes of `preTwoFourRecord(output:)`.
    static func preTwoFourRecordBytes(output: URL) throws -> Data {
        let descriptor = try ProvenanceFileDescriptor.file(url: output, format: .unknown, role: .output)
        let base = ProvenanceEnvelope(
            workflowName: "lungfish-cli convert",
            toolName: "lungfish-cli",
            toolVersion: "2026.10.14",
            githubReleaseVersion: "v2026.10.14",
            argv: ["lungfish-cli", "convert", output.path],
            durableReplayArgv: ["lungfish-cli", "convert", output.path],
            output: descriptor,
            outputs: [descriptor],
            steps: [StepCopyFacts.fullStep(input: output, outputs: [descriptor])],
            exitStatus: 0
        )
        return try EnvelopeCopySources.recordBytes(
            .preTwoFourNestedPlan,
            from: ProvenanceJSON.encoder.encode(base),
            extraNestedParameters: ["copyPinNestedFile": .file(output)]
        )
    }
}
