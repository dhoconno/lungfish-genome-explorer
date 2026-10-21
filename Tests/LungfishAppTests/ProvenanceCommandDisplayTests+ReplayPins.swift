// ProvenanceCommandDisplayTests+ReplayPins.swift - What a Move, a Duplicate and the two replays do with a moved record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.45 (SW2 R-REPLAY), milestone M0. Each pin records the base. A Move of a result folder, the
/// Duplicate's copy, a provenance export of a renamed record and `--repeat-from` on a renamed analysis folder. The
/// renamed mapping result is pinned by
/// `MappingDocumentCommandDisplayTests.testARenamedMappingResultsDocumentTabShowsTheCommandMappedByTheRelocation`.
extension ProvenanceCommandDisplayTests {

    static let recordedArgv = [
        "lungfish-cli", "fastq", "trim", "@/Inputs/reads.fastq", "--output", "@/Analyses/fastq-trim/trimmed.fastq",
    ]

    /// A Move of `Analyses/fastq-trim` into `Analyses/Group` rewrites the record's descriptors as a rename does and keeps
    /// the argv a replay runs (D1). `folderRenames` reads the Move (ARCH C1, Q2), so the Command row and Copy Command name
    /// the moved folder, and Copy Command names no fresh folder (ruling 3(b) of 12.25). At the base the row named the
    /// folder that is gone.
    func testAMoveKeepsTheArgvAndTheCommandRowShowsTheMovedFolder() async throws {
        let moved = try movedRecord()
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: moved.recordURL)) as? [String: Any])
        let step = try XCTUnwrap((record["steps"] as? [[String: Any]])?.first)

        XCTAssertEqual(record["argv"] as? [String], Self.recordedArgv)
        XCTAssertEqual(record["durableReplayArgv"] as? [String], Self.recordedArgv)
        XCTAssertEqual(step["reproducibleCommand"] as? String, Self.recordedCommand)
        XCTAssertEqual((record["output"] as? [String: Any])?["path"] as? String, "@/Analyses/Group/fastq-trim/trimmed.fastq")

        let model = try await loadedModel(folder: moved.newFolder)
        let built = await model.renamedCommands()
        let shown = try XCTUnwrap(model.lineageRuns.last?.steps.first)
        let mapped = try XCTUnwrap(built[shown.id], "a Move is mapped: \(built)")
        let redact = ProvenanceDisplayRedaction(projectURL: moved.project)
        XCTAssertEqual(mapped.label, "lungfish-cli fastq trim Inputs/reads.fastq --output Analyses/Group/fastq-trim/trimmed.fastq")
        XCTAssertEqual(
            redact(mapped.copyCommand),
            "lungfish-cli fastq trim <project>/Inputs/reads.fastq --output <project>/Analyses/Group/fastq-trim/trimmed.fastq"
        )
        XCTAssertEqual(
            mapped.note,
            "This command ran in Analyses/fastq-trim. The row and Copy Command name Analyses/Group/fastq-trim, where the record is now."
        )
    }

    /// A record whose command names two old folders that could each have moved to the record's folder cannot say which
    /// one did, so `folderRenames` maps neither and the row shows the command as recorded (ARCH C1, the pin of Q2).
    func testTwoOldFoldersForOneMovedFolderMapNothing() async throws {
        let moved = try movedRecord(secondOldFolder: true)
        let model = try await loadedModel(folder: moved.newFolder)
        let envelope = try XCTUnwrap(model.resolvedEnvelope)
        let files = envelope.files + envelope.outputs + envelope.steps.flatMap { $0.inputs + $0.outputs }

        XCTAssertEqual(ProvenanceCommandPresentation.folderRenames(
            commands: envelope.steps.map(\.reproducibleCommand),
            filePaths: files.map(\.path),
            recordURL: moved.recordURL,
            projectURL: moved.project
        ), [])
        let built = await model.renamedCommands()
        XCTAssertTrue(built.isEmpty, "\(built)")
        let shown = try XCTUnwrap(model.lineageRuns.last?.steps.first)
        XCTAssertEqual(
            shown.displayCommand,
            "lungfish-cli fastq trim Inputs/reads.fastq --output Analyses/fastq-trim/trimmed.fastq --report Other/fastq-trim/trimmed.fastq"
        )
    }

    /// The Duplicate's copy keeps the argv, which names the source folder that is still there, while its descriptors
    /// name the copy. Its replay writes only `$OUTDIR` and never names the source (ARCH C2). At the base the replay of
    /// that argv read and wrote under the source.
    func testADuplicateKeepsTheArgvNamingTheSourceFolder() throws {
        let copy = try renamedRecord(duplicating: true)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: copy.recordURL)) as? [String: Any])

        XCTAssertEqual(record["argv"] as? [String], Self.recordedArgv)
        XCTAssertEqual(record["durableReplayArgv"] as? [String], Self.recordedArgv)
        XCTAssertEqual((record["output"] as? [String: Any])?["path"] as? String, "@/Analyses/fastq-trim copy/trimmed.fastq")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: copy.project.appendingPathComponent("Analyses/fastq-trim/trimmed.fastq").path),
            "the source folder the argv names is still there"
        )
        let script = try exportedShellScript(of: copy)
        let commands = script.split(separator: "\n").filter { $0.contains("fastq trim") && !$0.hasPrefix("#") }
        XCTAssertEqual(commands.count, 1, script)
        XCTAssertTrue(commands.allSatisfy { $0.contains("$OUTDIR/trimmed.fastq") }, script)
        XCTAssertFalse(script.contains("Analyses/fastq-trim/"), script)
    }

    /// A provenance export of a renamed record replays the argv through the record's relocation (ARCH C2 to C5). The
    /// input keeps its place, the output goes to `$OUTDIR`, and no command names the gone folder or the renamed one. At
    /// the base the script ran the recorded argv, which reads and writes under the folder that is gone.
    func testAShellExportOfARenamedRecordWritesOnlyTheNewFolder() throws {
        let renamed = try renamedRecord()
        let script = try exportedShellScript(of: renamed)
        let commands = script.split(separator: "\n").filter { $0.contains("fastq trim") && !$0.hasPrefix("#") }

        XCTAssertEqual(commands.count, 1, script)
        XCTAssertTrue(commands.allSatisfy { $0.contains("$PROJECT/Inputs/reads.fastq") && $0.contains("$OUTDIR/trimmed.fastq") }, script)
        XCTAssertFalse(commands.contains { $0.contains("Analyses/fastq-trim/") || $0.contains("fastq-trim renamed") }, script)
        XCTAssertTrue(script.contains("mkdir -- \"$OUTDIR\"\n"), script)
        XCTAssertTrue(script.contains("lge_check_input \"$PROJECT/Inputs/reads.fastq\" 77b2c08a74e4bd9a22d68363ffc9497d9844dda883866251af8b1a5e32a75781\n"), script)
    }

    /// The shell script a provenance export writes for `record`.
    func exportedShellScript(of record: RenamedRecord) throws -> String {
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(fromSidecar: record.recordURL))
        let exportRoot = try TestTempDirectory.make(prefix: "provenance-replay-export")
        addTeardownBlock { TestTempDirectory.cleanup(exportRoot) }
        let bundle = try ProvenanceExporter(signingProvider: nil).exportBundle(
            envelope,
            format: .shell,
            to: exportRoot.appendingPathComponent("export", isDirectory: true),
            sourceSidecarURL: record.recordURL,
            sourceRootURL: record.newFolder,
            allowUnpinned: true
        )
        return try String(contentsOf: bundle.primaryArtifactURL, encoding: .utf8)
    }

    /// `--repeat-from` reads only a local run history bundle, so a renamed analysis folder is refused before anything
    /// runs, and the provenance export is the one replay that reads such a record.
    func testRepeatFromRefusesARenamedAnalysisFolder() throws {
        let renamed = try renamedRecord()
        XCTAssertThrowsError(try LocalWorkflowReplayPreflight.load(from: renamed.newFolder)) { error in
            XCTAssertTrue(
                String(describing: error).contains("Choose an existing local run history bundle."),
                String(describing: error)
            )
        }
    }

    /// The cancelled `fastq trim` record written into `Analyses/fastq-trim`, with its input and output on disk, and the
    /// folder moved into `Analyses/Group` as the sidebar's Move to Folder moves it. With `secondOldFolder` the step's
    /// command also names `Other/fastq-trim`, a second folder that could have moved there.
    func movedRecord(secondOldFolder: Bool = false) throws -> RenamedRecord {
        let root = try TestTempDirectory.make(prefix: "provenance-replay-move")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Commands.lungfish", isDirectory: true)
        let oldFolder = project.appendingPathComponent("Analyses/fastq-trim", isDirectory: true)
        let newFolder = project.appendingPathComponent("Analyses/Group/fastq-trim", isDirectory: true)
        let template = try String(
            contentsOf: ProvenanceDisplayFixtures.directory
                .appendingPathComponent("Analyses/fastq-trim-cancelled/.lungfish-provenance.json"),
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: newFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Inputs"), withIntermediateDirectories: true)
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: project.appendingPathComponent("Inputs/reads.fastq"))
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: oldFolder.appendingPathComponent("trimmed.fastq"))
        let output = "--output @/Analyses/fastq-trim-cancelled/trimmed.fastq\""
        let text = secondOldFolder
            ? template.replacingOccurrences(of: output, with: String(output.dropLast()) + " --report @/Other/fastq-trim/trimmed.fastq\"")
            : template
        try Data(text.replacingOccurrences(of: "fastq-trim-cancelled", with: "fastq-trim").utf8)
            .write(to: oldFolder.appendingPathComponent(".lungfish-provenance.json"))
        try FileManager.default.moveItem(at: oldFolder, to: newFolder)
        SidebarViewController().rehydrateScientificProvenance(from: oldFolder, to: newFolder)
        return RenamedRecord(
            project: project, newFolder: newFolder, recordURL: newFolder.appendingPathComponent(".lungfish-provenance.json")
        )
    }
}
