// VariantsCallGATKTests.swift - `variants call --caller gatk` runs the dialog's GATK call from the command line
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A50 M2 (BIO objections 2 and 3, ARCH objection 5 of Phase 2.10). The leaf runs
// `GATKPipelineExecutor` and `GATKBundleVariantAttachmentService` into `variants/gatk/`, as the Inspector's GATK
// row does. A run with no GATK flag is the dialog's run, every GATK option is a flag of its own, no GATK option rides
// in `--extra-args`, and the records name the `lungfish-cli` command and every GATK command. A stand-in
// `GATKCommandRunning` answers, so no GATK is needed. `GATKVariantCallPinConformanceTests` runs the pair on real GATK.

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class VariantsCallGATKTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "variants-call-gatk")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func makeBundle() throws -> URL {
        let bundle = root.appendingPathComponent("Sample.lungfishref", isDirectory: true)
        for folder in ["genome", "alignments"] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data(">chr1\nACGTACGTACGT\n".utf8).write(to: bundle.appendingPathComponent("genome/reference.fa"))
        try Data("chr1\t12\t6\t12\t13\n".utf8).write(to: bundle.appendingPathComponent("genome/reference.fa.fai"))
        try Data("bam-bytes".utf8).write(to: bundle.appendingPathComponent("alignments/sample.bam"))
        try Data("bai-bytes".utf8).write(to: bundle.appendingPathComponent("alignments/sample.bam.bai"))
        try BundleManifest(
            name: "Sample",
            identifier: "sample-bundle",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/reference.fa",
                indexPath: "genome/reference.fa.fai",
                totalLength: 12,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 12, offset: 6, lineBases: 12, lineWidth: 13)]
            ),
            alignments: [
                AlignmentTrackInfo(id: "aln-1", name: "Sample BAM", sourcePath: "alignments/sample.bam", indexPath: "alignments/sample.bam.bai"),
            ]
        ).save(to: bundle)
        return bundle
    }

    /// Runs the GATK path of `arguments` (the words after `variants call`) on a stand-in runner. Returns the
    /// GATK commands that ran, the events, the attachment and the argv the records were told to name.
    private func runGATK(
        _ arguments: [String], bundle: URL
    ) async throws -> (commands: [GATKCommand], events: [VariantsCommand.VariantCallingEvent], attachment: GATKBundleVariantAttachmentResult, argv: [String]) {
        let command = try VariantsCommand.CallSubcommand.parse(["--bundle", bundle.path, "--alignment-track", "aln-1", "--caller", "gatk"] + arguments)
        let runner = StandInGATKRunner()
        let sink = EventSink()
        let argv = command.recordedCommandLine(arguments: [])
        let attachment = try await command.executeGATK(
            runner: runner,
            toolVersion: "4.6.1.0",
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: "/opt/lungfish/envs/gatk-core"),
            recordedArguments: argv,
            outputExtension: "vcf",
            emitEvent: { sink.append($0) }
        )
        return (await runner.commands, sink.events, attachment, argv)
    }

    /// What the Call Variants dialog builds for the same bundle: reference confidence NONE and the configuration's
    /// defaults. Only the output path is the run's own.
    private func dialogArguments(bundle: URL, output: String, extra: [String] = []) -> [String] {
        GATKCommandBuilder.haplotypeCallerCommand(
            GATKHaplotypeCallerConfiguration(
                referenceFASTAURL: bundle.appendingPathComponent("genome/reference.fa"),
                inputBAMURL: bundle.appendingPathComponent("alignments/sample.bam"),
                outputVCFURL: URL(fileURLWithPath: output),
                emitReferenceConfidence: .none,
                extraArguments: extra
            )
        ).arguments
    }

    func testARunWithNoGATKFlagsIsTheDialogsRunAndTheRecordsNameEveryCommand() async throws {
        let bundle = try makeBundle()
        let ran = try await runGATK(["--name", "Sample GATK"], bundle: bundle)

        let command = try XCTUnwrap(ran.commands.first)
        XCTAssertEqual(ran.commands.count, 1)
        let output = try XCTUnwrap(command.arguments.firstIndex(of: "-O").map { command.arguments[$0 + 1] })
        XCTAssertTrue(output.contains("/variants/gatk/vc-") && output.hasSuffix(".vcf"), "the VCF goes where older bundles hold theirs: \(output)")
        XCTAssertEqual(command.arguments, dialogArguments(bundle: bundle, output: output), "no flags is the dialog's call")

        XCTAssertEqual(ran.events.map(\.event), ["runStart", "stageProgress", "stageProgress", "runComplete"])
        XCTAssertEqual(ran.events.map(\.progress), [0.0, 0.75, 0.97, 1.0], "the attach steps move the bar")
        let complete = try XCTUnwrap(ran.events.last)
        XCTAssertEqual(complete.variantTrackName, "Sample GATK")
        XCTAssertEqual(complete.variantTrackID, ran.attachment.trackInfo.id)
        XCTAssertEqual(complete.databasePath, ran.attachment.databaseURL.path)
        XCTAssertEqual(complete.tbiPath, ran.attachment.indexURL.path)
        XCTAssertEqual(complete.provenancePath, ran.attachment.provenanceURL.path)
        XCTAssertEqual(ran.attachment.trackInfo.databasePath?.hasPrefix("variants/gatk/vc-"), true)

        // The execution record names the lungfish-cli command and the GATK command of its step.
        let executionURL = GATKPipelineExecutionRequest.bundleRunRecordURL(forTrackID: ran.attachment.trackInfo.id, inBundle: bundle)
        let envelope = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: executionURL))
        XCTAssertEqual(envelope.argv, ran.argv)
        let execution = try envelope.legacyWorkflowRun()
        XCTAssertEqual(execution.steps.map(\.command), [["gatk"] + command.arguments])
        XCTAssertEqual(execution.parameters["shellCommands"].map { "\($0)" }?.contains("HaplotypeCaller"), true)
        XCTAssertEqual(execution.parameters["option.emitReferenceConfidence"]?.stringValue, "NONE")
        let attach = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: ran.attachment.provenanceURL)).legacyWorkflowRun()
        XCTAssertEqual(try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: ran.attachment.provenanceURL)).argv, ran.argv, "the record the completion event names is the leaf's own command")
        XCTAssertEqual(attach.parameters["shellCommand"]?.stringValue, command.shellCommand)
    }

    func testEveryGATKOptionIsAFlagOfItsOwnAndOnlyTheFreeTextRidesInExtraArgs() async throws {
        let bundle = try makeBundle()
        let ran = try await runGATK(
            ["--ploidy", "1", "--intervals", "regions.bed", "--pcr-indel-model", "AGGRESSIVE", "--stand-call-conf", "20",
             "--max-alternate-alleles", "3", "--pair-hmm-threads", "2", "--emit-ref-confidence", "NONE",
             "--extra-args", "--min-base-quality-score 20"],
            bundle: bundle
        )

        let arguments = try XCTUnwrap(ran.commands.first).arguments
        func value(after flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
        XCTAssertEqual(value(after: "--sample-ploidy"), "1")
        XCTAssertEqual(value(after: "-L"), URL(fileURLWithPath: "regions.bed").path)
        XCTAssertEqual(value(after: "--pcr-indel-model"), "AGGRESSIVE")
        XCTAssertEqual(value(after: "--standard-min-confidence-threshold-for-calling"), "20.0")
        XCTAssertEqual(value(after: "--max-alternate-alleles"), "3")
        XCTAssertEqual(value(after: "--native-pair-hmm-threads"), "2")
        XCTAssertEqual(Array(arguments.suffix(2)), ["--min-base-quality-score", "20"], "the free text is the only thing after the options")

        let executionURL = GATKPipelineExecutionRequest.bundleRunRecordURL(forTrackID: ran.attachment.trackInfo.id, inBundle: bundle)
        let execution = try ProvenanceEnvelopeReader.decodeCanonical(try Data(contentsOf: executionURL)).legacyWorkflowRun()
        XCTAssertEqual(execution.parameters["option.extraArguments"]?.stringValue, #"["--min-base-quality-score","20"]"#)
        XCTAssertEqual(execution.parameters["option.ploidy"]?.stringValue, "1")
    }

    func testGATKRefusesTheOptionsItHasNoUseFor() async throws {
        let bundle = try makeBundle()
        for flag in [["--min-af", "0.1"], ["--min-depth", "5"], ["--platform", "ont"], ["--medaka-model", "m"], ["--ivar-primer-trimmed"]] {
            do {
                _ = try await runGATK(flag, bundle: bundle)
                XCTFail("\(flag) must be refused for --caller gatk")
            } catch let error as ValidationError {
                XCTAssertTrue(error.message.contains(flag[0]), error.message)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("variants").path), "a refusal writes nothing")
    }

    /// Review A50 F5 (CLI-EQUIVALENCE). The record names the command as it was typed, and that command parses
    /// back and records itself again.
    func testTheRecordedCommandIsTheCommandAsTypedAndItParsesBack() throws {
        let bundle = try makeBundle()
        let typed = ["/opt/lungfish/lungfish-cli", "variants", "call", "--bundle", bundle.path, "--alignment-track", "aln-1",
                     "--caller", "gatk", "--name", "Sample GATK", "--ploidy", "1", "--format", "json", "--no-progress"]
        let command = try VariantsCommand.CallSubcommand.parse(Array(typed.dropFirst(3)))
        let recorded = command.recordedCommandLine(arguments: typed)
        XCTAssertEqual(recorded, [CLICommandIdentity.executableName] + Array(typed.dropFirst()), "the record names the command as it was typed")
        let replayed = try VariantsCommand.CallSubcommand.parse(Array(recorded.dropFirst(3)))
        XCTAssertEqual(replayed.recordedCommandLine(arguments: recorded), recorded, "the recorded command parses and records itself again")
    }
}

private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [VariantsCommand.VariantCallingEvent] = []

    func append(_ event: VariantsCommand.VariantCallingEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var events: [VariantsCommand.VariantCallingEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Answers a GATK command as GATK does for a tiny run: it writes the VCF named by `-O` and its index.
private actor StandInGATKRunner: GATKCommandRunning {
    private(set) var commands: [GATKCommand] = []

    func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        commands.append(command)
        guard let flag = command.arguments.firstIndex(of: "-O") else { throw NSError(domain: "StandInGATKRunner", code: 1) }
        let output = URL(fileURLWithPath: command.arguments[flag + 1])
        let vcf = "##fileformat=VCFv4.2\n##contig=<ID=chr1,length=12>\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n"
            + "chr1\t4\t.\tT\tG\t60\tPASS\tDP=18\n"
        try Data(vcf.utf8).write(to: output)
        try Data().write(to: output.appendingPathExtension("idx"))
        return GATKCommandExecutionResult(exitCode: 0, stdout: "", stderr: "", wallTime: 0.5)
    }
}
