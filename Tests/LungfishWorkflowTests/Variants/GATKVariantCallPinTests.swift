// GATKVariantCallPinTests.swift - Pins what the GATK call leaves in a bundle at the base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A50 M1. The Inspector's GATK row runs `GATKPipelineExecutor` and
// `GATKBundleVariantAttachmentService` in the app process. M2 adds `variants call --caller gatk`, which
// runs the same two types, so these tests pin the command, the VCF, the execution record, the attach
// record and the track that the pair leaves in a bundle before any Sources edit. A stand-in
// `GATKCommandRunning` answers here. `GATKVariantCallPinConformanceTests` runs the same steps on the
// managed gatk-core environment. Only what a run cannot repeat is masked, which is the bundle's path.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

/// A tiny reference bundle with one alignment track, the shape the dialog's GATK row starts from.
struct GATKPinBundle {
    static let trackID = "vc-pin-track"
    static let snpPosition = 150

    /// 300 bases from a fixed generator, so no two runs differ.
    static let referenceSequence: String = {
        var state: UInt32 = 12345
        let bases = Array("ACGT")
        return String((0..<300).map { _ -> Character in
            state = state &* 1_664_525 &+ 1_013_904_223
            return bases[Int((state >> 24) & 3)]
        })
    }()

    let bundleURL: URL
    let referenceURL: URL
    let bamURL: URL
    let outputVCFURL: URL

    static func make(in root: URL, outputName: String) throws -> GATKPinBundle {
        let bundleURL = root.appendingPathComponent("sample.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let alignmentsDir = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        let variantsDir = bundleURL.appendingPathComponent("variants/gatk", isDirectory: true)
        for directory in [genomeDir, alignmentsDir, variantsDir] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let referenceURL = genomeDir.appendingPathComponent("reference.fa")
        try Data(">chr1\n\(referenceSequence)\n".utf8).write(to: referenceURL)
        try Data("chr1\t300\t6\t300\t301\n".utf8).write(to: genomeDir.appendingPathComponent("reference.fa.fai"))
        let bamURL = alignmentsDir.appendingPathComponent("sample.bam")
        try Data("bam-bytes".utf8).write(to: bamURL)
        try Data("bai-bytes".utf8).write(to: alignmentsDir.appendingPathComponent("sample.bam.bai"))
        let manifest = BundleManifest(
            name: "Sample",
            identifier: "sample-bundle",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/reference.fa",
                indexPath: "genome/reference.fa.fai",
                totalLength: 300,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 300, offset: 6, lineBases: 300, lineWidth: 301)]
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Sample BAM",
                    sourcePath: "alignments/sample.bam",
                    indexPath: "alignments/sample.bam.bai"
                ),
            ]
        )
        try manifest.save(to: bundleURL)
        return GATKPinBundle(
            bundleURL: bundleURL,
            referenceURL: referenceURL,
            bamURL: bamURL,
            outputVCFURL: variantsDir.appendingPathComponent(outputName)
        )
    }

    /// The base at the SNP position and a different one.
    static var snpBases: (reference: String, alternate: String) {
        let reference = String(referenceSequence[referenceSequence.index(referenceSequence.startIndex, offsetBy: snpPosition - 1)])
        return (reference, reference == "A" ? "C" : "A")
    }
}

