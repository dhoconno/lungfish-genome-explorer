// SidebarMoveOfABuiltResultFolderReplayTests.swift - A sidebar rename, move or copy of a built result folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane R-REBIND, item 3 of BIO's verdict on FXA2 and ARCH's design in section 6 of the A31 review. A built
// result folder is a plain folder in a project, and it holds its own records, the batch's, each sample's and a sidecar
// for each file. A record in a project stores project-relative paths, so once the folder has a new name or a new place
// its records name files at the path it had, and a copy's records name the source's files.
//
// The sidebar moves or copies an item with `FileManager` and then calls `rehydrateScientificProvenance`
// (`SidebarViewController+ScientificProvenance.swift`). For a plain folder in a project that call used to look for the
// folder's record beside the folder, at the project root, in the project's roll-up and in the project's output sidecar
// for the folder. It never read the folder's own records, and it ended in `missingSourceProvenance` or in
// `outputPathNotMapped` and a log line. Each test here does what the sidebar does and then reads the records of the
// folder it leaves.
//
// The batch is built in process with a stand-in, `build-db kraken2` over `Tests/Fixtures/kraken2-mini`, so no real tool
// runs. The class name ends in ReplayTests, which sends it to the replay step with the other sidebar and classifier
// replays.

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class SidebarMoveOfABuiltResultFolderReplayTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var batch: URL!

    /// What the setup left, to compare with the folder after the sidebar's action.
    private struct Built {
        /// The digest of every record file under the project and outside the batch, by path below the project.
        var outside: [String: String]
        /// The digest of every record file under the batch, by path below it.
        var inside: [String: String]
        /// The commands the batch's records state, by record.
        var invocations: [String: [String]]
    }

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "SidebarMoveOfABuiltResultFolder")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        batch = project.appendingPathComponent("Analyses/kraken2-batch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Analyses", isDirectory: true), withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Rename and move

    /// A rename leaves records that name the folder's files at the new name. At the base the folder's records kept the
    /// old name, so each file they name was gone.
    func testARenamedKraken2BatchHoldsRecordsThatNameItsOwnFiles() async throws {
        let built = try await buildTheBatch()
        let renamed = project.appendingPathComponent("Analyses/kraken2-batch renamed", isDirectory: true)

        try FileManager.default.moveItem(at: batch, to: renamed)
        SidebarViewController().rehydrateScientificProvenance(from: batch, to: renamed)

        try assertTheRecordsNameTheirOwnFiles(at: renamed, from: batch, built)
    }

    /// A move to another folder of the project is the same, whether it comes from the menu or from a drag.
    func testAMovedKraken2BatchHoldsRecordsThatNameItsOwnFiles() async throws {
        let built = try await buildTheBatch()
        let archive = project.appendingPathComponent("Analyses/Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let moved = archive.appendingPathComponent("kraken2-batch", isDirectory: true)

        try FileManager.default.moveItem(at: batch, to: moved)
        SidebarViewController().rehydrateScientificProvenance(from: batch, to: moved)

        try assertTheRecordsNameTheirOwnFiles(at: moved, from: batch, built)
    }

    // MARK: - Duplicate and copy

    /// A duplicate and a drag copy leave records that name the copy's files, and the source's records stay as they were.
    /// At the base the copy's records named the source's files, and those files exist.
    func testACopiedKraken2BatchHoldsRecordsThatNameTheCopysFiles() async throws {
        let built = try await buildTheBatch()
        let copy = project.appendingPathComponent("Analyses/kraken2-batch copy", isDirectory: true)

        try FileManager.default.copyItem(at: batch, to: copy)
        SidebarViewController().rehydrateScientificProvenance(from: batch, to: copy)

        try assertTheRecordsNameTheirOwnFiles(at: copy, from: batch, built)
        let source = try recordDigests(in: batch)
        XCTAssertEqual(source, built.inside, "every record under the source is as it was")
    }

    /// `build-db kraken2` on a copy leaves the raw output that the copy's sample record names. FXA2's guard matches by
    /// resolved path, and a record that names the source's file says nothing about the copy's, so at the base the
    /// cleanup compacted the copy. The copy holds the source's `kraken2.sqlite`, and `build-db` keeps a database that
    /// exists unless `--force` (`BuildDbCommand+Kraken2Core.swift`, "Skip if exists"). So the run is forced, since
    /// without it the build ends before the cleanup and nothing is asked of the records.
    func testBuildDbOnACopiedKraken2BatchKeepsTheRawOutputItsRecordNames() async throws {
        _ = try await buildTheBatch()
        let copy = project.appendingPathComponent("Analyses/kraken2-batch copy", isDirectory: true)
        try FileManager.default.copyItem(at: batch, to: copy)
        SidebarViewController().rehydrateScientificProvenance(from: batch, to: copy)

        try await BuildDbCommand.Kraken2Subcommand.parse([copy.path, "--force", "-q"]).run()

        let raw = copy.appendingPathComponent("SRR35517702/classification.kraken")
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path), "the copy keeps the raw output its sample's record names")
        XCTAssertEqual(BuiltResultRecordChecks.problems(of: try BuiltResultRecordChecks.recordsOfTheTree(at: copy)), [])
    }

    // MARK: - The setup

    /// Steps 1 to 5 of the design. It builds the batch, writes the classifier's record for SRR35517702, runs
    /// `build-db kraken2`, makes one sidebar copy of a file so that the project holds a record, and returns the digests
    /// and the commands that `Built` keeps.
    private func buildTheBatch() async throws -> Built {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/kraken2-mini", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: batch)
        let sample = batch.appendingPathComponent("SRR35517702", isDirectory: true)
        // The record the app writes for a Kraken2 result, from the sidecar, as in FXA2's tests.
        try ProvenanceWriter().write(ClassificationProvenanceReconstructor.reconstructEnvelope(resultDirectory: sample), to: sample)
        try await BuildDbCommand.Kraken2Subcommand.parse([batch.path, "-q"]).run()

        let copies = project.appendingPathComponent("Copies", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        let database = batch.appendingPathComponent("kraken2.sqlite")
        let databaseCopy = copies.appendingPathComponent("kraken2 copy.sqlite")
        try FileManager.default.copyItem(at: database, to: databaseCopy)
        SidebarViewController().rehydrateScientificProvenance(from: database, to: databaseCopy)

        let outside = try recordDigests(in: project, excluding: [batch])
        XCTAssertFalse(outside.isEmpty, "the copy of a file left a record in the project")
        return Built(
            outside: outside,
            inside: try recordDigests(in: batch),
            invocations: invocations(of: try BuiltResultRecordChecks.recordsOfTheTree(at: batch))
        )
    }

    // MARK: - What the records must hold

    /// What a rename, a move and a copy all owe the folder at `destination`, which came from `source`.
    /// - The records name only files that exist, with the digests they state.
    /// - No record names a file under the old path of the folder, and some name its files at the new path.
    /// - Each record keeps the command that ran, which names the folder as it was then.
    /// - No record outside the two folders changed.
    private func assertTheRecordsNameTheirOwnFiles(
        at destination: URL, from source: URL, _ built: Built, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let records = try BuiltResultRecordChecks.recordsOfTheTree(at: destination)
        XCTAssertEqual(records.map(\.name), built.invocations.keys.sorted(), "the folder holds the records it held", file: file, line: line)
        XCTAssertEqual(BuiltResultRecordChecks.problems(of: records), [], "every file a record names exists as the record states", file: file, line: line)
        XCTAssertEqual(filesNamed(under: source, in: records), [], "no record names a file under the old path", file: file, line: line)
        XCTAssertFalse(filesNamed(under: destination, in: records).isEmpty, "the records name files at the new path", file: file, line: line)
        XCTAssertEqual(invocations(of: records), built.invocations, "each record keeps the command that ran", file: file, line: line)
        let outside = try recordDigests(in: project, excluding: [source, destination])
        XCTAssertEqual(outside, built.outside, "the records outside the folder are as they were", file: file, line: line)
    }

    /// One line for each file that a record names under `folder`. They are the files `problems(of:)` checks, from the
    /// run level and from each step's inputs and outputs, and argv is not among them.
    private func filesNamed(under folder: URL, in records: [(name: String, envelope: ProvenanceEnvelope)]) -> [String] {
        let prefix = BuiltResultRecordChecks.resolved(folder.path) + "/"
        var lines: Set<String> = []
        for (name, record) in records {
            let named = record.files + record.outputs + [record.output].compactMap { $0 } + record.steps.flatMap { $0.inputs + $0.outputs }
            for file in named {
                let path = BuiltResultRecordChecks.resolved(file.path)
                if path.hasPrefix(prefix) { lines.insert("\(name) names \(path)") }
            }
        }
        return lines.sorted()
    }

    /// The commands a record states, its own and each step's, by record. A rename or a move keeps the argv that ran.
    private func invocations(of records: [(name: String, envelope: ProvenanceEnvelope)]) -> [String: [String]] {
        var commands: [String: [String]] = [:]
        for (name, record) in records {
            var lines = ["argv " + record.argv.joined(separator: " "), "replay " + (record.durableReplayArgv ?? []).joined(separator: " ")]
            lines.append("command " + record.reproducibleCommand)
            for step in record.steps {
                lines.append("step \(step.toolName) argv " + step.argv.joined(separator: " "))
                lines.append("step \(step.toolName) replay " + (step.durableReplayArgv ?? []).joined(separator: " "))
                lines.append("step \(step.toolName) command " + step.reproducibleCommand)
            }
            commands[name] = lines
        }
        return commands
    }

    /// The digest of every record file under `folder` and outside `excluded`, by path below `folder`. A record file is a
    /// JSON file with `provenance` in its path, which is how `ProvenancePathRehydrator` finds the records of a folder.
    private func recordDigests(in folder: URL, excluding excluded: [URL] = []) throws -> [String: String] {
        let prefix = BuiltResultRecordChecks.resolved(folder.path) + "/"
        let skipped = excluded.map { BuiltResultRecordChecks.resolved($0.path) + "/" }
        let urls = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL } ?? []
        var digests: [String: String] = [:]
        for url in urls where url.pathExtension.lowercased() == "json" {
            let path = BuiltResultRecordChecks.resolved(url.path)
            let relative = String(path.dropFirst(prefix.count))
            guard path.hasPrefix(prefix), relative.lowercased().contains("provenance"),
                  !skipped.contains(where: { path.hasPrefix($0) }),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            digests[relative] = ProvenanceRecorder.sha256(of: url) ?? "unreadable"
        }
        return digests
    }
}
