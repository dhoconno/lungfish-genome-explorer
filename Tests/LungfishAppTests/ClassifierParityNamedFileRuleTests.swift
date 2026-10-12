// ClassifierParityNamedFileRuleTests.swift - The named-file rule of the classifier parity cases
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Panel decision P1 of Phase 2.8 (docs/plans/2026-10-11-phase-2-8.md). A record keeps its step
// facts as they were, and a file it names that is gone or holds another digest is accepted
// only when the result recorded why. These cases hold the rule on hand-built facts, so they
// run without tools.

import XCTest
import LungfishTestSupport

@MainActor
final class ClassifierParityNamedFileRuleTests: XCTestCase {
    typealias Value = ProvenanceCompatFacts.Value

    private let result = "Project.lungfish/Analyses/kraken2-batch-1"
    private let kraken = "Analyses/kraken2-batch-1/s1/classification.kraken"

    func testARemovedFileThatNoRemovalStepNamesIsFound() throws {
        let found = try differences([
            ("\(result)/s1/.lungfish-provenance.json", record(steps: [
                step(outputs: [file(kraken, "d0")]),
                step(inputs: [file(kraken, "d0")]),
            ])),
        ], files: [:])

        XCTAssertEqual(found.map(\.id), [
            "fact: record \(result)/s1/.lungfish-provenance.json names <project>/\(kraken) that does not exist",
        ])
    }

    func testARemovalStepOfTheSameRecordOrResultAccountsForTheFile() throws {
        let removal = step(inputs: [file(kraken, nil)], operation: "remove")
        let sample = record(steps: [step(outputs: [file(kraken, "d0")]), step(inputs: [file(kraken, "d0")])])

        XCTAssertEqual(try differences([
            ("\(result)/s1/.lungfish-provenance.json", record(steps: [
                step(outputs: [file(kraken, "d0")]), step(inputs: [file(kraken, "d0")]), removal,
            ])),
        ], files: [:]), [])
        XCTAssertEqual(try differences([
            ("\(result)/s1/.lungfish-provenance.json", sample),
            ("\(result)/kraken2.sqlite.lungfish-provenance.json", record(steps: [removal])),
        ], files: [:]), [])
    }

    func testARemovalStepOfAnotherResultDoesNotAccountForTheFile() throws {
        let found = try differences([
            ("\(result)/s1/.lungfish-provenance.json", record(steps: [step(outputs: [file(kraken, "d0")])])),
            ("Project.lungfish/Analyses/kraken2-2/.lungfish-provenance.json", record(steps: [
                step(inputs: [file(kraken, nil)], operation: "remove"),
            ])),
        ], files: [:])

        XCTAssertEqual(found.map(\.id), [
            "fact: record \(result)/s1/.lungfish-provenance.json names <project>/\(kraken) that does not exist",
        ])
    }

    func testAFileRewrittenInPlaceNeedsARemovalStepForItsEarlierDigest() throws {
        let bam = "Analyses/kraken2-batch-1/s1/bams/s1.bam"
        let steps = [
            step(outputs: [file(bam, "d0")]),
            step(inputs: [file(bam, "d0")]),
            step(outputs: [file(bam, "d2")]),
        ]
        let path = "\(result)/s1/.lungfish-provenance.json"

        let found = try differences([(path, record(steps: steps, files: [file(bam, "d0")]))], files: [bam: "d2"])
        XCTAssertEqual(found.map(\.id), ["fact: record \(path) names <project>/\(bam) with another digest"])
        XCTAssertEqual(try differences([
            (path, record(steps: steps + [step(inputs: [file(bam, "d0")], operation: "remove")])),
        ], files: [bam: "d2"]), [])
    }

    func testARemovalStepDoesNotAccountForTheRunLevel() throws {
        let bam = "Analyses/kraken2-batch-1/s1/bams/s1.bam"
        let path = "\(result)/s1/.lungfish-provenance.json"
        let replaced = try differences([
            (path, record(steps: [step(outputs: [file(bam, "d0")]), step(inputs: [file(bam, "d0")], operation: "remove")],
                          files: [file(bam, "d0")])),
        ], files: [bam: "d2"])
        XCTAssertEqual(replaced.map(\.id), ["fact: record \(path) names <project>/\(bam) with another digest"])
        let removed = try differences([
            (path, record(steps: [step(outputs: [file(kraken, "d0")]), step(inputs: [file(kraken, "d0")], operation: "remove")],
                          files: [file(kraken, "d0")])),
        ], files: [:])
        XCTAssertEqual(removed.map(\.id), ["fact: record \(path) names <project>/\(kraken) that does not exist"])
    }