/// What the pair leaves in a bundle, one `key = value` line per fact, the bundle's path masked.
enum GATKPinFacts {
    static func collect(
        fixture: GATKPinBundle,
        request: GATKPipelineExecutionRequest,
        result: GATKPipelineExecutionResult,
        attachment: GATKBundleVariantAttachmentResult
    ) throws -> [String] {
        func mask(_ text: String) -> String {
            var masked = text
            let paths = [fixture.bundleURL.resolvingSymlinksInPath().path, fixture.bundleURL.standardizedFileURL.path, fixture.bundleURL.path]
            for path in paths { masked = masked.replacingOccurrences(of: path, with: "<bundle>") }
            return masked
        }
        func render(_ value: ParameterValue) -> String {
            if let text = value.stringValue { return text }
            switch value {
            case .array(let items): return "[" + items.map(render).joined(separator: ", ") + "]"
            case .integer(let number): return String(number)
            default: return String(describing: value)
            }
        }
        var facts: [String] = []

        facts.append("gatk.commands = \(request.commands.map { mask($0.shellCommand) })")
        facts.append("gatk.cliCommandLine = \(String(describing: request.cliCommandLine))")

        let executionData = try Data(contentsOf: result.provenanceURL)
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(executionData)
        let execution = try envelope.legacyWorkflowRun()
        facts.append("exec.file = \(mask(result.provenanceURL.path))")
        facts.append("exec.envelope.status = \(envelope.status.rawValue)")
        facts.append("exec.envelope.argv = \(envelope.argv.map(mask))")
        facts.append("exec.envelope.reproducibleCommand = \(mask(envelope.reproducibleCommand))")
        facts.append("exec.name = \(execution.name)")
        facts.append("exec.stepCount = \(execution.steps.count)")
        for (index, step) in execution.steps.enumerated() {
            facts.append("exec.step\(index).tool = \(step.toolName) \(step.toolVersion ?? "nil")")
            facts.append("exec.step\(index).command = \(step.command.map(mask))")
            facts.append("exec.step\(index).exitCode = \(step.exitCode.map(String.init) ?? "nil")")
            facts.append("exec.step\(index).inputs = \(step.inputs.map { mask($0.path) })")
            facts.append("exec.step\(index).outputs = \(step.outputs.map { mask($0.path) })")
        }
        for key in execution.parameters.keys.sorted() {
            facts.append("exec.parameter.\(key) = \(mask(render(execution.parameters[key]!)))")
        }

        let attachData = try Data(contentsOf: attachment.provenanceURL)
        let attachEnvelope = try ProvenanceEnvelopeReader.decodeCanonical(attachData)
        let attach = try attachEnvelope.legacyWorkflowRun()
        facts.append("attach.file = \(mask(attachment.provenanceURL.path))")
        facts.append("attach.envelope.status = \(attachEnvelope.status.rawValue)")
        facts.append("attach.envelope.argv = \(attachEnvelope.argv.map(mask))")
        facts.append("attach.name = \(attach.name)")
        facts.append("attach.stepCount = \(attach.steps.count)")
        for (index, step) in attach.steps.enumerated() {
            facts.append("attach.step\(index).tool = \(step.toolName)")
            facts.append("attach.step\(index).command = \(step.command.map(mask))")
            facts.append("attach.step\(index).inputs = \(step.inputs.map { mask($0.path) })")
            facts.append("attach.step\(index).outputs = \(step.outputs.map { mask($0.path) })")
        }
        for key in attach.parameters.keys.sorted() {
            facts.append("attach.parameter.\(key) = \(mask(render(attach.parameters[key]!)))")
        }

        let track = attachment.trackInfo
        facts.append("track = id:\(track.id) name:\(track.name) description:\(track.description ?? "nil")")
        facts.append("track.paths = \(track.path ?? "nil") | \(track.indexPath ?? "nil") | \(track.databasePath ?? "nil")")
        facts.append("track.kind = \(track.variantType) count:\(track.variantCount.map(String.init) ?? "nil") source:\(track.source ?? "nil") version:\(track.version ?? "nil")")
        for key in ["variant_caller", "variant_caller_version", "variant_caller_command_line", "source_alignment_track_id",
                    "source_alignment_track_name", "source_alignment_relative_path", "artifact_vcf_path", "artifact_index_path",
                    "artifact_database_path", "workflow_provenance_path", "call_semantics", "source_execution_provenance"] {
            let value = VariantDatabase.metadataValue(at: attachment.databaseURL, key: key)
            facts.append("db.\(key) = \(mask(value ?? "nil"))")
        }

        let manifest = try BundleManifest.load(from: fixture.bundleURL)
        facts.append("manifest.variants = \(manifest.variants.map(\.id))")
        let gatkFolder = fixture.bundleURL.appendingPathComponent("variants/gatk", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: gatkFolder.path).sorted()
        facts.append("folder.variants/gatk = \(names)")
        return facts
    }
}

