// TaxTriageParityUUIDNumberingTests.swift - The TaxTriage compare numbers the UUIDs of each file alone
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q31, panel decision G3. The contract's `uuids` mask numbers the UUIDs of a tree in
// the order it meets them, and a UUID that only a payload holds reads the tree's count plus its
// place in that payload. One UUID more in a side's names or records moved the number of every such
// UUID, which four declared differences of 2.9 carried until this lane. TaxTriageParityComparison
// .folderDifferences now numbers the UUIDs of each file alone, and these checks run it on two small
// trees. The contract and the classifier parity keep the per-tree numbering.

import Foundation
import XCTest
import LungfishTestSupport

final class TaxTriageParityUUIDNumberingTests: XCTestCase {
    /// The checks' n-th UUID, spelled as a run draws one.
    private func uuid(_ n: Int) -> String {
        String(format: "%08lX-0000-4000-8000-%012lX", n, n)
    }

    /// A provenance record that names the UUIDs numbered `ids`. The record comparison covers a
    /// record, so the folder comparison drops its own difference and only the files after it show.
    private func record(_ ids: [Int]) -> String {
        "{\n  \"ids\" : [" + ids.map { "\"\(uuid($0))\"" }.joined(separator: ", ") + "]\n}\n"
    }

    /// The files of one side below the project, `analysis` named below the analysis folder and
    /// `imports` below `Imports/`.
    private func tree(analysis: [String: String], imports: [String: String] = [:]) -> [String: String] {
        var files: [String: String] = [:]
        for (name, text) in analysis { files["Analyses/taxtriage-run/\(name)"] = text }
        for (name, text) in imports { files["Imports/\(name)"] = text }
        return files
    }

