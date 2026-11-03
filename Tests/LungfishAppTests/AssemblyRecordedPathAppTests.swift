// AssemblyRecordedPathAppTests.swift - The app's routes from an assembly result read the folder it is in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane ASSEMBLY-PATH (BIO-ASSEMBLY-RECORDED-PATH). `assembly-result.json` names the folder the run wrote, and a
// result that was copied or moved is somewhere else. A BLAST search of its contigs is saved in the project that holds the
// result, and the Inspector reads the run record in the result's own folder.

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishApp
@testable import LungfishWorkflow

extension AssemblyViewerIntegrationTests {
    func testAssemblyBlastPlanOfACloneSavesInTheClonesProject() throws {
        let fixture = try AssemblyCloneFixture(naming: .other, separateProjects: true)
        defer { fixture.remove() }
        let loaded = try AssemblyResult.load(from: fixture.clone)

        let plan = try ViewerViewController.assemblyBlastSubmitPlan(
            sourceLabel: "contig k141_0", taxId: nil,
            fastaRecords: [AssemblyCloneFixture.record0(flipped: false)], resultURL: loaded.outputDirectory
        )

        let project = fixture.cloneProject.standardizedFileURL.path + "/"
        XCTAssertTrue(
            plan.request.outputURL.standardizedFileURL.path.hasPrefix(project),
            "the record goes in the project that holds the result, not \(plan.request.outputURL.path)"
        )
        XCTAssertTrue(
            plan.request.queryURL.standardizedFileURL.path.hasPrefix(project),
            "the query is staged in that project, not \(plan.request.queryURL.path)"
        )
    }

    func testInspectorOfAMovedResultReadsItsOwnRecord() throws {
        let fixture = try AssemblyCloneFixture(naming: .missing)
        defer { fixture.remove() }
        let reads = fixture.clone.appendingPathComponent("reads.fastq")
        let trimmed = fixture.clone.appendingPathComponent("trimmed.fastq")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: reads)
        try Data("@r\nACG\n+\n!!!\n".utf8).write(to: trimmed)
        let input = try ProvenanceFileDescriptor.file(url: reads, format: .fastq, role: .input)
        let output = try ProvenanceFileDescriptor.file(url: trimmed, format: .fastq, role: .output)
        let envelope = ProvenanceEnvelope(
            workflowName: "Assembly", workflowVersion: "1", toolName: "lungfish-cli", toolVersion: "0.1",
            argv: ["lungfish-cli", "assemble", reads.path],
            options: ProvenanceOptions(explicit: [:], defaults: [:], resolvedDefaults: [:]),
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [input, output], output: output, outputs: [output], steps: [],
            wallTimeSeconds: 1, exitStatus: 0, stderr: ""
        )
        _ = try ProvenanceWriter(signingProvider: nil).write(envelope, to: fixture.clone)
        let loaded = try AssemblyResult.load(from: fixture.clone)

        let record = try XCTUnwrap(
            ProvenanceRecorder.loadEnvelope(from: loaded.outputDirectory), "the run record in the result's own folder"
        )
        let rows = AssemblyInspectorSourceResolver.resolve(envelope: record, outputDirectory: loaded.outputDirectory, projectURL: nil)
        XCTAssertFalse(rows.isEmpty, "Source Data comes from the result's own record")
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
    var cloneProject: URL { clone.deletingLastPathComponent().deletingLastPathComponent() }

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
