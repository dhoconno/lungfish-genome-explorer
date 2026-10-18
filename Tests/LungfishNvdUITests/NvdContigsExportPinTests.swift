// NvdContigsExportPinTests.swift - Pins the NVD contigs export bytes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M1 for M4 (QA 1). The byte pin held the in-app writer, `writeContigsTSV`, before
// `nvd export contigs` replaced it, and now holds the builder the leaf calls, `NvdContigsExport.contigsTSV`, fed by
// the view's shown contigs and metadata columns, with the same expected bytes. The view applies its search and sample
// selection to the best hits it shows (`displayedContigs`, ordered by sample and contig), so the bytes hold only those
// rows with the shown metadata column. An outline sort leaves the bytes in that order. The record, input and alert
// facts the deleted pins held are in `NvdExportCLIGUIParityReplayTests`, `NvdExportContigsCommandTests` and
// `NvdContigsExportRowTests`.

import XCTest
import AppKit
@testable import LungfishNvdUI
@testable import LungfishIO
import LungfishWorkflow
@testable import LungfishCore
import LungfishTestSupport

final class NvdContigsExportPinTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NvdContigsExportPin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The search drops `Beta phage`, the selection drops `sample3`, and the sort by mapped reads ascending, which
    /// would put `sample2` first, leaves the database's order.
    @MainActor func testBytesHoldTheShownContigsInDatabaseOrder() throws {
        let vc = try configuredController()

        XCTAssertEqual(Self.bytes(of: vc), [
            "sample_id\tcontig\tlength\tclassification\trank\taccession\tsubject\tpident\tevalue\tbitscore\tmapped_reads\treads_per_billion\tCohort",
            "sample1\tcontig_1\t8\tAlpha virus\tspecies\tNC_sample1_contig_1\tAlpha virus\t100.00\t0.0\t50.0\t30\t30000000\tcase",
            "sample2\tcontig_1\t8\tGamma virus\tspecies\tNC_sample2_contig_1\tGamma virus\t100.00\t0.0\t50.0\t20\t20000000\tcontrol",
        ].joined(separator: "\n") + "\n")
    }

    /// The builder the leaf calls, fed by the view's shown contigs and metadata columns as the deleted writer fed it.
    @MainActor private static func bytes(of vc: NvdResultViewController) -> String {
        let hits = vc.testContigsExportWriterState.hits
        let metadata = vc.metadataColumnController
        return NvdContigsExport.contigsTSV(
            hits: hits,
            metadataHeaders: metadata.exportHeaders,
            metadataValuesBySample: Dictionary(uniqueKeysWithValues: Set(hits.map(\.sampleId)).map {
                ($0, metadata.exportValues(for: $0))
            })
        )
    }

    // MARK: - Fixture

    @MainActor private func configuredController() throws -> NvdResultViewController {
        let isolatedDefaults = makeTestDefaultsSuite(prefix: "NvdContigsExportPinTests").defaults
        NvdResultViewController.testMetadataUserDefaultsOverride = isolatedDefaults
        addTeardownBlock {
            NvdResultViewController.testMetadataUserDefaultsOverride = nil
        }
        let runFolder = folder.appendingPathComponent("nvd-run", isDirectory: true)
        let bundleURL = folder.appendingPathComponent("fixture.nvd", isDirectory: true)
        try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent("manifest.json"))
        let samples = ["sample1", "sample2", "sample3"]
        let database = try NvdDatabase.create(
            at: bundleURL.appendingPathComponent("hits.sqlite"),
            hits: [
                Self.hit(sample: "sample1", contig: "contig_1", name: "Alpha virus", reads: 30),
                Self.hit(sample: "sample1", contig: "contig_2", name: "Beta phage", reads: 50),
                Self.hit(sample: "sample2", contig: "contig_1", name: "Gamma virus", reads: 20),
                Self.hit(sample: "sample3", contig: "contig_1", name: "Alpha virus", reads: 40),
            ],
            samples: samples.map {
                NvdSampleMetadata(
                    sampleId: $0, bamPath: "\($0).bam", fastaPath: "\($0).fasta",
                    totalReads: 1000, contigCount: 1, hitCount: 1
                )
            }
        )
        let manifest = NvdManifest(
            experiment: "exp-pin", sampleCount: 3, contigCount: 4, hitCount: 4, blastDbVersion: "db",
            snakemakeRunId: "run-1", sourceDirectoryPath: runFolder.path,
            samples: samples.map {
                NvdSampleSummary(
                    sampleId: $0, contigCount: 1, hitCount: 1, totalReads: 1000,
                    bamRelativePath: "\($0).bam", fastaRelativePath: "\($0).fasta"
                )
            },
            cachedTopContigs: nil
        )

        let vc = NvdResultViewController()
        _ = vc.view
        vc.configure(database: database, manifest: manifest, bundleURL: bundleURL)
        let metadataFolder = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        try Data("Sample\tCohort\nsample1\tcase\nsample2\tcontrol\nsample3\tcase\n".utf8)
            .write(to: metadataFolder.appendingPathComponent("sample_metadata.tsv"))
        let store = try XCTUnwrap(SampleMetadataStore.load(from: bundleURL, knownSampleIds: Set(samples)))
        vc.testShowMetadataColumn("Cohort", store: store)
        vc.testSearchField.stringValue = "virus"
        _ = vc.testSearchField.target?.perform(vc.testSearchField.action, with: vc.testSearchField)
        vc.testOutlineView.sortDescriptors = [NSSortDescriptor(key: "mappedReads", ascending: true)]
        vc.samplePickerState.selectedSamples = ["sample1", "sample2"]
        vc.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        return vc
    }

    private static func hit(sample: String, contig: String, name: String, reads: Int) -> NvdBlastHit {
        NvdBlastHit(
            experiment: "exp-pin", blastTask: "blastn", sampleId: sample, qseqid: contig, qlen: 8,
            sseqid: "NC_\(sample)_\(contig)", stitle: name, taxRank: "species", length: 8, pident: 100, evalue: 0,
            bitscore: 50, sscinames: name, staxids: "1234", blastDbVersion: "db", snakemakeRunId: "run-1",
            mappedReads: reads, totalReads: 1000, statDbVersion: "stats-1", adjustedTaxid: "1234",
            adjustmentMethod: "dominant", adjustedTaxidName: name, adjustedTaxidRank: "species", hitRank: 1,
            readsPerBillion: Double(reads) * 1_000_000
        )
    }
}
