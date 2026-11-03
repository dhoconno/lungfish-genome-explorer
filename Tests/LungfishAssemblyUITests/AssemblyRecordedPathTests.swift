// AssemblyRecordedPathTests.swift - An assembly result reads the folder it is in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane ASSEMBLY-PATH (BIO-ASSEMBLY-RECORDED-PATH). `assembly-result.json` names the folder the run wrote, and a
// result that was moved, renamed or copied is somewhere else. BLAST Contig, Copy FASTA and the saved-search scan must read
// the folder the result was loaded from, and BLAST Contig must say so when it cannot read the contigs. These extend the
// classes the ruling names, in one file, since `AssemblyResultViewControllerTests.swift` is over 800 lines and may not grow.

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishAssemblyUI
@testable import LungfishWorkflow

private final class RecordedArgumentsBox: @unchecked Sendable {
    var arguments: [String] = []

    /// The folder after `--assembly`, standardized.
    var assemblyPath: String? {
        arguments.firstIndex(of: "--assembly").map { URL(fileURLWithPath: arguments[$0 + 1]).standardizedFileURL.path }
    }
}

extension AssemblyContigMaterializationActionTests {
    private func recordingAction() -> (action: AssemblyContigMaterializationAction, box: RecordedArgumentsBox) {
        let box = RecordedArgumentsBox()
        let action = AssemblyContigMaterializationAction()
        action.pasteboard = RecordingPasteboard()
        action.runner = { arguments in
            box.arguments = arguments
            return .init(stdout: ">k141_0 len=64\nACGT\n", stderr: "", status: 0)
        }
        return (action, box)
    }

    func testBlastRequestOfACloneAsksForTheClonesFolder() async throws {
        let fixture = try AssemblyCloneFixture(naming: .other)
        defer { fixture.remove() }
        let loaded = try AssemblyResult.load(from: fixture.clone)
        let (action, box) = recordingAction()

        _ = try await action.buildBlastRequest(result: loaded, selectedContigs: ["k141_0"])

        XCTAssertEqual(box.assemblyPath, fixture.clone.standardizedFileURL.path, "the CLI reads the folder the result is in")
    }

    func testCopyFASTAOfACloneAsksForTheClonesFolder() async throws {
        let fixture = try AssemblyCloneFixture(naming: .other)
        defer { fixture.remove() }
        let loaded = try AssemblyResult.load(from: fixture.clone)
        let (action, box) = recordingAction()

        try await action.copyFASTA(result: loaded, selectedContigs: ["k141_0"])

        XCTAssertEqual(box.assemblyPath, fixture.clone.standardizedFileURL.path, "the CLI reads the folder the result is in")
    }

    func testBlastRequestOfAMovedResultAsksForItsOwnFolder() async throws {
        let fixture = try AssemblyCloneFixture(naming: .missing)
        defer { fixture.remove() }
        let loaded = try AssemblyResult.load(from: fixture.clone)
        let (action, box) = recordingAction()

        _ = try await action.buildBlastRequest(result: loaded, selectedContigs: ["k141_0"])

        XCTAssertEqual(box.assemblyPath, fixture.clone.standardizedFileURL.path, "the JSON names a folder that is gone")
    }
}

extension AssemblyResultViewControllerTests {
    @MainActor
    func testBlastContigFailureShowsWordsAndSendsNothing() async throws {
        struct FakeCLIError: LocalizedError {
            var errorDescription: String? { "contig not found in assembly output" }
        }
        _ = NSApplication.shared
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult(), materializationRunner: { _ in throw FakeCLIError() })
        let shown = expectation(description: "the failure words are shown")
        var failure: FailureReport?
        var sent = false
        vc.failurePresenter = { report in
            failure = report
            shown.fulfill()
        }
        vc.onBlastVerification = { _ in sent = true }

        try await vc.testSelectContigs(named: ["contig_7"])
        vc.testTriggerBlast()
        await fulfillment(of: [shown], timeout: 5)

        XCTAssertFalse(sent, "nothing is sent when the contigs cannot be read")
        let report = try XCTUnwrap(failure, "a failed read shows words")
        XCTAssertTrue(report.body.contains("nothing was sent to NCBI"), report.body)
        XCTAssertTrue(report.details?.contains("contig not found in assembly output") ?? false, "the cause stays in the details")
    }

    @MainActor
    func testSelectedContigReadFailureShowsWordsAndRunsNothing() async throws {
        _ = NSApplication.shared
        let vc = AssemblyResultViewController()
        _ = vc.view
        let result = try makeAssemblyResult()
        try await vc.configureForTesting(result: result)
        let shown = expectation(description: "the failure words are shown")
        var failure: FailureReport?
        var exported = false
        vc.failurePresenter = { report in
            failure = report
            shown.fulfill()
        }
        vc.onExportFASTARequested = { _, _ in exported = true }
        try await vc.testSelectContigs(named: ["contig_7"])
        try FileManager.default.removeItem(at: result.contigsPath)

        vc.testTriggerExport()
        await fulfillment(of: [shown], timeout: 5)

        XCTAssertFalse(exported, "nothing is exported when a selected contig cannot be read")
        let report = try XCTUnwrap(failure, "a failed read shows words")
        // A contigs file that is gone is a contigs file that changed after the result opened (BIO-ASSEMBLY-REPLACED, Fix A),
        // so the words say that and no longer "could not read". Nothing is exported either way.
        XCTAssertTrue(report.body.contains("changed on disk"), report.body)
    }
}