final class GATKVariantCallPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "gatk-variant-call-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private var vcfText: String {
        let bases = GATKPinBundle.snpBases
        return """
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=300>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tsample
        chr1\t\(GATKPinBundle.snpPosition)\t.\t\(bases.reference)\t\(bases.alternate)\t60\tPASS\tDP=18\tGT:DP\t0/1:18

        """
    }

    /// The pair runs as the dialog's GATK row runs it. The request is the dialog's, so its values are
    /// `emitReferenceConfidence` NONE and the configuration's defaults, and the free-text extra arguments.
    func testTodaysGATKCallLeavesThisCommandVCFRecordsAndTrack() async throws {
        let fixture = try GATKPinBundle.make(in: root, outputName: "\(GATKPinBundle.trackID).vcf")
        let configuration = GATKHaplotypeCallerConfiguration(
            referenceFASTAURL: fixture.referenceURL,
            inputBAMURL: fixture.bamURL,
            outputVCFURL: fixture.outputVCFURL,
            emitReferenceConfidence: .none,
            extraArguments: ["--min-base-quality-score", "20"]
        )
        let request = GATKPipelineExecutionRequest.haplotypeCaller(
            configuration: configuration,
            toolVersion: "4.6.1.0",
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: "/opt/lungfish/envs/gatk-core")
        )
        let runner = PinGATKRunner(vcfText: vcfText)

        let result = try await GATKPipelineExecutor(runner: runner).run(request)
        let attachment = try await GATKBundleVariantAttachmentService().attach(
            request: GATKBundleVariantAttachmentRequest(
                bundleURL: fixture.bundleURL,
                alignmentTrackID: "aln-1",
                outputTrackID: GATKPinBundle.trackID,
                outputTrackName: "Sample BAM \u{2022} GATK HaplotypeCaller",
                outputVCFURL: fixture.outputVCFURL,
                executionProvenanceURL: result.provenanceURL,
                executionRequest: request
            )
        )

        let ran = await runner.recordedCommands()
        XCTAssertEqual(ran.count, 1, "the executor runs the one HaplotypeCaller command")
        XCTAssertEqual(try String(contentsOf: fixture.outputVCFURL, encoding: .utf8), vcfText, "the kept VCF is what GATK wrote")
        XCTAssertEqual(attachment.variantCount, 1)

        let facts = try GATKPinFacts.collect(fixture: fixture, request: request, result: result, attachment: attachment)
        if let directory = ProcessInfo.processInfo.environment["LUNGFISH_RECORD_PINS_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try facts.joined(separator: "\n").write(
                toFile: directory + "/gatk-variant-call-pin.txt", atomically: true, encoding: .utf8
            )
        }
        XCTAssertEqual(facts.joined(separator: "\n"), Self.expectedFacts)
    }
}

/// Answers a GATK command the way GATK does for a tiny run: it writes the VCF named by `-O` and its index.
private actor PinGATKRunner: GATKCommandRunning {
    private let vcfText: String
    private var commands: [GATKCommand] = []

    init(vcfText: String) {
        self.vcfText = vcfText
    }

    func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        commands.append(command)
        guard let flag = command.arguments.firstIndex(of: "-O"), command.arguments.indices.contains(flag + 1) else {
            throw NSError(domain: "GATKVariantCallPinTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "no -O"])
        }
        let output = URL(fileURLWithPath: command.arguments[flag + 1])
        try Data(vcfText.utf8).write(to: output)
        try Data().write(to: output.appendingPathExtension("idx"))
        return GATKCommandExecutionResult(exitCode: 0, stdout: "", stderr: "stand-in GATK summary", wallTime: 1.5)
    }

    func recordedCommands() -> [GATKCommand] {
        commands
    }
}
