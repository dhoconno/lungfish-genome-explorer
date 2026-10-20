// SequenceFASTAExportCLIGUIParityReplayTests.swift - The sequence view's FASTA export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.34 M3, ARCH ruling on the export shape 1.7 and row A12, on lane Q30's harness. Each case runs on
// three sides that start as copies of one root that holds the document the viewer shows. The four cases are a 200 base
// sequence with a description (the 80 column lines the M1 pin held), a sequence of exactly one full line, a short
// sequence with no description, and a name that holds a space.
//
// - Side A is the sequence view's writer (`writeSequenceFASTAExport`, `sequenceFASTAText` and its argv) as
//   `SequenceViewerView+Drawing.swift` held it at bdfb8781c, frozen in this file since the lane deletes it.
// - Side C is `SequenceViewerView.runSequenceFASTAExport`, which stages the sequence beside the output, begins the row
//   and runs the built `lungfish-cli extract sequence ... --line-width 80` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded, with the inputs folder copied to root C'.
//
// A against C compares what 1.7 names, which is the payload byte for byte (the 80 column wrapping the command asks
// for gives the writer's bytes, so no byte differs and no key is needed), the output's digest and size, and the one
// `resolved` key both sides write. The five identity fields, the options that name the inputs, the other `resolved`
// keys and the inputs (side A the viewer's document, side C the staged sequence with its digest) are prediction rows of
// the lane report (BIO 4, 6 and 7), pinned on each side by `assertPredictedRecordChanges`. C against C' compares
// everything under the contract's masks.
//
// The cancel runs through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output, its record nor the staged
// input are left (ARCH ruling 1.6, X14).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
private final class SequenceFASTAExportReports {
    var messages: [String] = []
}