extension AssemblySavedBlastRestoreTests {
    @MainActor
    private func makeCloneViewer(in project: SavedBlastSearchProject) async throws -> AssemblyResultViewController {
        _ = NSApplication.shared
        let fixture = try AssemblyCloneFixture(naming: .other, in: project.root)
        let viewer = AssemblyResultViewController()
        _ = viewer.view
        try await viewer.configureForTesting(result: AssemblyResult.load(from: fixture.clone))
        return viewer
    }

    /// The query copy a BLAST of `name` leaves beside its record, read from the contigs file the viewer opened, since the saved
    /// search comes back only when its query holds the bases of the selected contigs (ruling BIO-ASSEMBLY-REPLACED, Fix E).
    @MainActor
    private func contigQuery(_ name: String, of viewer: AssemblyResultViewController) throws -> [(id: String, sequence: String)] {
        let contigs = try XCTUnwrap(viewer.currentResult?.contigsPath)
        let text = try String(contentsOf: contigs, encoding: .utf8)
        return BlastSavedSearchRow.sequences(ofFASTA: text).filter { $0.id == name }.map { (id: $0.id, sequence: $0.sequence) }
    }

    @MainActor
    func testACloneRestoresTheSearchInItsOwnFolder() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let viewer = try await makeCloneViewer(in: project)
        let record = try project.saveRecord(
            rid: "RID-CLONE", sourceResult: "Clone", sample: nil, taxId: nil, contig: "k141_0", heldIn: "Clone",
            querySequences: try contigQuery("k141_0", of: viewer)
        )

        try await viewer.testSelectContigs(named: ["k141_0"])
        await viewer.savedBlastRestorer.restoreTask?.value

        let pane = try XCTUnwrap(viewer.testBlastDrawerContainer?.blastResultsTab, "the clone's own search comes back")
        XCTAssertEqual(pane.currentResult?.rid, "RID-CLONE")
        XCTAssertEqual(pane.currentRecordURL?.standardizedFileURL.path, record.standardizedFileURL.path, "the export reads this file")
    }

    @MainActor
    func testACloneDoesNotShowTheSearchInTheFolderItsJSONNames() async throws {
        let project = try SavedBlastSearchProject()
        defer { project.remove() }
        let viewer = try await makeCloneViewer(in: project)
        try project.saveRecord(
            rid: "RID-OTHER", sourceResult: "Other", sample: nil, taxId: nil, contig: "k141_0", heldIn: "Other",
            querySequences: try contigQuery("k141_0", of: viewer)
        )

        try await viewer.testSelectContigs(named: ["k141_0"])
        await viewer.savedBlastRestorer.restoreTask?.value

        XCTAssertNil(viewer.testBlastDrawerContainer, "a search held only in the other folder is not this result's")
    }
}

/// Two assembly result folders, `Other` and `Clone`, each with its `assembly-result.json` and `contigs.fasta`. `k141_0` differs
/// in 20 bases, so a read of the wrong folder shows. `Clone`'s JSON names the folder it was copied from, `Other`, or a folder
/// that is gone, as a result moved on its own. `Other` sits in a second project when `separateProjects` is set.
struct AssemblyCloneFixture {
    enum Naming { case other, missing }

    let root: URL
    let other: URL
    let clone: URL

    init(naming: Naming, in parent: URL? = nil, separateProjects: Bool = false) throws {
        root = parent ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-clone-\(UUID().uuidString)", isDirectory: true)
        other = root.appendingPathComponent(separateProjects ? "OtherProject.lungfish" : "Project.lungfish", isDirectory: true)
            .appendingPathComponent("Analyses/Other", isDirectory: true)
        clone = root.appendingPathComponent(separateProjects ? "CloneProject.lungfish" : "Project.lungfish", isDirectory: true)
            .appendingPathComponent("Analyses/Clone", isDirectory: true)
        let gone = root.appendingPathComponent("Moved-away.lungfish/Analyses/megahit-original", isDirectory: true)
        try Self.write(into: other, recordedAs: other, flipped: true)
        try Self.write(into: clone, recordedAs: naming == .other ? other : gone, flipped: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The first contig as `Clone` holds it, or as `Other` holds it with its first 20 bases changed.
    static func record0(flipped: Bool) -> String {
        let bases = String(repeating: "ACGTTGCA", count: 8)
        let swapped: [Character: Character] = ["A": "C", "C": "A", "G": "T", "T": "G"]
        let sequence = flipped ? String(bases.prefix(20).map { swapped[$0] ?? $0 }) + String(bases.dropFirst(20)) : bases
        return ">k141_0 len=64\n\(sequence)\n"
    }

    private static func write(into folder: URL, recordedAs recorded: URL, flipped: Bool) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let contigsURL = folder.appendingPathComponent("contigs.fasta")
        try (record0(flipped: flipped) + ">k141_1 len=24\n\(String(repeating: "GGATCC", count: 4))\n")
            .write(to: contigsURL, atomically: true, encoding: .utf8)
        let result = AssemblyResult(
            tool: .megahit, readType: .illuminaShortReads, contigsPath: contigsURL, graphPath: nil, logPath: nil,
            assemblerVersion: "1.2.9", commandLine: "megahit -o \(recorded.path)", outputDirectory: recorded,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL), wallTimeSeconds: 1
        )
        try result.save(to: folder)
    }
}
