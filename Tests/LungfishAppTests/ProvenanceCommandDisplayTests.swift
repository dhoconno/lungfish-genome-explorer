// ProvenanceCommandDisplayTests.swift - The shown and copied command of a renamed record and of a managed tool
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// Phase 2.12 lane 12.25 (CMD-DISPLAY), rows RENAME-COMMAND (R-B2), SW17 (a) (Q-U6) and SW2.
///
/// A sidebar rename of a result folder rewrites the paths its record names and keeps every command as it ran
/// (`ProvenancePathRehydrator.preservesExactInvocationValue`). The record here is the cancelled `fastq trim` record of
/// `Tests/Fixtures/provenance-display`, written into `Analyses/fastq-trim` of a temporary project, and the test renames
/// that folder to `fastq-trim renamed` the way the sidebar does.
@MainActor
final class ProvenanceCommandDisplayTests: XCTestCase {
    private var pasteboard: NSPasteboard?

    override func tearDown() async throws {
        pasteboard?.releaseGlobally()
        pasteboard = nil
        try await super.tearDown()
    }

    // MARK: - The record a rename leaves

    /// The rename moves the paths the record names to the new folder and keeps the command and the argv a replay
    /// runs as they ran, so both name the old folder, which is gone (SW2's state at the base).
    func testARenameMovesTheRecordsPathsAndKeepsTheArgvAReplayRuns() throws {
        let renamed = try renamedRecord()
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: renamed.recordURL)) as? [String: Any])
        let step = try XCTUnwrap((record["steps"] as? [[String: Any]])?.first)
        let oldOutput = "@/Analyses/fastq-trim/trimmed.fastq"
        let argv = ["lungfish-cli", "fastq", "trim", "@/Inputs/reads.fastq", "--output", oldOutput]

        XCTAssertEqual(record["argv"] as? [String], argv)
        XCTAssertEqual(record["durableReplayArgv"] as? [String], argv)
        XCTAssertEqual(step["argv"] as? [String], argv)
        XCTAssertEqual(step["reproducibleCommand"] as? String, Self.recordedCommand)
        XCTAssertEqual(record["reproducibleCommand"] as? String, Self.recordedCommand)
        XCTAssertEqual((record["output"] as? [String: Any])?["path"] as? String, "@/Analyses/fastq-trim renamed/trimmed.fastq")
        XCTAssertEqual(
            (step["outputs"] as? [[String: Any]])?.compactMap { $0["path"] as? String },
            ["@/Analyses/fastq-trim renamed/trimmed.fastq"]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: renamed.project.appendingPathComponent("Analyses/fastq-trim").path),
            "the folder the argv names is gone"
        )
    }

    /// Showing the step and copying its command leave the record's bytes as the rename wrote them (QA 1, BIO 4).
    func testShowingAndCopyingARenamedRecordsCommandLeavesItsBytes() async throws {
        let renamed = try renamedRecord()
        let bytes = try Data(contentsOf: renamed.recordURL)
        let model = try await loadedModel(folder: renamed.newFolder)
        let step = try XCTUnwrap(model.lineageRuns.last?.steps.first)

        XCTAssertFalse(step.displayCommand.isEmpty)
        XCTAssertNotNil(try copied("Copy Command", of: step, in: model))
        XCTAssertNotNil(try copied("Copy Step", of: step, in: model))
        XCTAssertEqual(try Data(contentsOf: renamed.recordURL), bytes, "the record keeps the bytes the rename wrote")
    }

    // MARK: - The Command row and Copy Command of a renamed record

    /// R-B2 in UX's placement (T4). The Command row and Copy Command name the renamed folder, the note beside the row
    /// says where the command ran, the row's tooltip and Copy Step keep the command as it ran, and the copied text
    /// holds no note. At the base the row and Copy Command named the old folder, which is gone, and there was no note.
    func testARenamedRecordsCommandRowAndCopyCommandNameTheRenamedFolder() async throws {
        let renamed = try renamedRecord()
        let model = try await loadedModel(folder: renamed.newFolder)
        let step = try XCTUnwrap(model.lineageRuns.last?.steps.first)
        let redact = ProvenanceDisplayRedaction(projectURL: renamed.project)
        let envelope = try XCTUnwrap(model.resolvedEnvelope)
        let built = await model.renamedCommands()
        XCTAssertEqual(
            built.keys.sorted(), [step.id],
            "\(String(describing: model.resolvedSidecarURL)) \(envelope.steps.map(\.reproducibleCommand)) \(envelope.outputs.map(\.path))"
        )
        let board = NSPasteboard(name: NSPasteboard.Name("ProvenanceCommandDisplayTests-\(UUID().uuidString)"))
        pasteboard = board
        model.pasteboard = board
        let window = AccessibilityTreeProbe.host(ProvenanceSection(viewModel: model))
        defer { window.orderOut(nil) }

        XCTAssertTrue(AccessibilityTreeProbe.press(try element("provenance-run-1", in: window)))
        XCTAssertTrue(AccessibilityTreeProbe.press(try element("provenance-run-1-step-1", in: window)))
        // The tab builds the renamed command in a task, which runs once this test yields the main actor.
        _ = await waitUntil(timeout: .seconds(30)) {
            AccessibilityTreeProbe.element(in: window, identifier: "provenance-step-command-rename-note") != nil
        }
        let note = try element("provenance-step-command-rename-note", in: window)
        XCTAssertEqual(
            AccessibilityTreeProbe.label(note) ?? AccessibilityTreeProbe.value(note),
            "This command ran in Analyses/fastq-trim. "
                + "The row and Copy Command name Analyses/fastq-trim renamed, where the record is now."
        )
        let command = try element("provenance-step-command", in: window)
        XCTAssertEqual(
            AccessibilityTreeProbe.label(command),
            "lungfish-cli fastq trim Inputs/reads.fastq --output 'Analyses/fastq-trim renamed/trimmed.fastq'"
        )
        XCTAssertEqual(
            AccessibilityTreeProbe.help(command).map { redact($0) },
            "lungfish-cli fastq trim <project>/Inputs/reads.fastq --output <project>/Analyses/fastq-trim/trimmed.fastq"
        )
        XCTAssertTrue(AccessibilityTreeProbe.performCustomAction(named: "Copy Command", on: command))
        XCTAssertEqual(
            board.string(forType: .string).map { redact($0) },
            "lungfish-cli fastq trim <project>/Inputs/reads.fastq --output '<project>/Analyses/fastq-trim renamed/trimmed.fastq'"
        )
        let copyStep = try XCTUnwrap(try copied("Copy Step", of: step, in: model).map { redact($0) })
        XCTAssertTrue(
            copyStep.contains("\nCommand: lungfish-cli fastq trim <project>/Inputs/reads.fastq --output "
                + "<project>/Analyses/fastq-trim/trimmed.fastq\n"),
            copyStep
        )
    }

    // MARK: - The note of a duplicated folder (UX ruling 3, the new finding)

    /// The sidebar's Duplicate copies a result folder and rebinds the copy's record, which then names the copy's files
    /// while its command names the source. That is the trace a rename leaves, so the step gets a note, and Copy Command
    /// names the copy, whose files a pasted run reads. Nothing was renamed, so the note never says so. At the base it
    /// read "Paths that the rename of Analyses/fastq-trim moved now name Analyses/fastq-trim copy."
    func testADuplicatedFoldersNoteDoesNotSayRename() async throws {
        let duplicated = try renamedRecord(duplicating: true)
        let model = try await loadedModel(folder: duplicated.newFolder)
        let step = try XCTUnwrap(model.lineageRuns.last?.steps.first)
        let redact = ProvenanceDisplayRedaction(projectURL: duplicated.project)
        let built = await model.renamedCommands()
        let moved = try XCTUnwrap(built[step.id], "the copy's command names the source folder, so the step has a note")

        XCTAssertFalse(moved.note.localizedCaseInsensitiveContains("rename"), moved.note)
        XCTAssertEqual(
            moved.note,
            "This command ran in Analyses/fastq-trim. "
                + "The row and Copy Command name Analyses/fastq-trim copy, where the record is now."
        )
        XCTAssertEqual(
            redact(moved.copyCommand),
            "lungfish-cli fastq trim <project>/Inputs/reads.fastq --output '<project>/Analyses/fastq-trim copy/trimmed.fastq'"
        )
    }

    // MARK: - A managed tool under the reader's storage root (SW17 (a))

    /// The released 2026.9.58 record names `<tool-root>/envs/htslib/bin/bgzip`, and a tool under the reader's own tool
    /// root shows its name (Q-U6), so the record reads one way under every storage root. At the base it read
    /// `conda/envs/htslib/bin/bgzip` under a root named `.lungfish`, which the path presentation took for a project,
    /// `bgzip` under a temporary root with another name, and the whole path on this Mac with the variable unset.
    func testTheReleasedBgzipCommandReadsTheSameUnderEveryStorageRoot() async throws {
        let roots = try TestTempDirectory.make(prefix: "provenance-command-display-roots")
        addTeardownBlock { TestTempDirectory.cleanup(roots) }
        let unset = try await bgzipCommand(storageRoot: nil)
        let named = try await bgzipCommand(storageRoot: roots.appendingPathComponent("a/.lungfish", isDirectory: true))
        let other = try await bgzipCommand(storageRoot: roots.appendingPathComponent("b/lungfish-storage", isDirectory: true))

        XCTAssertEqual(unset, "bgzip " + Self.bgzipArguments)
        XCTAssertEqual(named, "bgzip " + Self.bgzipArguments)
        XCTAssertEqual(other, "bgzip " + Self.bgzipArguments)
    }

    // MARK: - Fixtures

    static let recordedCommand = "lungfish-cli fastq trim @/Inputs/reads.fastq --output @/Analyses/fastq-trim/trimmed.fastq"
    static let bgzipArguments = "-f -@ 13 'Reference Sequences/.SIMULATED-MHC-annotated-reference.building-"
        + "B15F0112-6EB2-49B3-91D6-4BA746B3B508/genome/sequence.fa'"

    struct RenamedRecord {
        let project: URL
        let newFolder: URL
        let recordURL: URL
    }

    /// The cancelled `fastq trim` record written into `Analyses/fastq-trim`, with its input and output on disk, and the
    /// folder renamed to `fastq-trim renamed` as the sidebar renames it. With `duplicating` the folder is copied to
    /// `fastq-trim copy` as the sidebar's Duplicate copies it, and the source stays where it is.
    func renamedRecord(duplicating: Bool = false) throws -> RenamedRecord {
        let root = try TestTempDirectory.make(prefix: "provenance-command-display")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Commands.lungfish", isDirectory: true)
        let oldFolder = project.appendingPathComponent("Analyses/fastq-trim", isDirectory: true)
        let newFolder = project.appendingPathComponent(
            duplicating ? "Analyses/fastq-trim copy" : "Analyses/fastq-trim renamed", isDirectory: true
        )
        let template = try String(
            contentsOf: ProvenanceDisplayFixtures.directory
                .appendingPathComponent("Analyses/fastq-trim-cancelled/.lungfish-provenance.json"),
            encoding: .utf8
        )
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Inputs"), withIntermediateDirectories: true)
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: project.appendingPathComponent("Inputs/reads.fastq"))
        try Data("@r\nACGT\n+\nIIII\n".utf8).write(to: oldFolder.appendingPathComponent("trimmed.fastq"))
        try Data(template.replacingOccurrences(of: "fastq-trim-cancelled", with: "fastq-trim").utf8)
            .write(to: oldFolder.appendingPathComponent(".lungfish-provenance.json"))

        if duplicating {
            try FileManager.default.copyItem(at: oldFolder, to: newFolder)
        } else {
            try FileManager.default.moveItem(at: oldFolder, to: newFolder)
        }
        SidebarViewController().rehydrateScientificProvenance(from: oldFolder, to: newFolder)
        return RenamedRecord(
            project: project, newFolder: newFolder, recordURL: newFolder.appendingPathComponent(".lungfish-provenance.json")
        )
    }

    func loadedModel(folder: URL) async throws -> ProvenanceInspectorViewModel {
        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: folder, sidebarType: .analysisResult, contentMode: .genomics, displayName: folder.lastPathComponent
        ))
        let finished = await waitUntil(timeout: .seconds(30)) { !model.isLoading && !model.lineageRuns.isEmpty }
        XCTAssertTrue(finished, "The provenance lookup did not finish.")
        XCTAssertNotNil(model.resolvedEnvelope, "The record was not found.")
        return model
    }

    private func element(_ identifier: String, in window: NSWindow) throws -> NSObject {
        AccessibilityTreeProbe.waitUntil(timeout: 10) { AccessibilityTreeProbe.element(in: window, identifier: identifier) != nil }
        return try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: identifier),
            "no \(identifier); tree:\n" + AccessibilityTreeProbe.dump(window)
        )
    }

    /// The text one of a Lineage step's copy commands writes, on a private pasteboard.
    func copied(_ title: String, of step: ProvenanceLineageStep, in model: ProvenanceInspectorViewModel) throws -> String? {
        let board = NSPasteboard(name: NSPasteboard.Name("ProvenanceCommandDisplayTests-\(UUID().uuidString)"))
        pasteboard?.releaseGlobally()
        pasteboard = board
        model.pasteboard = board
        let run = try XCTUnwrap(model.lineageRuns.last)
        let action = try XCTUnwrap(model.stepCopyActions(step, in: run).first { $0.title == title }, title)
        guard case let .command(_, isEnabled, perform) = action.kind, isEnabled else {
            XCTFail("\(title) is not an enabled command")
            return nil
        }
        perform()
        return board.string(forType: .string)
    }

    /// The bgzip step's Command row of the released MHC record, read with `LUNGFISH_STORAGE_ROOT` at `storageRoot`
    /// (unset when nil) and `LUNGFISH_CONDA_ROOT` unset. Both variables are put back before it returns.
    func bgzipCommand(storageRoot: URL?) async throws -> String {
        let saved = ["LUNGFISH_STORAGE_ROOT", "LUNGFISH_CONDA_ROOT"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (name, value) in saved {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        unsetenv("LUNGFISH_CONDA_ROOT")
        if let storageRoot {
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            setenv("LUNGFISH_STORAGE_ROOT", storageRoot.path, 1)
        } else {
            unsetenv("LUNGFISH_STORAGE_ROOT")
        }

        let root = try TestTempDirectory.make(prefix: "provenance-command-display-mhc")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let bundlePath = "Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref"
        let bundle = root.appendingPathComponent("Commands.lungfish/\(bundlePath)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: ProvenanceDisplayFixtures.directory.appendingPathComponent("\(bundlePath)/.lungfish-provenance.json"),
            to: bundle.appendingPathComponent(".lungfish-provenance.json")
        )
        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: bundle, sidebarType: .referenceBundle, contentMode: .genomics,
            displayName: "SIMULATED-MHC-annotated-reference"
        ))
        let finished = await waitUntil(timeout: .seconds(30)) { !model.isLoading && !model.lineageRuns.isEmpty }
        XCTAssertTrue(finished, "The provenance lookup did not finish.")
        let step = try XCTUnwrap(model.lineageRuns.last?.steps.first { $0.toolName == "bgzip" })
        return step.displayCommand
    }
}
