// TwelveSLoosePairOutOfStepTests.swift - 12S matching refuses two loose read files that are out of step by name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
@testable import LungfishWorkflow
@testable import LungfishWorkflowTwelveS
import XCTest
import LungfishTestSupport

/// FIX-ROUTES-7 item 9 (BIO-ROUTES-5, 12S separate mates, S1). Two read files whose names carry no mate number were paired
/// by position, with a warning that only a progress line showed. A pair of two loose files is now refused with the words of
/// the `.notMates` case, and the warning of a pair inside a `.lungfishfastq` bundle reaches the result's manifest.
///
/// Four-record FASTQ files, R1 named `fragA` to `fragD`. The swapped R2 holds records 2 and 3 in each other's place, so the
/// pair at record 2 is `fragB` against `fragC`, and the first and last pairs name one fragment each.
final class TwelveSLoosePairOutOfStepTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSLoosePairOutOfStepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let inStep = ["fragA", "fragB", "fragC", "fragD"]
    private static let swapped = ["fragA", "fragC", "fragB", "fragD"]
    private static let r1Sequences = ["CCACCTTGACAA", "CCACCTTGACAA", "CCACCTTGACAA", "CCAAAAAAAACC"]
    private static let r2Sequences = ["AAGTCAAGGTCC", "AAAGGGTCCCCC", "CCTTTTTTTTAA", "GGTTTTTTTTGG"]

    // MARK: - Pins

    /// Pin 1. A loose pair with records 2 and 3 swapped stops at record 2, after one fragment was read.
    func testALoosePairWithRecordsTwoAndThreeSwappedIsRefusedAtRecordTwo() async throws {
        let (r1, r2) = try writePair(in: root.appendingPathComponent("loose"), r2Names: Self.swapped)
        let result = await visit(plan(r1: r1, r2: r2))
        XCTAssertEqual(
            result.message,
            "Record 2 of S_R1.fastq is fragB and of S_R2.fastq is fragC, so the two files do not hold the same fragments "
                + "in the same order."
        )
        XCTAssertEqual(result.visited, 1)
    }

    /// Pin 2, a guard. A loose pair in step runs and carries no warning.
    func testALoosePairInStepRunsWithNoWarning() async throws {
        let (r1, r2) = try writePair(in: root.appendingPathComponent("loose"), r2Names: Self.inStep)
        let result = await visit(plan(r1: r1, r2: r2))
        XCTAssertEqual(result.message, nil)
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.visited, 4)
    }

    /// Pin 3. The same swapped pair inside `S.lungfishfastq` keeps the legacy pairing by position and runs, and the
    /// warning reaches the manifest the Inspector shows.
    func testTheSameSwappedPairInABundleRunsAndItsWarningReachesTheManifest() async throws {
        let bundle = root.appendingPathComponent("S.lungfishfastq", isDirectory: true)
        _ = try writePair(in: bundle, r2Names: Self.swapped)
        try saveDerivedManifest(in: bundle)
        let loaded = try await run([bundle])
        let manifest = try XCTUnwrap(loaded.sampleMetadataManifest)
        XCTAssertEqual(
            manifest.warnings.last,
            "Warning: 2 of the 4 record pairs of S_R1.fastq and S_R2.fastq carry no mate number in their names, the first "
                + "being 'fragB' and 'fragC', so they were paired by position."
        )
    }

    // MARK: - Fixtures

    private static func fastq(_ names: [String], _ sequences: [String]) -> String {
        zip(names, sequences).map { "@\($0)\n\($1)\n+\n\(String(repeating: "I", count: $1.count))\n" }.joined()
    }

    /// Writes `S_R1.fastq` (`fragA` to `fragD`) and `S_R2.fastq` (`r2Names`) into `folder`.
    private func writePair(in folder: URL, r2Names: [String]) throws -> (r1: URL, r2: URL) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let r1 = folder.appendingPathComponent("S_R1.fastq")
        let r2 = folder.appendingPathComponent("S_R2.fastq")
        try Self.fastq(Self.inStep, Self.r1Sequences).write(to: r1, atomically: true, encoding: .utf8)
        try Self.fastq(r2Names, Self.r2Sequences).write(to: r2, atomically: true, encoding: .utf8)
        return (r1, r2)
    }

    /// The plan of two files that a caller names as R1 and R2.
    private func plan(r1: URL, r2: URL) -> ReadSetPlan {
        let run = ReadSetRun(matePairs: [ReadSetMatePair(files: .separate(r1: r1, r2: r2))])
        return ReadSetPlan(
            inputURL: r1,
            capability: .bothInOneRunAsSeparateFiles,
            sourceLayout: .pairedFiles,
            layoutReason: "Two files named as R1 and R2.",
            sequencingPlatform: nil,
            wasMaterialized: false,
            sampleHoldsPairsAndSingleReads: false,
            runs: [run],
            steps: [],
            singleReadReason: nil,
            composition: ReadSetComposition(runs: [run])
        )
    }

    /// Reads every fragment of `plan`, and reports how many were visited, what the reading warned of or why it stopped.
    private func visit(_ plan: ReadSetPlan) async -> (visited: Int, warnings: [String]?, message: String?) {
        var visited = 0
        do {
            let warnings = try await TwelveSAmpliconMatchingWorkflow.readFragments(of: plan) { _ in visited += 1 }
            return (visited, warnings, nil)
        } catch TwelveSAmpliconMatchingError.mateMismatch(let message) {
            return (visited, nil, message)
        } catch {
            return (visited, nil, "unexpected \(error)")
        }
    }

    /// A `fullPaired` derivative, the pair as R1 and R2 files of the bundle.
    private func saveDerivedManifest(in bundle: URL) throws {
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "S",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "reads.fastq",
                payload: .fullPaired(r1Filename: "S_R1.fastq", r2Filename: "S_R2.fastq"),
                lineage: [FASTQDerivativeOperation(kind: .interleaveReformat)],
                operation: FASTQDerivativeOperation(kind: .interleaveReformat),
                cachedStatistics: .countsOnlyFixture(readCount: 4, baseCount: 48),
                pairingMode: .pairedEnd,
                readClassification: nil,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
    }

    private func run(_ inputs: [URL]) async throws -> TwelveSAmpliconResultBundleData {
        let referenceURL = root.appendingPathComponent("reference.fa")
        try """
        >human (Homo sapiens)|locus=12S|len=8
        ACCTTGAC
        >dog (Canis lupus familiaris)|locus=12S|len=8
        GGGACCCT

        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        let result = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer()).run(
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: inputs,
                referenceFASTA: referenceURL,
                outputDirectory: root.appendingPathComponent("outputs", isDirectory: true),
                outputName: "loose-pair-12s",
                minimumSoftClipBases: 2,
                maximumIndelBases: 2,
                matchingMode: .illuminaExact,
                threads: 2,
                runChimeraReview: false
            ),
            progressHandler: nil
        )
        return try TwelveSAmpliconResultBundle.loadResult(from: result.bundleURL)
    }
}
