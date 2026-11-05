// KrakenBlastPaneSampleWordsTests.swift - The Kraken 2 BLAST pane names the sample of a search that runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTWORDS, W-21. While one sample's Verify with BLAST runs and a person picks the same taxon under another sample, the
// pane shows the running search. The words must say whose search it is. No network and no process.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKit
@testable import LungfishTaxonomyUI

@MainActor
final class KrakenBlastPaneSampleWordsTests: XCTestCase {
    private let sample = "SRR12486983"

    private func makeController() throws -> (TaxonomyViewController, TaxonNode) {
        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 1000, fractionClade: 1.0, fractionDirect: 0.0, parentTaxId: nil
        )
        let viruses = TaxonNode(
            taxId: 10239, name: "Viruses", rank: .domain, depth: 1,
            readsDirect: 1000, readsClade: 1000, fractionClade: 1.0, fractionDirect: 1.0, parentTaxId: 1
        )
        viruses.parent = root
        root.children = [viruses]
        let tree = TaxonTree(root: root, unclassifiedNode: nil, totalReads: 1000)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kraken-blast-words-\(UUID().uuidString)")
        let config = ClassificationConfig(
            inputFiles: [folder.appendingPathComponent("reads.fastq")], isPairedEnd: false, databaseName: "test-db",
            databasePath: folder.appendingPathComponent("db"), outputDirectory: folder
        )
        let result = ClassificationResult(
            config: config, tree: tree, reportURL: folder.appendingPathComponent("classification.kreport"),
            outputURL: folder.appendingPathComponent("classification.kraken"), brackenURL: nil, runtime: 1, toolVersion: "2.1.3",
            provenanceId: nil
        )
        let controller = TaxonomyViewController()
        isolateLayouts(controller)
        _ = controller.view
        controller.configure(result: result)
        return (controller, viruses)
    }

    /// The words a person reads on `tab`, from the labels that show.
    private func visibleWords(in tab: BlastResultsDrawerTab?) -> String {
        func fields(_ view: NSView) -> [NSTextField] {
            view.subviews.filter { !$0.isHidden }.flatMap { sub -> [NSTextField] in
                (sub as? NSTextField).map { [$0] + fields(sub) } ?? fields(sub)
            }
        }
        guard let tab else { return "" }
        return fields(tab).map(\.stringValue).joined(separator: " | ")
    }

    func testTheProgressPaneNamesTheSampleOfTheRunningSearch() throws {
        let (controller, viruses) = try makeController()
        let run = controller.beginBlastVerification(for: viruses)
        controller.lastBlastSampleId = sample

        controller.showBlastLoading(phase: .submitting, requestId: nil, runID: run)

        guard case .loading? = controller.testBlastResultsTab?.displayState else {
            return XCTFail("the pane is not on the run's progress: \(visibleWords(in: controller.testBlastResultsTab))")
        }
        XCTAssertTrue(visibleWords(in: controller.testBlastResultsTab).contains(sample), "the progress pane names no sample: \(visibleWords(in: controller.testBlastResultsTab))")
    }
}
