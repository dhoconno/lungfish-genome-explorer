import AppKit
import XCTest
@testable import LungfishKit

@MainActor
final class LungfishHelpContentTests: XCTestCase {
    func testCatalogIDsAreUniqueAndNonEmpty() {
        let items = LungfishHelpContent.allItems

        XCTAssertFalse(items.isEmpty)
        XCTAssertEqual(items.map(\.id).count, Set(items.map(\.id)).count)
        for item in items {
            XCTAssertFalse(item.id.isEmpty)
            XCTAssertFalse(item.summary.isEmpty)
        }
    }

    func testCatalogAvoidsBannedDocumentationLanguage() {
        let banned = [
            "revolutionary",
            "breakthrough",
            "powerful",
            "cutting-edge",
            "AI-powered",
            "game-changing",
            "unleash",
            "leverages",
            "!",
        ]

        for item in LungfishHelpContent.allItems {
            let copy = "\(item.summary) \(item.detail ?? "")"
            for word in banned {
                XCTAssertFalse(copy.localizedCaseInsensitiveContains(word), "\(item.id) contains \(word)")
            }
            XCTAssertFalse(copy.contains("—"), "\(item.id) contains an em dash")
        }
    }

    func testCatalogIncludesFieldLevelScientificWorkflowInventory() {
        let ids = Set(LungfishHelpContent.allItems.map(\.id))
        let expectedIDs: Set<String> = [
            "workflow.fastq.field.qualityThreshold",
            "workflow.fastq.field.windowSize",
            "workflow.fastq.field.adapterSequence",
            "workflow.fastq.field.primerSequence",
            "workflow.fastq.field.kmerSize",
            "workflow.fastq.field.hammingDistance",
            "workflow.fastq.field.minLength",
            "workflow.fastq.field.maxLength",
            "workflow.fastq.field.threads",
            "workflow.fastq.field.seed",
            "workflow.fastq.field.query",
            "workflow.fastq.field.pattern",
            "workflow.fastq.field.regex",
            "workflow.fastq.field.sequenceOrFasta",
            "workflow.fastq.field.errorRate",
            "workflow.fastq.field.demultiplexDistance",
            "workflow.fastq.import.platform",
            "workflow.fastq.import.pairing",
            "workflow.fastq.import.qualityBinning",
            "workflow.fastq.import.compression",
            "workflow.fastq.import.recipe",
            "workflow.fastq.import.barcodeSheet",
            "workflow.fastq.import.demuxFolder",
            "workflow.bam.primerTrim.minReadLength",
            "workflow.bam.primerTrim.minQuality",
            "workflow.bam.variantCalling.ivarConsensusAF",
            "workflow.bam.variantCalling.ivarMergeAF",
            "workflow.bam.variantCalling.ivarBadQuality",
        ]

        XCTAssertTrue(expectedIDs.isSubset(of: ids), "Missing IDs: \(expectedIDs.subtracting(ids).sorted())")
    }

    func testTooltipSummariesStayShortEnoughForHoverUse() {
        for item in LungfishHelpContent.allItems {
            let words = item.summary.split { $0.isWhitespace || $0.isNewline }

            XCTAssertLessThanOrEqual(words.count, 20, "\(item.id) is too long for a tooltip")
        }
    }

    func testProvenanceRelevantItemsSayWhatProvenanceHelpsVerify() {
        for item in LungfishHelpContent.allItems where item.provenanceRelevant {
            let copy = "\(item.summary) \(item.detail ?? "")".lowercased()

            XCTAssertTrue(copy.contains("provenance"), "\(item.id) should mention provenance")
            XCTAssertTrue(
                copy.contains("command")
                    || copy.contains("inputs")
                    || copy.contains("checksums")
                    || copy.contains("runtime"),
                "\(item.id) should mention reproducibility evidence"
            )
        }
    }

    func testClassifierActionBarAppliesScientificHelp() {
        let actionBar = ClassifierActionBar(frame: NSRect(x: 0, y: 0, width: 600, height: 36))

        XCTAssertEqual(
            actionBar.blastButton.toolTip,
            LungfishHelpContent.classifierBlastVerify.summary
        )
        XCTAssertEqual(
            actionBar.exportButton.toolTip,
            LungfishHelpContent.resultExport.summary
        )
        XCTAssertEqual(
            actionBar.extractButton.toolTip,
            LungfishHelpContent.classifierExtractFASTQ.summary
        )
        XCTAssertEqual(
            actionBar.provenanceButton.toolTip,
            LungfishHelpContent.resultProvenance.summary
        )
        XCTAssertEqual(
            actionBar.provenanceButton.accessibilityHelp(),
            LungfishHelpContent.resultProvenance.detail
        )
    }

    func testClassifierActionBarPreservesScientificHelpWhenBlastStateChanges() {
        let actionBar = ClassifierActionBar(frame: NSRect(x: 0, y: 0, width: 600, height: 36))

        actionBar.setBlastEnabled(false, reason: "Select a row to use BLAST Verify")

        XCTAssertEqual(
            actionBar.blastButton.toolTip,
            "Select a row to use BLAST Verify. \(LungfishHelpContent.classifierBlastVerify.summary)"
        )
        XCTAssertTrue(actionBar.blastButton.accessibilityHelp()?.contains("supports review") ?? false)

        actionBar.setBlastEnabled(true)

        XCTAssertEqual(actionBar.blastButton.toolTip, LungfishHelpContent.classifierBlastVerify.summary)
        XCTAssertEqual(actionBar.blastButton.accessibilityHelp(), LungfishHelpContent.classifierBlastVerify.detail)
    }
}
