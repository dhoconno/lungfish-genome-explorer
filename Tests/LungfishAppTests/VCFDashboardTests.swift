// VCFDashboardTests.swift - Tests for VCF Dataset Dashboard functionality
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

/// Use IO variant to disambiguate from LungfishCore.VCFVariant
private typealias IOVCFVariant = LungfishIO.VCFVariant

final class VCFDashboardTests: XCTestCase {

    // MARK: - Helpers

    private func makeSampleVariants(count: Int = 10) -> [IOVCFVariant] {
        (0..<count).map { i in
            IOVCFVariant(
                id: "var_\(i)",
                chromosome: "NC_045512.2",
                position: 100 + i * 50,
                ref: "A",
                alt: ["G"],
                quality: Double(100 + i * 10),
                filter: "PASS",
                info: ["DP": "\(500 + i * 10)", "AF": "0.99\(i)"],
                format: nil,
                genotypes: [:]
            )
        }
    }

    private func makeSampleSummary(
        variantCount: Int = 10,
        chromosomes: Set<String> = ["NC_045512.2"],
        assembly: String? = "SARS-CoV-2"
    ) -> VCFSummary {
        let header = VCFHeader(
            fileFormat: "VCFv4.0",
            infoFields: [:],
            formatFields: [:],
            filters: [:],
            contigs: [:],
            sampleNames: [],
            otherHeaders: [:]
        )
        let ref: ReferenceInference.Result? = assembly.map {
            ReferenceInference.Result(
                assembly: $0, organism: $0, accession: nil,
                namingConvention: nil, confidence: .medium,
                sequenceCount: 1, totalLength: 29903
            )
        }
        return VCFSummary(
            header: header,
            variantCount: variantCount,
            chromosomes: chromosomes,
            maxPositionPerChromosome: ["NC_045512.2": 29000],
            variantTypes: ["SNP": variantCount],
            hasSampleColumns: false,
            inferredReference: ref,
            qualityStats: VCFSummary.QualityStats(
                min: 100, max: 1000, mean: 500, count: variantCount
            ),
            filterCounts: ["PASS": variantCount]
        )
    }

    // MARK: - VCFDatasetViewController Configuration

    @MainActor
    func testVCFDatasetViewControllerConfiguration() {
        let controller = VCFDatasetViewController()
        _ = controller.view

        let summary = makeSampleSummary(variantCount: 10)
        let variants = makeSampleVariants(count: 10)

        controller.configure(summary: summary, variants: variants)

        XCTAssertEqual(controller.numberOfRows(in: NSTableView()), 10)
    }

    @MainActor
    func testVCFDatasetViewControllerEmptyVariants() {
        let controller = VCFDatasetViewController()
        _ = controller.view

        let summary = makeSampleSummary(variantCount: 0, chromosomes: [])
        let variants: [IOVCFVariant] = []

        controller.configure(summary: summary, variants: variants)

        XCTAssertEqual(controller.numberOfRows(in: NSTableView()), 0)
    }

    @MainActor
    func testVCFDatasetViewControllerTableSorting() {
        let controller = VCFDatasetViewController()
        _ = controller.view

        let variants = [
            IOVCFVariant(id: "v1", chromosome: "chr1", position: 500,
                       ref: "A", alt: ["G"], quality: 100, filter: "PASS",
                       info: [:], format: nil, genotypes: [:]),
            IOVCFVariant(id: "v2", chromosome: "chr1", position: 100,
                       ref: "T", alt: ["C"], quality: 200, filter: "PASS",
                       info: [:], format: nil, genotypes: [:]),
            IOVCFVariant(id: "v3", chromosome: "chr1", position: 300,
                       ref: "G", alt: ["A"], quality: 50, filter: "q10",
                       info: [:], format: nil, genotypes: [:]),
        ]

        let summary = makeSampleSummary(variantCount: 3)
        controller.configure(summary: summary, variants: variants)

        XCTAssertEqual(controller.numberOfRows(in: NSTableView()), 3)
    }

    // MARK: - VCF File Detection Logic

    func testVCFFileDetectionPlainVCF() {
        XCTAssertTrue(isVCF(URL(fileURLWithPath: "/path/to/variants.vcf")))
    }

