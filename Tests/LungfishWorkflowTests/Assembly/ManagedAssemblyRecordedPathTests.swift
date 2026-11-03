// ManagedAssemblyRecordedPathTests.swift - A loaded assembly result is the folder it was loaded from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane ASSEMBLY-PATH (BIO-ASSEMBLY-RECORDED-PATH). `assembly-result.json` names the folder the run wrote. A result
// that was moved, renamed or copied is no longer there, so `load(from:)` returns the folder it read the file from.

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

extension ManagedAssemblyArtifactTests {
    func testLoadReturnsTheFolderItLoadedFromWhenTheJSONNamesAnother() throws {
        for naming in [AssemblyCloneFixture.Naming.other, .missing] {
            let fixture = try AssemblyCloneFixture(naming: naming)
            defer { fixture.remove() }
            let sidecar = fixture.clone.appendingPathComponent("assembly-result.json")
            let before = try Data(contentsOf: sidecar)

            let loaded = try AssemblyResult.load(from: fixture.clone)

            let folder = fixture.clone.standardizedFileURL.path
            XCTAssertEqual(loaded.outputDirectory.standardizedFileURL.path, folder, "the JSON names \(naming), the result is in \(folder)")
            XCTAssertTrue(
                loaded.contigsPath.standardizedFileURL.path.hasPrefix(loaded.outputDirectory.standardizedFileURL.path + "/"),
                "the contigs are under the output directory"
            )
            XCTAssertEqual(try Data(contentsOf: sidecar), before, "a load does not rewrite the file")
        }
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
        try FASTAIndexBuilder.buildAndWrite(for: contigsURL)
        let result = AssemblyResult(
            tool: .megahit, readType: .illuminaShortReads, contigsPath: contigsURL, graphPath: nil, logPath: nil,
            assemblerVersion: "1.2.9", commandLine: "megahit -o \(recorded.path)", outputDirectory: recorded,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL), wallTimeSeconds: 1
        )
        try result.save(to: folder)
    }
}