    private func sideRun(
        _ side: TaxTriageParitySide, in scratch: URL, files: [String: String]
    ) throws -> TaxTriageParitySideRun {
        let root = scratch.appendingPathComponent(side.folderName, isDirectory: true)
        let project = root.appendingPathComponent(ClassifierParityFixtures.projectName, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: project.appendingPathComponent("Imports", isDirectory: true), withIntermediateDirectories: true)
        for (name, text) in files {
            let url = project.appendingPathComponent(name)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return TaxTriageParitySideRun(
            side: side, root: root, analysisPath: "\(ClassifierParityFixtures.projectName)/Analyses/taxtriage-run",
            recordedCommand: nil, replayedCommands: [], terminal: .exit(0), row: nil, launches: []
        )
    }

    /// What the TaxTriage compare finds between side A holding `a` and side B holding `b`.
    private func differences(a: [String: String], b: [String: String]) throws -> [TaxTriageParityDifference] {
        let scratch = try TestTempDirectory.make(prefix: "taxtriage-uuid-numbering")
        defer { TestTempDirectory.cleanup(scratch) }
        let reference = try sideRun(.a, in: scratch, files: a)
        let candidate = try sideRun(.b, in: scratch, files: b)
        return try TaxTriageParityComparison.folderDifferences(reference, candidate, bundlePaths: [])
    }

    // MARK: - Numbering

    /// Side B's record holds a UUID more than side A's, as the executor's root record does. The
    /// launch scratch that the log and the launch command name reads the same number on both sides.
    func testAnExtraUUIDInAnEarlierFileMovesNoLaterNumber() throws {
        let found = try differences(
            a: tree(analysis: [
                ".lungfish-provenance.json": record([1]),
                "nextflow.log": "launch scratch .tmp/taxtriage-run-\(uuid(10)) created\n",
                "taxtriage-launch-command.sh": "cd .tmp/taxtriage-run-\(uuid(10)) && nextflow run\n",
            ]),
            b: tree(analysis: [
                ".lungfish-provenance.json": record([2, 3]),
                "nextflow.log": "launch scratch .tmp/taxtriage-run-\(uuid(11)) created\n",
                "taxtriage-launch-command.sh": "cd .tmp/taxtriage-run-\(uuid(11)) && nextflow run\n",
            ])
        )
        XCTAssertEqual(found.map(\.id), [], "\(found)")
    }

    /// A manifest is a record, so at the base its UUIDs took the tree's numbers after every earlier
    /// record, and one UUID more in side B's provenance moved them. Records are numbered alone too.
    func testAnExtraUUIDInAnEarlierRecordMovesNoManifestNumber() throws {
        let found = try differences(
            a: tree(analysis: [
                ".lungfish-provenance.json": record([1]),
                "run-manifest.json": "{\n  \"run\" : \"\(uuid(10))\"\n}\n",
            ]),
            b: tree(analysis: [
                ".lungfish-provenance.json": record([2, 3]),
                "run-manifest.json": "{\n  \"run\" : \"\(uuid(11))\"\n}\n",
            ])
        )
        XCTAssertEqual(found.map(\.id), [], "\(found)")
    }

    /// One UUID twice against two UUIDs once is a difference of the file, so the mask hides the
    /// numbering and nothing else.
    func testOneUUIDTwiceAgainstTwoUUIDsOnceStillDiffers() throws {
        let found = try differences(
            a: tree(analysis: ["nextflow.log": "scratch \(uuid(1)) removed \(uuid(1))\n"]),
            b: tree(analysis: ["nextflow.log": "scratch \(uuid(2)) removed \(uuid(3))\n"])
        )
        XCTAssertEqual(found.map(\.id), ["analysis: differs: nextflow.log"])
        let detail = found.first?.detail ?? ""
        XCTAssertTrue(detail.contains("A: scratch <UUID-1> removed <UUID-1>"), detail)
        XCTAssertTrue(detail.contains("B: scratch <UUID-1> removed <UUID-2>"), detail)
    }

    /// Text beside a UUID that differs is still a difference, and both sides number their UUID alike.
    func testTextBesideAUUIDStillDiffers() throws {
        let found = try differences(
            a: tree(analysis: ["nextflow.log": "scratch \(uuid(1)) created\n"]),
            b: tree(analysis: ["nextflow.log": "scratch \(uuid(2)) removed\n"])
        )
        XCTAssertEqual(found.map(\.id), ["analysis: differs: nextflow.log"])
        let detail = found.first?.detail ?? ""
        XCTAssertTrue(detail.contains("A: scratch <UUID-1> created"), detail)
        XCTAssertTrue(detail.contains("B: scratch <UUID-1> removed"), detail)
    }

    /// File names keep the per-tree numbering, so two folders named by UUIDs mask to two names. A
    /// numbering of each name alone would mask both to one and report a collision.
    func testTwoFoldersNamedByUUIDsStillNumberApart() throws {
        let found = try differences(
            a: tree(analysis: [
                "scratch-\(uuid(1))/nextflow.log": "scratch \(uuid(1))\n",
                "scratch-\(uuid(2))/nextflow.log": "scratch \(uuid(2))\n",
            ]),
            b: tree(analysis: [
                "scratch-\(uuid(3))/nextflow.log": "scratch \(uuid(3))\n",
                "scratch-\(uuid(4))/nextflow.log": "scratch \(uuid(4))\n",
            ])
        )
        XCTAssertEqual(found.map(\.id), [], "\(found)")
    }

    /// The inputs are one copy on both sides and compare byte for byte, UUIDs included.
    func testTheInputsStillCompareWithTheirUUIDs() throws {
        let found = try differences(
            a: tree(analysis: [:], imports: ["Sample.lungfishfastq/notes.txt": "sample \(uuid(1))\n"]),
            b: tree(analysis: [:], imports: ["Sample.lungfishfastq/notes.txt": "sample \(uuid(2))\n"])
        )
        XCTAssertEqual(found.map(\.id), ["inputs: differs: Sample.lungfishfastq/notes.txt"], "\(found)")
    }
}