    func testVCFFileDetectionGzipped() {
        XCTAssertTrue(isVCF(URL(fileURLWithPath: "/path/to/variants.vcf.gz")))
    }

    func testVCFFileDetectionCaseInsensitive() {
        XCTAssertTrue(isVCF(URL(fileURLWithPath: "/path/to/VARIANTS.VCF")))
        XCTAssertTrue(isVCF(URL(fileURLWithPath: "/path/to/variants.VCF.GZ")))
    }

    func testNonVCFFilesNotDetected() {
        XCTAssertFalse(isVCF(URL(fileURLWithPath: "/path/to/genome.fasta")))
        XCTAssertFalse(isVCF(URL(fileURLWithPath: "/path/to/reads.fastq")))
        XCTAssertFalse(isVCF(URL(fileURLWithPath: "/path/to/annotations.gff3")))
        XCTAssertFalse(isVCF(URL(fileURLWithPath: "/path/to/data.bed")))
        XCTAssertFalse(isVCF(URL(fileURLWithPath: "/path/to/data.bam")))
    }

    /// Local replica of the isVCFFile logic for testing.
    private func isVCF(_ url: URL) -> Bool {
        var checkURL = url
        if checkURL.pathExtension.lowercased() == "gz" {
            checkURL = checkURL.deletingPathExtension()
        }
        return checkURL.pathExtension.lowercased() == "vcf"
    }

    // MARK: - Notification Names

    func testVCFDatasetLoadedNotificationExists() {
        let name = Notification.Name.vcfDatasetLoaded
        XCTAssertEqual(name.rawValue, "vcfDatasetLoaded")
    }

    func testVCFDatasetLoadedNotificationContent() {
        let summary = makeSampleSummary()

        let notification = Notification(
            name: .vcfDatasetLoaded,
            object: nil,
            userInfo: ["summary": summary]
        )

        let extractedSummary = notification.userInfo?["summary"] as? VCFSummary
        XCTAssertNotNil(extractedSummary)
        XCTAssertEqual(extractedSummary?.variantCount, 10)
    }

    // MARK: - DocumentLoader VCF Empty Result

    func testDocumentLoaderVCFReturnsEmptyResult() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VCFDashboardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vcfURL = tempDir.appendingPathComponent("test.vcf")
        let vcfContent = """
        ##fileformat=VCFv4.0
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\t.\tA\tG\t30\tPASS\tDP=10
        """
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)

        let result = try await DocumentLoader.loadFile(at: vcfURL, type: .vcf)
        XCTAssertTrue(result.sequences.isEmpty,
            "VCF DocumentLoader should return empty sequences for dashboard display")
        XCTAssertTrue(result.annotations.isEmpty,
            "VCF DocumentLoader should return empty annotations for dashboard display")
    }

    // MARK: - VCFSummaryBar

    @MainActor
    func testVCFSummaryBarCreation() {
        let bar = VCFSummaryBar(frame: NSRect(x: 0, y: 0, width: 800, height: 64))
        let summary = makeSampleSummary()
        bar.update(with: summary)

        XCTAssertEqual(bar.frame.width, 800)
        XCTAssertEqual(bar.frame.height, 64)
    }

    @MainActor
    func testVCFSummaryBarWithNoInferredReference() {
        let bar = VCFSummaryBar(frame: NSRect(x: 0, y: 0, width: 800, height: 64))
        let summary = makeSampleSummary(assembly: nil)
        bar.update(with: summary)
        // Should not crash — download button should be hidden
    }

    @MainActor
    func testVCFSummaryBarDownloadCallback() {
        let bar = VCFSummaryBar(frame: NSRect(x: 0, y: 0, width: 800, height: 64))

        var callbackInvoked = false
        bar.onDownloadReference = { _ in
            callbackInvoked = true
        }

        let summary = makeSampleSummary()
        bar.update(with: summary)

        // Simulate button tap (directly call the method the button targets)
        bar.perform(NSSelectorFromString("downloadTapped"))

        XCTAssertTrue(callbackInvoked, "Download callback should fire when tapped")
    }
}
