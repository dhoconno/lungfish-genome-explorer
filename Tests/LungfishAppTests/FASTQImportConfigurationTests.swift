// FASTQImportConfigurationTests.swift - Tests for FASTQ import configuration and pair grouping
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import AppKit
import Testing
@testable import LungfishApp

@Suite("FASTQ Import Configuration")
struct FASTQImportConfigurationTests {

    // MARK: - Pair Grouping

    @Test("Groups R1/R2 paired files with _R1_001/_R2_001 suffix")
    func groupIlluminaPairedFiles() {
        let r1 = URL(fileURLWithPath: "/data/Sample_R1_001.fastq.gz")
        let r2 = URL(fileURLWithPath: "/data/Sample_R2_001.fastq.gz")
        let pairs = groupFASTQByPairs([r1, r2])
        #expect(pairs.count == 1)
        #expect(pairs[0].r1 == r1)
        #expect(pairs[0].r2 == r2)
        #expect(pairs[0].isPaired)
    }

    @Test("Groups R1/R2 paired files with _R1/_R2 suffix")
    func groupSimplePairedFiles() {
        let r1 = URL(fileURLWithPath: "/data/Sample_R1.fastq.gz")
        let r2 = URL(fileURLWithPath: "/data/Sample_R2.fastq.gz")
        let pairs = groupFASTQByPairs([r1, r2])
        #expect(pairs.count == 1)
        #expect(pairs[0].isPaired)
    }

    @Test("Groups R1/R2 paired files with _1/_2 suffix (SRA convention)")
    func groupSRAPairedFiles() {
        let r1 = URL(fileURLWithPath: "/data/SRR12345_1.fastq.gz")
        let r2 = URL(fileURLWithPath: "/data/SRR12345_2.fastq.gz")
        let pairs = groupFASTQByPairs([r1, r2])
        #expect(pairs.count == 1)
        #expect(pairs[0].isPaired)
    }

    @Test("Single file without mate is unpaired")
    func singleFileUnpaired() {
        let url = URL(fileURLWithPath: "/data/Sample.fastq.gz")
        let pairs = groupFASTQByPairs([url])
        #expect(pairs.count == 1)
        #expect(pairs[0].r1 == url)
        #expect(pairs[0].r2 == nil)
        #expect(!pairs[0].isPaired)
    }

    @Test("R1 without matching R2 is unpaired")
    func r1WithoutR2() {
        let r1 = URL(fileURLWithPath: "/data/Sample_R1_001.fastq.gz")
        let pairs = groupFASTQByPairs([r1])
        #expect(pairs.count == 1)
        #expect(!pairs[0].isPaired)
    }

    @Test("Multiple pairs grouped correctly")
    func multiplePairs() {
        let files = [
            URL(fileURLWithPath: "/data/SampleA_R1_001.fastq.gz"),
            URL(fileURLWithPath: "/data/SampleA_R2_001.fastq.gz"),
            URL(fileURLWithPath: "/data/SampleB_R1_001.fastq.gz"),
            URL(fileURLWithPath: "/data/SampleB_R2_001.fastq.gz"),
            URL(fileURLWithPath: "/data/SampleC.fastq.gz"),
        ]
        let pairs = groupFASTQByPairs(files)
        #expect(pairs.count == 3)
        let pairedCount = pairs.filter(\.isPaired).count
        let singleCount = pairs.filter { !$0.isPaired }.count
        #expect(pairedCount == 2)
        #expect(singleCount == 1)
    }

    @Test("Order is preserved — R2 dropped before R1 still pairs correctly")
    func reverseOrderPairing() {
        let r2 = URL(fileURLWithPath: "/data/Sample_R2_001.fastq.gz")
        let r1 = URL(fileURLWithPath: "/data/Sample_R1_001.fastq.gz")
        let pairs = groupFASTQByPairs([r2, r1])
        #expect(pairs.count == 1)
        #expect(pairs[0].isPaired)
        #expect(pairs[0].r1 == r1)
        #expect(pairs[0].r2 == r2)
    }

    @Test("Handles .fq extension")
    func fqExtension() {
        let r1 = URL(fileURLWithPath: "/data/Sample_R1.fq.gz")
        let r2 = URL(fileURLWithPath: "/data/Sample_R2.fq.gz")
        let pairs = groupFASTQByPairs([r1, r2])
        #expect(pairs.count == 1)
        #expect(pairs[0].isPaired)
    }

    // MARK: - Sample Name Derivation

    @Test("Sample name strips _R1_001 suffix")
    func sampleNameIllumina() {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/data/School030_S33_L004_R1_001.fastq.gz"),
            r2: URL(fileURLWithPath: "/data/School030_S33_L004_R2_001.fastq.gz")
        )
        #expect(pair.sampleName == "School030_S33_L004")
    }

    @Test("Sample name strips _R1 suffix")
    func sampleNameSimple() {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/data/MySample_R1.fastq.gz"),
            r2: nil
        )
        #expect(pair.sampleName == "MySample")
    }

    @Test("Sample name preserves name when no read suffix")
    func sampleNameNoSuffix() {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/data/MySample.fastq.gz"),
            r2: nil
        )
        #expect(pair.sampleName == "MySample")
    }

    @MainActor
    @Test("ONT import sheet hides paired-end choices and imports as single-end")
    func ontImportSheetHidesPairedEndChoices() {
        let pair = FASTQFilePair(
            r1: URL(fileURLWithPath: "/data/barcode01_R1.fastq.gz"),
            r2: URL(fileURLWithPath: "/data/barcode01_R2.fastq.gz")
        )
        var capturedConfig: FASTQImportConfiguration?
        let sheet = FASTQImportConfigSheet(
            pairs: [pair],
            detectedPlatform: .oxfordNanopore,
            onImport: { configuration in
                capturedConfig = configuration
            }
        )

        sheet.loadViewIfNeeded()

        let pairingLabel = sheet.view.fastqImportDescendants(of: NSTextField.self)
            .first { $0.stringValue == "Pairing:" }
        let pairingPopup = sheet.view.fastqImportDescendants(of: NSPopUpButton.self)
            .first { popup in
                (0..<popup.numberOfItems).contains { popup.item(at: $0)?.title == "Paired-end" }
            }

        #expect(pairingLabel?.isHidden == true)
        #expect(pairingPopup?.isHidden == true)
        #expect(pairingPopup?.selectedItem?.title == "Single-end")

        let importButton = sheet.view.fastqImportDescendants(of: NSButton.self)
            .first { $0.title == "Import" }
        importButton?.performClick(nil)

        #expect(capturedConfig?.pairingMode == .singleEnd)
    }
}

private extension NSView {
    func fastqImportDescendants<T: NSView>(of type: T.Type) -> [T] {
        var matches: [T] = []
        for subview in subviews {
            if let match = subview as? T {
                matches.append(match)
            }
            matches.append(contentsOf: subview.fastqImportDescendants(of: type))
        }
        return matches
    }
}