    func testARemovalStepAccountsOnlyForStepsBeforeItInItsRecord() throws {
        let path = "\(result)/s1/.lungfish-provenance.json"
        let found = try differences([
            (path, record(steps: [
                step(outputs: [file(kraken, "d0")]),
                step(inputs: [file(kraken, "d0")], operation: "remove"),
                step(inputs: [file(kraken, "d0")]),
            ])),
        ], files: [:])

        XCTAssertEqual(found.map(\.id), ["fact: record \(path) names <project>/\(kraken) that does not exist"])
    }

    func testARemovalStepAccountsForAChangedFileOnlyAtTheDigestItNames() throws {
        let bam = "Analyses/kraken2-batch-1/s1/bams/s1.bam"
        let path = "\(result)/s1/.lungfish-provenance.json"
        let found = try differences([
            (path, record(steps: [step(outputs: [file(bam, "d1")]), step(inputs: [file(bam, "d0")], operation: "remove")])),
        ], files: [bam: "d2"])

        XCTAssertEqual(found.map(\.id), ["fact: record \(path) names <project>/\(bam) with another digest"])
    }

    func testAMoveIsNotARemovalStep() throws {
        let source = "Analyses/kraken2-batch-1/s1/s1_temp/s1.bam"
        let found = try differences([
            ("\(result)/.lungfish-provenance.json", record(steps: [
                step(inputs: [file(source, "d0")], outputs: [file("Analyses/kraken2-batch-1/s1/bams/s1.bam", "d0")], operation: "move"),
            ])),
        ], files: ["Analyses/kraken2-batch-1/s1/bams/s1.bam": "d0"])

        XCTAssertEqual(found.map(\.id), [
            "fact: record \(result)/.lungfish-provenance.json names <project>/\(source) that does not exist",
        ])
    }

    func testNamingsKeepTheirStepAndTheRunLevelComesLast() {
        let namings = ClassifierCLIGUIParityReplayTests.orderedNamings(in: record(
            steps: [step(outputs: [file(kraken, "d0")]), step(inputs: [file(kraken, "d0")])],
            files: [file(kraken, "d0")]
        ))

        XCTAssertEqual(namings.map(\.step), [0, 1, 2])
        XCTAssertEqual(namings.map(\.isInput), [false, true, false])
    }

    func testTheResultOfARecordIsItsFolderUnderAnalyses() {
        XCTAssertEqual(ClassifierCLIGUIParityReplayTests.resultFolder(of: "\(result)/s1/bams/s1.bam.lungfish-provenance.json"), result)
        XCTAssertEqual(ClassifierCLIGUIParityReplayTests.resultFolder(of: "\(result)/.lungfish-provenance.json"), result)
        XCTAssertEqual(
            ClassifierCLIGUIParityReplayTests.resultFolder(of: "Project.lungfish/Imports/a.lungfishfastq/.lungfish-provenance.json"),
            "Project.lungfish/Imports/a.lungfishfastq"
        )
    }

    // MARK: - Helpers

    private func differences(_ records: [(String, Value)], files: [String: String]) throws -> [ClassifierParityDifference] {
        try ClassifierCLIGUIParityReplayTests.namedFileDifferences(
            side: "C", records: records.map { (path: $0.0, facts: $0.1) }
        ) { path in
            files[path].map { digest in .file { digest } }
        }
    }

    private func file(_ path: String, _ sha256: String?) -> Value {
        var members: [String: Value] = ["path": .string("<project>/\(path)"), "role": .string("input")]
        if let sha256 { members["sha256"] = .string(sha256) }
        return .object(members)
    }

    private func step(inputs: [Value] = [], outputs: [Value] = [], operation: String? = nil) -> Value {
        var members: [String: Value] = ["inputs": .array(inputs), "outputs": .array(outputs)]
        if let operation {
            members["resolvedOptions"] = .object(["operation": .object(["type": .string("string"), "value": .string(operation)])])
        }
        return .object(members)
    }

    private func record(steps: [Value], files: [Value] = []) -> Value {
        .object(["steps": .array(steps), "files": .array(files)])
    }
}
