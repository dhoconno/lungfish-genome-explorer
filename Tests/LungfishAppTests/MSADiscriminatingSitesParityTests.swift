// MSADiscriminatingSitesParityTests.swift - The Inspector's run equals a hand-written CLI run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/CLI-EQUIVALENCE.md. Each test runs Find Discriminating Sites
// the way the window does: InspectorViewController builds the model, the
// model's request goes through runMSADiscriminatingSites, the Operation
// Center, CLIMSAActionRunner and a lungfish-cli subprocess, and the section
// reads the JSON report back. The same selection is then written by hand as a
// lungfish-cli command, run in this process, and the two report sets are
// compared with OutputEquivalence. The rows-mode test is pure Swift and runs
// in the unit tier. The file-mode test needs the managed MAFFT, so its class
// name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class MSADiscriminatingSitesParityTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "msa-discriminating-parity")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// Two targets, one exclusion row, one skipped row and a template that is not
    /// the first target, so the GUI argv carries --targets, --exclusions and --template.
    func testRowsModeInspectorRunEqualsAHandWrittenCommand() async throws {
        let fixture = try DiscriminatingSitesParityFixture(root: scratch)
        let run = try await fixture.runThroughInspector { model in
            let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.name, $0) })
            model.setRole(.exclusion, for: try XCTUnwrap(rows["x1"]))
            model.setRole(.skip, for: try XCTUnwrap(rows["t3"]))
            model.templateRowID = try XCTUnwrap(rows["t2"]).id
        }
        let parsed = try RecordedCLICommand.parseScript(run.recordedCommand)
        XCTAssertEqual(parsed.count, 1)
        let command = try XCTUnwrap(parsed.first as? MSACommand.DiscriminatingSitesSubcommand)
        XCTAssertEqual(command.targets, "t1,t2")
        XCTAssertEqual(command.exclusions, "x1")
        XCTAssertEqual(command.template, "t2")
        XCTAssertEqual(run.model.report?.targetNames, ["t1", "t2"])
        XCTAssertEqual(run.model.report?.exclusionNames, ["x1"])
        XCTAssertFalse(run.model.sites.isEmpty, "the fixture must yield sites, or the comparison proves nothing")

        try await fixture.assertHandWrittenRunMatches(run, arguments: [
            "--targets", "t1,t2",
            "--exclusions", "x1",
            "--template", "t2",
        ])
    }
}

@MainActor
final class MSADiscriminatingSitesParityReplayTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "msa-discriminating-parity-file")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// Exclusions from a FASTA file in the project's Reference Sequences folder,
    /// chosen from the section's project menu, with the alignment's x1 row skipped.
    func testFileModeInspectorRunEqualsAHandWrittenCommand() async throws {
        let mafft = CoreToolLocator.managedExecutableURL(
            environment: "mafft", executableName: "mafft",
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: mafft.path), "file mode needs the managed MAFFT")
        let fixture = try DiscriminatingSitesParityFixture(root: scratch)
        let run = try await fixture.runThroughInspector { model in
            model.exclusionSource = .file
            model.exclusionFileURL = fixture.exclusionFASTAURL.standardizedFileURL
            model.setRole(.skip, for: try XCTUnwrap(model.rows.first { $0.name == "x1" }))
        }
        let parsed = try RecordedCLICommand.parseScript(run.recordedCommand)
        let command = try XCTUnwrap(parsed.first as? MSACommand.DiscriminatingSitesSubcommand)
        XCTAssertEqual(command.targets, "t1,t2,t3")
        XCTAssertEqual(command.exclusionSequencesPath, fixture.exclusionFASTAURL.standardizedFileURL.path)
        XCTAssertEqual(run.model.report?.targetNames, ["t1", "t2", "t3"])
        XCTAssertEqual(run.model.report?.exclusionNames, ["e1", "e2"])
        XCTAssertFalse(run.model.sites.isEmpty, "the fixture must yield sites, or the comparison proves nothing")

        try await fixture.assertHandWrittenRunMatches(run, arguments: [
            "--targets", "t1,t2,t3",
            "--exclusion-sequences", fixture.exclusionFASTAURL.path,
        ])
    }
}

/// A project holding one small alignment and one unaligned exclusion FASTA.
@MainActor
private struct DiscriminatingSitesParityFixture {
    struct InspectorRun {
        let model: MSADiscriminatingSitesInspectorModel
        let recordedCommand: String?
        let outputURL: URL
    }

