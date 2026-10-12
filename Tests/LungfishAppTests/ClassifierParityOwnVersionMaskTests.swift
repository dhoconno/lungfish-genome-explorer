// ClassifierParityOwnVersionMaskTests.swift - LGE's own version on the steps of the classifier parity cases
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Ruling R1 of Phase 2.8. Side A runs the GUI path in the test process, so the steps LGE performs
// itself carry the XCTest host's version, and side C's carry the version of the `lungfish-cli` it
// ran. The A-against-C comparison leaves a step's toolVersion out only when each side holds its
// own LGE version there, in the same shape. These cases hold the rule on hand-built facts, so they
// run without tools.

import Foundation
import XCTest
import LungfishTestSupport

@MainActor
final class ClassifierParityOwnVersionMaskTests: XCTestCase {
    typealias Value = ProvenanceCompatFacts.Value

    private let sideA = ClassifierParityComparison.sideALGEVersions
    private let sideC = ClassifierParityComparison.sideCLGEVersions

    func testEachSidesOwnLGEVersionInOneShapeIsLeftOutOfAAgainstC() throws {
        try XCTSkipIf(sideA == sideC, "this process stamps the CLI's own version")
        for array in ClassifierParityComparison.stepArrays {
            for (versionA, versionC) in zip(sideA, sideC) {
                XCTAssertEqual(differences(steps(versionA, in: array), steps(versionC, in: array)), [], "\(array) \(versionA) \(versionC)")
            }
        }
    }

    func testAThirdPartyVersionAnotherLGEVersionOrAnotherShapeStillShows() {
        let pairs = [
            ("2.1.3", sideC[0]),
            (sideA[0], "2.1.3"),
            (sideA[0], "Lungfish 2026.9.1 (dev)"),
            ("Lungfish 2026.9.1 (25228)", sideC[0]),
            (sideA[0], sideC[1]),
            (sideA[1], sideC[0]),
        ]
        for (versionA, versionC) in pairs where versionA != versionC {
            XCTAssertEqual(
                differences(steps(versionA, in: "steps"), steps(versionC, in: "steps")),
                ["steps[kraken2#1].toolVersion"],
                "\(versionA) and \(versionC)"
            )
        }
    }

    func testEveryOtherPairComparesTheVersionAsItIs() throws {
        try XCTSkipIf(sideA[0] == sideC[0], "this process stamps the CLI's own version")
        let pairs: [(ClassifierParitySide, ClassifierParitySide)] = [(.a, .b), (.c, .cPrime), (.cPrime, .c), (.c, .a)]
        for (reference, candidate) in pairs {
            XCTAssertEqual(
                differences(steps(sideA[0], in: "steps"), steps(sideC[0], in: "steps"), reference, candidate),
                ["steps[kraken2#1].toolVersion"],
                "\(reference) against \(candidate)"
            )
        }
    }

    func testTheRecordsOwnVersionIsNoStepAndStillShows() throws {
        try XCTSkipIf(sideA[1] == sideC[1], "this process stamps the CLI's own version")
        let found = differences(
            .object(["toolVersion": .string(sideA[1])]),
            .object(["toolVersion": .string(sideC[1])])
        )
        XCTAssertEqual(found, ["toolVersion"])
    }

    func testAStepWithoutAVersionOnOneSideStillShows() {
        let bare: Value = .object(["steps": .array([.object(["toolName": .string("kraken2")])])])
        XCTAssertEqual(differences(steps(sideA[0], in: "steps"), bare), ["steps[kraken2#1].toolVersion"])
    }

    // MARK: - Helpers

    /// A record with one kraken2 step in `array` that names `version`.
    private func steps(_ version: String, in array: String) -> Value {
        .object([array: .array([.object(["toolName": .string("kraken2"), "toolVersion": .string(version)])])])
    }

    /// The paths of the facts of `reference` that `candidate` lacks or holds with another value.
    private func differences(
        _ reference: Value,
        _ candidate: Value,
        _ referenceSide: ClassifierParitySide = .a,
        _ candidateSide: ClassifierParitySide = .c
    ) -> [String] {
        var found: [(path: String, detail: String)] = []
        ClassifierParityComparison.collectMissing(
            reference,
            candidate,
            path: "",
            into: &found,
            context: ClassifierParityComparison.FactContext(reference: run(referenceSide), candidate: run(candidateSide))
        )
        return found.map(\.path)
    }

    private func run(_ side: ClassifierParitySide) -> ClassifierParitySideRun {
        ClassifierParitySideRun(
            side: side,
            root: URL(fileURLWithPath: "/nonexistent-parity-root/\(side.folderName)", isDirectory: true),
            analysisPath: nil,
            recordedCommand: nil,
            replayedCommands: [],
            terminal: .notRun("hand-built facts"),
            row: nil
        )
    }
}
