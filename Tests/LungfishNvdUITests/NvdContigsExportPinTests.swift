// NvdContigsExportPinTests.swift - Pins the NVD contigs export at the 12.31 base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M1 for M4 (QA 1). These pins hold today's in-app writer, `writeContigsTSV`, before
// `nvd export contigs` replaces it. The view applies its search and sample selection to the best hits it shows
// (`displayedContigs`, ordered by sample and contig), so the bytes hold only those rows with the shown metadata
// column. An outline sort leaves the bytes in that order. The record names the tool `Lungfish.app` with its own
// argv. The M4 parity class reads these facts as side A.

import XCTest
import AppKit
@testable import LungfishNvdUI
@testable import LungfishIO
import LungfishWorkflow
@testable import LungfishKit
@testable import LungfishCore
import LungfishTestSupport

@MainActor
private final class NvdRecordingFailurePresenter: ExportFailurePresenting {
    private(set) var alerts: [(title: String, message: String)] = []
    func presentExportFailure(title: String, message: String, in window: NSWindow?) {
        alerts.append((title, message))
    }
}

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
        let outputURL = folder.appendingPathComponent("contigs.tsv")
        try vc.writeContigsTSV(to: outputURL)

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), [
            "sample_id\tcontig\tlength\tclassification\trank\taccession\tsubject\tpident\tevalue\tbitscore\tmapped_reads\treads_per_billion\tCohort",
            "sample1\tcontig_1\t8\tAlpha virus\tspecies\tNC_sample1_contig_1\tAlpha virus\t100.00\t0.0\t50.0\t30\t30000000\tcase",
            "sample2\tcontig_1\t8\tGamma virus\tspecies\tNC_sample2_contig_1\tGamma virus\t100.00\t0.0\t50.0\t20\t20000000\tcontrol",
        ].joined(separator: "\n") + "\n")
    }

    /// The record facts lane 12.31 predicts will move (tool, kind, argv, workflow name), the `resolved` keys and
    /// the inputs, which name the database, the result's manifest and the run folder.
    @MainActor func testRecordNamesTheAppWriterAndTheViewState() throws {
        let vc = try configuredController()
        let outputURL = folder.appendingPathComponent("contigs.tsv")
        try vc.writeContigsTSV(to: outputURL)

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        let argv = ["Lungfish.app", "export-nvd-contigs", "--output", outputURL.path]
        XCTAssertEqual(envelope.workflowName, "lungfish app nvd contigs export")
        XCTAssertEqual(envelope.toolName, "Lungfish.app")
        XCTAssertEqual(envelope.tool.kind, "gui")
        XCTAssertEqual(envelope.argv, argv)
        XCTAssertEqual(envelope.durableReplayArgv, argv)
        let resolved = envelope.options.resolvedDefaults
        XCTAssertEqual(resolved.keys.sorted(), [
            "experiment", "groupingMode", "metadataColumns", "rowCount", "searchQuery", "selectedSamples",
            "sourceSampleCount", "taxonGroupCount",
        ])
        XCTAssertEqual(resolved["rowCount"]?.integerValue, 2)
        XCTAssertEqual(resolved["experiment"]?.stringValue, "exp-pin")
        XCTAssertEqual(resolved["sourceSampleCount"]?.integerValue, 3)
        XCTAssertEqual(resolved["selectedSamples"]?.arrayValue?.compactMap(\.stringValue), ["sample1", "sample2"])
        XCTAssertEqual(resolved["searchQuery"]?.stringValue, "virus")
        XCTAssertEqual(resolved["groupingMode"]?.stringValue, "bySample")
        XCTAssertEqual(resolved["metadataColumns"]?.arrayValue?.compactMap(\.stringValue), ["Cohort"])
        XCTAssertEqual(envelope.options.explicit.keys.sorted(), ["format", "outputPath"])
        XCTAssertEqual(envelope.options.defaults["format"]?.stringValue, "tsv")
        XCTAssertEqual(
            envelope.files.filter { $0.role == .input }.map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted(),
            ["manifest.json", "nvd-run", "nvd.sqlite"]
        )
    }

    /// A failed write reaches `ResultExportCoordinator.reportFailure`, whose words UX 1 keeps.
    @MainActor func testFailureAlertWords() throws {
        let vc = try configuredController()
        let blocked = folder.appendingPathComponent("contigs.tsv", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let presenter = NvdRecordingFailurePresenter()
        do {
            try vc.writeContigsTSV(to: blocked)
            XCTFail("a folder in the output's place fails the export")
        } catch {
            ResultExportCoordinator.reportFailure(
                fileName: blocked.lastPathComponent, error: error, window: nil, presenter: presenter
            )
            XCTAssertEqual(presenter.alerts.map(\.title), ["Export Failed"])
            XCTAssertEqual(presenter.alerts.map(\.message), ["Could not write contigs.tsv: \(error.localizedDescription)"])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: blocked).path))
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
            at: bundleURL.appendingPathComponent("nvd.sqlite"),
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
        vc.testShowMetadataColumn("Cohort", store: try SampleMetadataStore(
            csvData: Data("Sample\tCohort\nsample1\tcase\nsample2\tcontrol\nsample3\tcase\n".utf8),
            knownSampleIds: Set(samples)
        ))
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
