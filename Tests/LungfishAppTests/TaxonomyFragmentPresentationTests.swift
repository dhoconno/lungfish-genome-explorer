// TaxonomyFragmentPresentationTests.swift - The Kraken2 summary bar counts fragments and labels older per-read results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// A Kraken2 run that held read pairs counts fragments, and the bar says how
/// many came from pairs and how many from merged or single reads (decisions 1
/// and 2). An older result made from paired inputs without the read-pairing
/// contract is labelled as counted per read (manager ruling 3).
@MainActor
final class TaxonomyFragmentPresentationTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxonomy-fragments")
        fixtures = try ReadSetFixtures(in: root)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testANewPairedResultCountsFragments() throws {
        let composition = ClassificationFragmentComposition(pairedFragments: 23, mergedReads: 77, orphanReads: 0, singleEndReads: 0)
        let result = try makeResult(isPairedEnd: true, classified: 90, unclassified: 10, composition: composition)
        let presentation = TaxonomyFragmentPresentation(result: result)
        XCTAssertTrue(presentation.countsFragments)
        XCTAssertEqual(presentation.fragmentLine, "100 fragments, 23 from read pairs and 77 from merged or single reads")
        XCTAssertFalse(presentation.mayHaveCountedPerRead)

        let bar = TaxonomySummaryBar()
        bar.update(result: result)
        XCTAssertEqual(bar.cards.first?.label, "Fragments")
        XCTAssertEqual(bar.cards.last?.value, "100 fragments, 23 from read pairs and 77 from merged or single reads")
    }

    func testTheFragmentLineIsLeftOutWhenTheReportDisagrees() throws {
        let composition = ClassificationFragmentComposition(pairedFragments: 23, mergedReads: 77, orphanReads: 0, singleEndReads: 0)
        let result = try makeResult(isPairedEnd: true, classified: 90, unclassified: 9, composition: composition)
        XCTAssertNil(TaxonomyFragmentPresentation(result: result).fragmentLine)
    }

    func testAnOlderResultFromAPairedDerivativeIsCountedPerRead() async throws {
        let result = try makeResult(isPairedEnd: false, originalInputs: [fixtures.pairedDerivative])
        let presentation = TaxonomyFragmentPresentation(result: result)
        XCTAssertTrue(presentation.mayHaveCountedPerRead)
        let holdsPairs = await KrakenReadSetPlanner.originalInputsHoldPairs(presentation.originalInputs)
        XCTAssertTrue(presentation.showsCountedPerRead(inputsHoldPairs: holdsPairs))

        let bar = TaxonomySummaryBar()
        bar.update(result: result)
        XCTAssertEqual(bar.cards.first?.label, "Total Reads")
        await waitUntil { bar.countedPerRead }
        XCTAssertEqual(bar.cards.last?.value, TaxonomyFragmentPresentation.countedPerReadLabel)
    }

    func testASingleEndResultIsNotLabelled() async throws {
        let result = try makeResult(isPairedEnd: false, originalInputs: [fixtures.singleRoot])
        let presentation = TaxonomyFragmentPresentation(result: result)
        let holdsPairs = await KrakenReadSetPlanner.originalInputsHoldPairs(presentation.originalInputs)
        XCTAssertEqual(holdsPairs, false)
        XCTAssertFalse(presentation.showsCountedPerRead(inputsHoldPairs: holdsPairs))
    }

    func testANewPairedResultIsNotLabelled() throws {
        let composition = ClassificationFragmentComposition(pairedFragments: 2, mergedReads: 0, orphanReads: 0, singleEndReads: 0)
        let result = try makeResult(isPairedEnd: true, classified: 2, unclassified: 0, composition: composition,
                                    originalInputs: [fixtures.pairedDerivative])
        XCTAssertFalse(TaxonomyFragmentPresentation(result: result).showsCountedPerRead(inputsHoldPairs: true))
    }

    func testAResultWhoseInputsAreGoneIsNotLabelled() async throws {
        let gone = root.appendingPathComponent("Gone.lungfishfastq", isDirectory: true)
        let result = try makeResult(isPairedEnd: false, originalInputs: [gone])
        let presentation = TaxonomyFragmentPresentation(result: result)
        let holdsPairs = await KrakenReadSetPlanner.originalInputsHoldPairs(presentation.originalInputs)
        XCTAssertNil(holdsPairs)
        XCTAssertFalse(presentation.showsCountedPerRead(inputsHoldPairs: holdsPairs))
    }

    func testAnOlderInterleavedResultIsNotLabelled() throws {
        var result = try makeResult(isPairedEnd: false, originalInputs: [fixtures.interleavedRoot])
        var config = result.config
        config.interleavedInput = true
        result = ClassificationResult(config: config, tree: result.tree, reportURL: result.reportURL, outputURL: result.outputURL,
                                      brackenURL: nil, runtime: 0, toolVersion: "2.17.1", provenanceId: nil)
        XCTAssertFalse(TaxonomyFragmentPresentation(result: result).mayHaveCountedPerRead)
    }

    // MARK: - Helpers

    private func makeResult(
        isPairedEnd: Bool,
        classified: Int = 2,
        unclassified: Int = 1,
        composition: ClassificationFragmentComposition? = nil,
        originalInputs: [URL] = []
    ) throws -> ClassificationResult {
        let report = root.appendingPathComponent("report-\(UUID().uuidString).kreport")
        let total = Double(classified + unclassified)
        let kreport = String(format: "%.2f\t%d\t%d\tU\t0\tunclassified\n%.2f\t%d\t0\tR\t1\troot\n%.2f\t%d\t%d\tS\t2697049\t  Severe acute respiratory syndrome coronavirus 2\n",
                             Double(unclassified) / total * 100, unclassified, unclassified,
                             Double(classified) / total * 100, classified,
                             Double(classified) / total * 100, classified, classified)
        try kreport.write(to: report, atomically: true, encoding: .utf8)
        var config = ClassificationConfig(
            inputFiles: [root.appendingPathComponent("reads.fastq")],
            isPairedEnd: isPairedEnd,
            databaseName: "Viral",
            databasePath: root.appendingPathComponent("db"),
            outputDirectory: root
        )
        config.originalInputFiles = originalInputs.isEmpty ? nil : originalInputs
        return ClassificationResult(
            config: config,
            tree: try KreportParser.parse(url: report),
            reportURL: report,
            outputURL: root.appendingPathComponent("classification.kraken"),
            brackenURL: nil,
            runtime: 0,
            toolVersion: "2.17.1",
            provenanceId: nil,
            fragmentComposition: composition,
            readPairingContract: composition == nil ? nil : ClassificationResult.currentReadPairingContract
        )
    }
}