    let root: URL
    let bundleURL: URL
    let exclusionFASTAURL: URL

    // The targets share A at columns 5, 18 and 31. x1 and both exclusion
    // sequences carry another base there. t3 differs from t1 and t2 at column 12.
    private static let alignment = """
    >t1
    ACGTAGTTAGCATCGATCGGATCCATGCAAGCTTGCATGC
    >t2
    ACGTAGTTAGCATCGATCGGATCCATGCAAGCTTGCATGC
    >t3
    ACGTAGTTAGCTTCGATCGGATCCATGCAAGCTTGCATGC
    >x1
    ACGTCGTTAGCATCGATGGGATCCATGCACGCTTGCATGC
    """
    private static let exclusions = """
    >e1
    ACGTGGTTAGCATCGATTGGATCCATGCATGCTTGCATGC
    >e2
    ACGTTGTTAGCATCGATCGGATCCATGCAGGCTTGCATGC
    """

    init(root: URL) throws {
        self.root = root
        let project = root.appendingPathComponent("Parity.lungfish", isDirectory: true)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let references = project.appendingPathComponent(ReferenceSequenceFolder.folderName, isDirectory: true)
        for folder in [analyses, references] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let source = root.appendingPathComponent("panel.fasta")
        try Self.alignment.write(to: source, atomically: true, encoding: .utf8)
        bundleURL = analyses.appendingPathComponent("panel.lungfishmsa", isDirectory: true)
        _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundleURL, options: .init(name: "panel"))
        exclusionFASTAURL = references.appendingPathComponent("exclusions.fasta")
        try Self.exclusions.write(to: exclusionFASTAURL, atomically: true, encoding: .utf8)
    }

    /// Runs Find Discriminating Sites through the Inspector exactly as the button does.
    func runThroughInspector(
        _ configure: (MSADiscriminatingSitesInspectorModel) throws -> Void
    ) async throws -> InspectorRun {
        let cli = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/lungfish-cli")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "build lungfish-cli first")
        // CLIBinaryLocator would otherwise ask swift build for its bin path,
        // which waits on the build lock swift test holds.
        let priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        defer {
            if let priorCLIPath { setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }

        let bundle = try MultipleSequenceAlignmentBundle.load(from: bundleURL)
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()
        inspector.updateMultipleSequenceAlignmentDocument(bundle)
        let model = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.msaDiscriminatingSites)
        try configure(model)
        XCTAssertTrue(model.canRun, model.validationMessage ?? "")
        model.requestRun()
        XCTAssertEqual(model.status, .running)
        let finished = await waitUntil(timeout: .seconds(120)) { model.status != .running }
        XCTAssertTrue(finished, "the run did not finish")
        XCTAssertEqual(model.status, .ready)
        let item = OperationCenter.shared.items.first {
            $0.title == "Find Discriminating Sites"
                && $0.targetBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL
        }
        XCTAssertEqual(item?.state, .completed)
        return InspectorRun(
            model: model,
            recordedCommand: item?.cliCommand,
            outputURL: try XCTUnwrap(model.lastOutputURL)
        )
    }

    /// Runs the same selection written by hand and compares the TSV, the
    /// candidate-window TSV and the JSON report with the Inspector's.
    func assertHandWrittenRunMatches(_ run: InspectorRun, arguments: [String]) async throws {
        let handFolder = root.appendingPathComponent("hand", isDirectory: true)
        try FileManager.default.createDirectory(at: handFolder, withIntermediateDirectories: true)
        let handOutput = handFolder.appendingPathComponent(run.outputURL.lastPathComponent)
        let handWritten = OperationCenter.buildCLICommand(
            subcommand: "msa discriminating-sites",
            args: [bundleURL.path] + arguments + ["--output", handOutput.path]
        )
        try await RecordedCLICommand.runInProcess(handWritten)

        let compareGUI = root.appendingPathComponent("compare-gui", isDirectory: true)
        let compareHand = root.appendingPathComponent("compare-hand", isDirectory: true)
        for (output, folder) in [(run.outputURL, compareGUI), (handOutput, compareHand)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in [
                output,
                MSADiscriminatingSitesRequest.defaultWindowsOutputURL(for: output),
                MSADiscriminatingSitesRequest.defaultJSONOutputURL(for: output),
            ] {
                try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
            }
        }
        OutputEquivalence.assertSame(compareGUI, compareHand, kind: .files)
    }
}
