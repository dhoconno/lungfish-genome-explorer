// EsVirituBlastBAMContextTests.swift - The table's BLAST request never carries another sample's BAM
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishEsVirituUI
import LungfishIO
import LungfishWorkflow
import LungfishKit
import LungfishTestSupport
@testable import LungfishCore

/// An alignment viewer that shows nothing, so selecting a detection in these tests reads no BAM and needs no tool.
@MainActor
private final class BlastContextQuietViewer: NSObject, ClassifierAlignmentViewerProviding {
    let viewController = NSViewController()
    private(set) var status: ClassifierAlignmentViewerStatus = .idle
    var onStatusChanged: (@MainActor @Sendable (ClassifierAlignmentViewerStatus) -> Void)?
    override init() { super.init(); viewController.view = NSView() }
    func display(_ request: ClassifierAlignmentEvidenceRequest) {}
    func clear() {}
}

/// 3.1 ADOPT-BIO Backlog 3 (fold F1). The detection table's BLAST request forwards the BAM and index of the detection's
/// own sample. In a batch the controller used to fall back to the BAM of the last selected row when the sample had none,
/// so a sample with no recorded BAM would have BLASTed reads of another sample under its own record.
final class EsVirituBlastBAMContextTests: XCTestCase {
    /// A batch of two samples, A with a BAM and B without. Selecting A's row sets the controller's BAM context to A's.
    /// B's BLAST request must then carry no BAM and no index, so the host says there is no BAM (R10). A's own request
    /// still carries A's BAM and index.
    @MainActor func testABatchBlastOfASampleWithoutABAMNeverTakesAnotherSamplesBAM() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("EsVirituBlastBAMContext-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let bamA = root.appendingPathComponent("A.bam")
        let indexA = root.appendingPathComponent("A.bam.bai")
        try Data().write(to: bamA)
        try Data().write(to: indexA)
        let database = try EsVirituDatabase.create(
            at: root.appendingPathComponent("esviritu.sqlite"),
            rows: [
                Self.row(sample: "A", virus: "Virus A", accession: "NC_A.1", assembly: "ASM_A", bam: bamA, index: indexA),
                Self.row(sample: "B", virus: "Virus B", accession: "NC_B.1", assembly: "ASM_B", bam: nil, index: nil),
            ],
            metadata: ["tool": "test"]
        )

        let controller = EsVirituResultViewController()
        controller.classifierAlignmentViewerFactory = { BlastContextQuietViewer() }
        // `configureFromDatabase` gives both tables the result path as their identity, which keys their column
        // layouts, so they save to a suite and not to `UserDefaults.standard`.
        let layouts = makeTestDefaultsSuite(prefix: "EsVirituBlastBAMContextTests")
        controller.testDetectionTableView.metadataColumns.userDefaults = layouts.defaults
        controller.testBatchTableView.metadataColumns.userDefaults = layouts.defaults
        _ = controller.view
        controller.configureFromDatabase(database, resultURL: root)

        var received: [(sample: String, bam: URL?, index: URL?)] = []
        controller.onBlastVerification = { detection, _, _, bamURL, indexURL in
            received.append((detection.sampleId, bamURL, indexURL))
        }
        let table = controller.testDetectionTableView
        let detectionA = Self.detection(sample: "A", accession: "NC_A.1", assembly: "ASM_A")
        let detectionB = Self.detection(sample: "B", accession: "NC_B.1", assembly: "ASM_B")

        table.onDetectionSelected?(detectionA)
        XCTAssertEqual(controller.bamURL?.path, bamA.path, "selecting A's detection sets the BAM context to A's BAM")

        table.onBlastRequested?(detectionB, 30, ["NC_B.1"])
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.sample, "B")
        XCTAssertNil(received.first?.bam, "B has no BAM, so its BLAST request must not carry A's: \(String(describing: received.first?.bam))")
        XCTAssertNil(received.first?.index, "B has no BAM index, so its BLAST request must not carry A's: \(String(describing: received.first?.index))")

