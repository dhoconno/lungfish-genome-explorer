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
/// renamed mapping result is pinned by `MappingDocumentCommandDisplayTests.testARenamedMappingResultsDocumentCommandAtTheBase`.
extension ProvenanceCommandDisplayTests {

    static let recordedArgv = [
        "lungfish-cli", "fastq", "trim", "@/Inputs/reads.fastq", "--output", "@/Analyses/fastq-trim/trimmed.fastq",
    ]

    /// A Move of `Analyses/fastq-trim` into `Analyses/Group` rewrites the record's descriptors as a rename does and keeps
    /// the argv a replay runs. The Command row finds no rename, because `folderRenames` looks for the moved file directly
    /// under the record's ancestor, so the row and Copy Command name the folder that is gone (12.25 review, optional 2).
    func testAMoveKeepsTheArgvAndTheCommandRowFindsNoRename() async throws {
        let moved = try movedRecord()
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: moved.recordURL)) as? [String: Any])
        let step = try XCTUnwrap((record["steps"] as? [[String: Any]])?.first)

        XCTAssertEqual(record["argv"] as? [String], Self.recordedArgv)
        XCTAssertEqual(record["durableReplayArgv"] as? [String], Self.recordedArgv)
        XCTAssertEqual(step["reproducibleCommand"] as? String, Self.recordedCommand)
        XCTAssertEqual((record["output"] as? [String: Any])?["path"] as? String, "@/Analyses/Group/fastq-trim/trimmed.fastq")

        let model = try await loadedModel(folder: moved.newFolder)
        let built = await model.renamedCommands()
        XCTAssertTrue(built.isEmpty, "a Move is not mapped at the base: \(built)")
        let shown = try XCTUnwrap(model.lineageRuns.last?.steps.first)
        XCTAssertEqual(shown.displayCommand, "lungfish-cli fastq trim Inputs/reads.fastq --output Analyses/fastq-trim/trimmed.fastq")
    }

    /// The Duplicate's copy keeps the argv, which names the source folder that is still there, while its descriptors
    /// name the copy. A replay of that argv reads and writes under the source.
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
    }

    /// A provenance export of a renamed record writes a script whose command is the recorded argv, so the script reads
    /// and writes under the folder that is gone.
    func testAShellExportOfARenamedRecordRunsTheArgvThatNamesTheGoneFolder() throws {
        let renamed = try renamedRecord()
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(fromSidecar: renamed.recordURL))
        let exportRoot = try TestTempDirectory.make(prefix: "provenance-replay-export")
        addTeardownBlock { TestTempDirectory.cleanup(exportRoot) }

        let bundle = try ProvenanceExporter(signingProvider: nil).exportBundle(
            envelope,
            format: .shell,
            to: exportRoot.appendingPathComponent("export", isDirectory: true),
            sourceSidecarURL: renamed.recordURL,
            sourceRootURL: renamed.newFolder,
            allowUnpinned: true
        )
        let script = try String(contentsOf: bundle.primaryArtifactURL, encoding: .utf8)
        let commands = script.split(separator: "\n").filter { $0.contains("fastq trim") && !$0.hasPrefix("#") }

        XCTAssertFalse(commands.isEmpty, script)
        XCTAssertTrue(commands.allSatisfy { $0.contains("Analyses/fastq-trim/trimmed.fastq") }, script)
        XCTAssertFalse(commands.contains { $0.contains("fastq-trim renamed") }, script)
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
    /// folder moved into `Analyses/Group` as the sidebar's Move to Folder moves it.
    func movedRecord() throws -> RenamedRecord {
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
        try Data(template.replacingOccurrences(of: "fastq-trim-cancelled", with: "fastq-trim").utf8)
            .write(to: oldFolder.appendingPathComponent(".lungfish-provenance.json"))
        try FileManager.default.moveItem(at: oldFolder, to: newFolder)
        SidebarViewController().rehydrateScientificProvenance(from: oldFolder, to: newFolder)
        return RenamedRecord(
            project: project, newFolder: newFolder, recordURL: newFolder.appendingPathComponent(".lungfish-provenance.json")
        )
    }
}