@MainActor
final class SequenceFASTAExportCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case describedSequence
        case fullLine
        case shortSequence
        case spacedName

        func sequence() throws -> LungfishCore.Sequence {
            switch self {
            case .describedSequence:
                return try LungfishCore.Sequence(
                    name: "chr1", description: "visible track", alphabet: .dna, bases: String(repeating: "ACGT", count: 50)
                )
            case .fullLine:
                return try LungfishCore.Sequence(name: "s", alphabet: .dna, bases: String(repeating: "A", count: 80))
            case .shortSequence:
                return try LungfishCore.Sequence(name: "plasmid", alphabet: .dna, bases: "GATTACA")
            case .spacedName:
                return try LungfishCore.Sequence(
                    name: "my seq", description: "circular", alphabet: .dna, bases: String(repeating: "GATTACA", count: 20)
                )
            }
        }

        /// The bytes the sequence view wrote, written out so a fault in the frozen writer shows.
        var expectedText: String {
            let eighty = String(repeating: "ACGT", count: 20)
            switch self {
            case .describedSequence:
                return ">chr1 visible track\n\(eighty)\n\(eighty)\n\(String(repeating: "ACGT", count: 10))\n"
            case .fullLine:
                return ">s\n\(String(repeating: "A", count: 80))\n"
            case .shortSequence:
                return ">plasmid\nGATTACA\n"
            case .spacedName:
                let bases = String(repeating: "GATTACA", count: 20)
                return ">my seq circular\n\(bases.prefix(80))\n\(bases.dropFirst(80))\n"
            }
        }
    }

    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    static let documentName = "document.fa"
    static let outputName = "selected.fasta"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        scratch = try TestTempDirectory.make(prefix: "sequence-fasta-export-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(60))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// 200 bases and a description wrap to 80, 80 and 40, the M1 pin of the writer.
    func testADescribedSequenceWrapsAt80ColumnsAndMatches() async throws {
        let runs = try await assertParity(.describedSequence)
        XCTAssertEqual(try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8), Case.describedSequence.expectedText)
    }

    /// A sequence of exactly 80 bases is one line and ends without a blank line.
    func testAFullLineEndsWithoutABlankLineAndMatches() async throws {
        let runs = try await assertParity(.fullLine)
        XCTAssertEqual(try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8), Case.fullLine.expectedText)
    }

    func testAShortSequenceWithNoDescriptionMatches() async throws {
        let runs = try await assertParity(.shortSequence)
        XCTAssertEqual(try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8), Case.shortSequence.expectedText)
    }

    /// The name holds a space, so the command names the whole header line and the leaf still finds the record.
    func testANameWithASpaceMatches() async throws {
        let runs = try await assertParity(.spacedName)
        XCTAssertEqual(try String(contentsOf: Self.outputURL(in: runs.c.root), encoding: .utf8), Case.spacedName.expectedText)
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no message, the staged input goes, and the row's command, cancelled on the launcher every CLI route uses,
    /// exits 125 inside the grace. Neither leaves the output or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        // The leaf's record looks for a sidecar of each input in the input's folder and the four folders above it, and
        // lists each one (`ProvenanceRecorder.findProvenanceReading`). The staged input sits two folders under this
        // root, so from `scratch/cancel` that walk reached the shared temporary folder (135,212 entries), 13 to 16
        // seconds a run here and 20 to 40 under load, against the 30 second cancel wait. Two more levels keep it
        // inside this case's folders, as in the FASTA records, NAO-MGS and NVD cancel cases.
        let root = scratch.appendingPathComponent("cancel/case/run", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(root)
        let output = Self.outputURL(in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let sequence = try Case.describedSequence.sequence()

        let reports = SequenceFASTAExportReports()
        let begun = try unwrapStarted(await SequenceViewerView.runSequenceFASTAExport(
            name: sequence.name, description: sequence.description, bases: sequence.asString(), outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { reports.messages.append($0) })
        let held = try await FASTARecordsExportCLIGUIParityReplayTests.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(reports.messages, [], "a cancel shows nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
        let staged = root.appendingPathComponent(ViewerExportSelection.inputsFolderName)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: staged.path)) ?? [], [], "a cancel removes the staged input")

        // The cancel removed the input the recorded command names, so restage it where it looks.
        try FileManager.default.removeItem(at: hold)
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item?.cliCommand))
        let stagedURL = URL(fileURLWithPath: arguments[2])
        try FileManager.default.createDirectory(at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(FASTARecordsExport.sequenceText(
            name: sequence.name, description: sequence.description, bases: sequence.asString()
        ).utf8).write(to: stagedURL)
        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(60),
            environment: [Self.holdFileVariable: hold.path],
            cancelWhen: { FileManager.default.fileExists(atPath: hold.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "the run was cancelled through the transport, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(run.stdout.contains("The export was cancelled. No file was written."), run.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
    }

    /// Review 12.34 fix 4. A replace passes `--force` because the panel confirmed it, so a cancel leaves the user's old
    /// file in place. No record names the staged copy of the sequence then, so the copy goes all the same. The folder
    /// stays only when the record beside the output names it.
    func testACancelledReplaceKeepsTheOldFileAndRemovesTheStagedInputs() async throws {
        // Two more levels below the temporary folder, for the reason the cancel case above gives.
        let root = scratch.appendingPathComponent("replace-cancel/case/run", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(root)
        let output = Self.outputURL(in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        let sequence = try Case.describedSequence.sequence()
        let old = Data("old\n".utf8)
        try old.write(to: output)

        let reports = SequenceFASTAExportReports()
        let begun = try unwrapStarted(await SequenceViewerView.runSequenceFASTAExport(
            name: sequence.name, description: sequence.description, bases: sequence.asString(), outputURL: output,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { reports.messages.append($0) })
        let held = try await FASTARecordsExportCLIGUIParityReplayTests.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(reports.messages, [], "a cancel shows nothing")
        XCTAssertEqual(try Data(contentsOf: output), old, "a cancelled replace leaves the old file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
        let staged = root.appendingPathComponent(ViewerExportSelection.inputsFolderName)
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: staged.path)) ?? [], [],
            "a cancel removes the staged input although the old file stays"
        )
    }
}

// MARK: - The sides and the comparison

extension SequenceFASTAExportCLIGUIParityReplayTests {
    static func documentURL(in root: URL) -> URL {
        root.appendingPathComponent(documentName)
    }

    /// The output each side writes, in its root.
    static func outputURL(in root: URL) -> URL {
        root.appendingPathComponent(outputName)
    }

    static func envelope(in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(in: root))))
    }

    /// The root every side starts from, the document the viewer shows. Side A names it, side C never opens it.
    static func makeFixture(_ root: URL) throws {
        try Data(">doc\nACGT\n".utf8).write(to: documentURL(in: root))
    }

    /// Side A. The sequence view's writer before the leaf, frozen below.
    private func sideA(_ root: URL, _ parityCase: Case) throws -> RouteParitySideOutcome {
        do {
            try Self.frozenExport(
                try parityCase.sequence(),
                sourceURLs: [Self.documentURL(in: root).standardizedFileURL], to: Self.outputURL(in: root)
            )
            return RouteParitySideOutcome(end: .completed, detail: "Exported \(Self.outputName).")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// `writeSequenceFASTAExport`, `sequenceFASTAText` and `sequenceFASTAExportArgv` as `SequenceViewerView` held them
    /// at bdfb8781c, with `sequenceFASTAExportSourceURLs(for:)` passed in.
    private static func frozenExport(_ sequence: LungfishCore.Sequence, sourceURLs: [URL], to outputURL: URL) throws {
        let runClock = ProvenanceRunClock()
        let fasta = frozenText(sequence)
        var explicitOptions: [String: ParameterValue] = [
            "sourcePaths": .array(sourceURLs.map { .file($0) }),
            "outputPath": .file(outputURL),
            "sequenceName": .string(sequence.name),
        ]
        if let description = sequence.description {
            explicitOptions["sequenceDescription"] = .string(description)
        }
        var argv = ["Lungfish Genome Explorer", "export-sequence-fasta"]
        for sourceURL in sourceURLs {
            argv.append(contentsOf: ["--source", sourceURL.path])
        }
        argv.append(contentsOf: ["--sequence", sequence.name, "--output", outputURL.path])
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app sequence fasta export",
            toolName: "Lungfish.app",
            toolKind: "gui",
            sourceURLs: sourceURLs,
            outputURL: outputURL,
            outputFormat: .fasta,
            argv: argv,
            explicitOptions: explicitOptions,
            defaults: [
                "lineWidth": .integer(80),
                "outputFormat": .string("fasta"),
            ],
            resolved: [
                "sequenceLength": .integer(sequence.length),
                "outputByteCount": .integer(fasta.utf8.count),
                "sourceCount": .integer(sourceURLs.count),
            ],
            runClock: runClock
        )) { staged in
            try fasta.write(to: staged, atomically: true, encoding: .utf8)
        }
    }

    private static func frozenText(_ sequence: LungfishCore.Sequence) -> String {
        var fasta = ">\(sequence.name)"
        if let desc = sequence.description {
            fasta += " \(desc)"
        }
        fasta += "\n"
        let bases = sequence.asString()
        for i in stride(from: 0, to: bases.count, by: 80) {
            let start = bases.index(bases.startIndex, offsetBy: i)
            let end = bases.index(start, offsetBy: min(80, bases.count - i))
            fasta += String(bases[start..<end]) + "\n"
        }
        return fasta
    }

    /// Side C. The viewer's run, which stages the sequence, begins the row and runs the built CLI behind it on the
    /// shared runner. The inputs folder is then copied to root C', so the rebased command reads it there.
    private func sideC(_ root: URL, _ parityCase: Case) async throws -> RouteParitySideOutcome {
        let reports = SequenceFASTAExportReports()
        let sequence = try parityCase.sequence()
        guard let begun = await SequenceViewerView.runSequenceFASTAExport(
            name: sequence.name, description: sequence.description, bases: sequence.asString(),
            outputURL: Self.outputURL(in: root),
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            onFailure: { reports.messages.append($0) }
        ) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start: \(reports.messages)")
        }
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        switch outcome {
        case .completed:
            XCTAssertEqual(item?.state, .completed)
            XCTAssertEqual(reports.messages, [])
            try RegionExtractionWithoutBundleParityReplayTests.copyStage(
                root.appendingPathComponent(ViewerExportSelection.inputsFolderName, isDirectory: true), from: root
            )
            return RouteParitySideOutcome(end: .completed, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .failed(let failure):
            return RouteParitySideOutcome(end: .failed, detail: failure.message, recordedCommand: item?.cliCommand)
        }
    }

    /// Runs the case on its three sides and checks it as 1.7 reads it. Each side completes with no side naming
    /// another's root, C against C' differs in nothing, A against C is equal on the compared facts, and the
    /// predicted record changes hold.
    @discardableResult
    private func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: Self.makeFixture,
            sideA: { root in try self.sideA(root, parityCase) },
            sideC: { root in try await self.sideC(root, parityCase) }
        )
        if let dump = RouteParityHarness.dumpFolder {
            _ = try harness.evaluate(parityCase, declared: [], runs: runs, dumpingTo: dump)
        }
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        let found = try harness.differences(of: runs)
        for side in RouteParitySide.allCases {
            XCTAssertEqual(found[.side(side)]?.map(\.description) ?? [], [], "side \(side) names no other side's root")
        }
        XCTAssertEqual(found[.cAgainstCPrime]?.map(\.description) ?? [], [], "C against C' declares nothing")
        try assertAEqualsC(runs)
        try assertPredictedRecordChanges(runs, parityCase)
        return runs
    }

    /// A against C on the facts of 1.7. No file but the record and the inputs folder differs, and the compared facts
    /// of the record are equal. Side A writes three `resolved` keys and side C two, and `outputByteCount` is the one
    /// both write.
    private func assertAEqualsC(_ runs: RouteParityRuns) throws {
        let sidecarName = ProvenanceRecorder.fileSidecarURL(for: Self.outputURL(in: runs.a.root)).lastPathComponent
        let others = try harness.differences(runs.a, runs.c).filter {
            !$0.id.contains(sidecarName) && !$0.id.contains(ViewerExportSelection.inputsFolderName)
        }
        XCTAssertEqual(others.map(\.description), [], "only the record and the inputs folder may differ between A and C")

        let payloadA = try Data(contentsOf: Self.outputURL(in: runs.a.root))
        XCTAssertEqual(payloadA, try Data(contentsOf: Self.outputURL(in: runs.c.root)), "the payload byte for byte")
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let outputA = try XCTUnwrap(a.output)
        let outputC = try XCTUnwrap(c.output)
        XCTAssertNotNil(outputA.checksumSHA256)
        XCTAssertEqual(outputA.checksumSHA256, outputC.checksumSHA256, "the output digest")
        XCTAssertEqual(outputA.fileSize, UInt64(payloadA.count))
        XCTAssertEqual(outputA.fileSize, outputC.fileSize, "the output size")
        let resolvedA = a.options.resolvedDefaults
        let resolvedC = c.options.resolvedDefaults
        XCTAssertEqual(Set(resolvedA.keys), ["outputByteCount", "sequenceLength", "sourceCount"])
        XCTAssertEqual(Set(resolvedC.keys), ["outputByteCount", "recordCount"])
        XCTAssertEqual(resolvedA["outputByteCount"], resolvedC["outputByteCount"], "resolved outputByteCount")
        XCTAssertEqual(resolvedC["recordCount"], .integer(1))
    }

    /// The prediction rows of the lane report (BIO 4, 6 and 7). The five identity fields move from the app's writer
    /// to the leaf, the options that name the inputs change with them, the width becomes an explicit option of the
    /// run, and the input is the staged sequence the leaf reads, with its digest, where side A named the viewer's
    /// document it never opened. The record's argv is the row's command (ARCH 2).
    private func assertPredictedRecordChanges(_ runs: RouteParityRuns, _ parityCase: Case) throws {
        let sequence = try parityCase.sequence()
        let a = try Self.envelope(in: runs.a.root)
        let c = try Self.envelope(in: runs.c.root)
        let argvA = [
            "Lungfish Genome Explorer", "export-sequence-fasta",
            "--source", Self.documentURL(in: runs.a.root).standardizedFileURL.path,
            "--sequence", sequence.name, "--output", Self.outputURL(in: runs.a.root).path,
        ]
        XCTAssertEqual(a.toolName, "Lungfish.app")
        XCTAssertEqual(a.tool.kind, "gui")
        XCTAssertEqual(a.argv, argvA)
        XCTAssertEqual(a.durableReplayArgv, argvA)
        XCTAssertEqual(a.workflowName, "lungfish app sequence fasta export")
        let explicitA = ["outputPath", "sequenceName", "sourcePaths"] + (sequence.description == nil ? [] : ["sequenceDescription"])
        XCTAssertEqual(a.options.explicit.keys.sorted(), explicitA.sorted())
        XCTAssertEqual(a.options.defaults.keys.sorted(), ["lineWidth", "outputFormat"])
        XCTAssertEqual(a.options.defaults["lineWidth"], .integer(80))
        XCTAssertEqual(Self.inputs(of: a, under: runs.a.root).keys.sorted(), ["/" + Self.documentName], "side A names the document")

        let identity = FASTARecordsExport.sequenceIdentity(name: sequence.name, description: sequence.description)
        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(Array(rowArguments.prefix(2)), FASTARecordsExport.commandPath)
        XCTAssertTrue(rowArguments.contains("--sequence=\(identity)"), "\(rowArguments)")
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, FASTARecordsExport.workflowName)
        XCTAssertEqual(c.options.explicit.keys.sorted(), ["lineWidth", "outputPath", "sequences"])
        XCTAssertEqual(c.options.explicit["lineWidth"], .integer(80))
        XCTAssertEqual(c.options.explicit["sequences"], .array([.string(identity)]))
        XCTAssertTrue(c.options.defaults.isEmpty)

        let inputsC = Self.inputs(of: c, under: runs.c.root)
        XCTAssertEqual(inputsC.count, 1, "\(inputsC)")
        let stagedPath = try XCTUnwrap(inputsC.keys.first)
        XCTAssertTrue(stagedPath.hasPrefix("/" + ViewerExportSelection.inputsFolderName + "/"), stagedPath)
        XCTAssertTrue(stagedPath.hasSuffix("/" + FASTARecordsExport.stagedSequenceFileName), stagedPath)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: runs.c.root.path + stagedPath))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(inputsC[stagedPath], digest, "the record names \(stagedPath) with its digest")
        XCTAssertEqual(
            bytes,
            Data(FASTARecordsExport.sequenceText(
                name: sequence.name, description: sequence.description, bases: sequence.asString()
            ).utf8),
            "the staged file holds the data, with the bases on one line"
        )
    }

    /// Each input's path below `root`, with its digest.
    private static func inputs(of envelope: ProvenanceEnvelope, under root: URL) -> [String: String] {
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        var inputs: [String: String] = [:]
        for file in envelope.files where file.role == .input {
            let rootPath = rootPaths.first { file.path.hasPrefix($0 + "/") }
            inputs[rootPath.map { String(file.path.dropFirst($0.count)) } ?? file.path] = file.checksumSHA256 ?? "no digest"
        }
        return inputs
    }
}