        table.onBlastRequested?(detectionA, 50, ["NC_A.1"])
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.last?.sample, "A")
        XCTAssertEqual(received.last?.bam?.path, bamA.path)
        XCTAssertEqual(received.last?.index?.path, indexA.path)
        withExtendedLifetime(database) {}
    }

    /// A single-sample result has no per-sample lookup, so its BLAST request still carries the result's own BAM and index.
    @MainActor func testASingleSampleBlastStillCarriesItsOwnBAM() throws {
        let controller = EsVirituResultViewController()
        controller.classifierAlignmentViewerFactory = { BlastContextQuietViewer() }
        _ = controller.view
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituBlastBAMContextSingle-\(UUID().uuidString)", isDirectory: true)
        let bam = folder.appendingPathComponent("sample.bam")
        let index = folder.appendingPathComponent("sample.bam.bai")
        controller.bamURL = bam
        controller.bamIndexURL = index

        var received: [(bam: URL?, index: URL?)] = []
        controller.onBlastVerification = { _, _, _, bamURL, indexURL in
            received.append((bamURL, indexURL))
        }
        let detection = Self.detection(sample: "single", accession: "NC_S.1", assembly: "ASM_S")
        controller.testDetectionTableView.onBlastRequested?(detection, 12, ["NC_S.1"])

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.bam, bam)
        XCTAssertEqual(received.first?.index, index)
    }

    /// UX blocker 1 of lane ROWPANE. A context-menu command acts on the clicked row when that row lies outside the
    /// selection, and the selection stays where it is. The run is about the clicked row, so its verdict names that
    /// row's sample. At the base it named the selected row's sample over the clicked row's reads.
    @MainActor func testARunStartedFromAClickedRowOutsideTheSelectionNamesThatRowsSample() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("EsVirituRunRow-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let saved = try SavedBlastSearchProject()
        defer {
            try? fm.removeItem(at: root)
            saved.remove()
        }
        let database = try EsVirituDatabase.create(
            at: root.appendingPathComponent("esviritu.sqlite"),
            rows: [
                Self.row(sample: "A", virus: "Virus A", accession: "NC_A.1", assembly: "ASM_A", bam: nil, index: nil),
                Self.row(sample: "B", virus: "Virus B", accession: "NC_B.1", assembly: "ASM_B", bam: nil, index: nil),
            ],
            metadata: ["tool": "test"]
        )
        let controller = EsVirituResultViewController()
        controller.classifierAlignmentViewerFactory = { BlastContextQuietViewer() }
        let layouts = makeTestDefaultsSuite(prefix: "EsVirituBlastBAMContextTests")
        controller.testDetectionTableView.metadataColumns.userDefaults = layouts.defaults
        controller.testBatchTableView.metadataColumns.userDefaults = layouts.defaults
        _ = controller.view
        controller.configureFromDatabase(database, resultURL: root)
        let actions = controller.resultActions
        var sent: [String] = []
        // The App shows the run's progress at the top of its submit.
        controller.onBlastVerification = { detection, _, _, _, _ in
            sent.append(detection.sampleId)
            actions.showBlastLoading(phase: .submitting, requestId: nil)
        }
        let table = controller.testDetectionTableView
        table.onDetectionSelected?(Self.detection(sample: "A", accession: "NC_A.1", assembly: "ASM_A"))

        table.onBlastRequested?(Self.detection(sample: "B", accession: "NC_B.1", assembly: "ASM_B"), 30, ["NC_B.1"])

        XCTAssertEqual(sent, ["B"], "the clicked row's reads are sent")
        _ = try saved.result("esviritu-A")
        let recordURL = try saved.saveRecord(
            rid: "RID-RUN", sourceResult: "esviritu-A", sample: "Z", taxId: 99, contig: nil, age: -100
        )
        actions.showBlastResults(try BlastSubmissionRecord.load(recordURL).result, recordURL: nil)
        let summary = actions.blastDrawer.summaryLabel.stringValue
        XCTAssertTrue(summary.contains("sample B"), "the verdict names the clicked row's sample: \(summary)")
        XCTAssertFalse(summary.contains("sample A"), "the verdict does not name the selected row: \(summary)")
        withExtendedLifetime(database) {}
    }

    private static func detection(sample: String, accession: String, assembly: String) -> ViralDetection {
        ViralDetection(
            sampleId: sample, name: "Virus \(sample)", description: "", length: 4_200, segment: nil,
            accession: accession, assembly: assembly, assemblyLength: 4_200,
            kingdom: nil, phylum: nil, tclass: nil, order: nil, family: nil, genus: nil, species: nil, subspecies: nil,
            rpkmf: 1, readCount: 50, coveredBases: 4_200, meanCoverage: 1, avgReadIdentity: 0.99, pi: 0,
            filteredReadsInSample: 100
        )
    }

    private static func row(
        sample: String, virus: String, accession: String, assembly: String, bam: URL?, index: URL?
    ) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample,
            virusName: virus,
            description: nil,
            contigLength: 4_200,
            segment: nil,
            accession: accession,
            assembly: assembly,
            assemblyLength: 4_200,
            kingdom: nil,
            phylum: nil,
            tclass: nil,
            torder: nil,
            family: nil,
            genus: nil,
            species: nil,
            subspecies: nil,
            rpkmf: 1,
            readCount: 50,
            uniqueReads: 40,
            coveredBases: 4_200,
            meanCoverage: 1,
            avgReadIdentity: 0.99,
            pi: nil,
            filteredReadsInSample: 100,
            bamPath: bam?.path,
            bamIndexPath: index?.path
        )
    }
}
