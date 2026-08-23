// EsVirituReferenceCandidateResolutionTests.swift - Injected reference-candidate resolution for the EsViritu leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishEsVirituUI
import LungfishIO
import LungfishWorkflow
import LungfishKit
import LungfishCore

@MainActor
private final class RecordingEvidenceViewer: NSObject, ClassifierAlignmentViewerProviding {
    let viewController = NSViewController()
    private(set) var status: ClassifierAlignmentViewerStatus = .idle
    var onStatusChanged: (@MainActor @Sendable (ClassifierAlignmentViewerStatus) -> Void)?
    private(set) var requests: [ClassifierAlignmentEvidenceRequest] = []
    private(set) var clearCount = 0
    override init() { super.init(); viewController.view = NSView() }
    func display(_ request: ClassifierAlignmentEvidenceRequest) { requests.append(request) }
    func clear() { clearCount += 1 }
}

/// The EsViritu leaf may not know how to find the managed EsViritu database, so
/// the reference for its alignment evidence has to arrive through an injected
/// callback wired by `LungfishApp`. These tests pin the callback contract: it is
/// consulted with the selected row's contig and length, and whatever it returns
/// (including `nil`) is what lands in the evidence request.
final class EsVirituReferenceCandidateResolutionTests: XCTestCase {

    @MainActor func testInjectedResolverSuppliesReferenceCandidateForSelectedContig() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let fastaURL = fixture.root.appendingPathComponent("virus_pathogen_database.fna")
        try Data().write(to: fastaURL)

        let recorder = RecordingEvidenceViewer()
        let controller = EsVirituResultViewController()
        controller.classifierAlignmentViewerFactory = { recorder }
        var observedArguments: [(sampleID: String, contig: String, length: Int)] = []
        controller.onResolveReferenceCandidate = { sampleID, contig, length in
            observedArguments.append((sampleID, contig, length))
            return ClassifierAlignmentReferenceCandidate(
                fastaURL: fastaURL,
                recordName: contig,
                expectedLength: length
            )
        }
        _ = controller.view
        controller.configureFromDatabase(fixture.database, resultURL: fixture.root)
        controller.testDetectionTableView.testOutlineView
            .selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertEqual(observedArguments.count, 1)
        XCTAssertEqual(observedArguments.first?.sampleID, "sample-a")
        XCTAssertEqual(observedArguments.first?.contig, "NC_REF.1")
        XCTAssertEqual(observedArguments.first?.length, 4_200)

        let request = try XCTUnwrap(recorder.requests.first)
        let candidate = try XCTUnwrap(request.referenceCandidate)
        XCTAssertEqual(candidate.fastaURL, fastaURL)
        XCTAssertEqual(candidate.recordName, "NC_REF.1")
        XCTAssertEqual(candidate.expectedLength, 4_200)
    }

    @MainActor func testUnresolvedReferenceLeavesRequestWithoutCandidate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let recorder = RecordingEvidenceViewer()
        let controller = EsVirituResultViewController()
        controller.classifierAlignmentViewerFactory = { recorder }
        var resolverCallCount = 0
        controller.onResolveReferenceCandidate = { _, _, _ in
            resolverCallCount += 1
            return nil
        }
        _ = controller.view
        controller.configureFromDatabase(fixture.database, resultURL: fixture.root)
        controller.testDetectionTableView.testOutlineView
            .selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertEqual(resolverCallCount, 1)
        XCTAssertNil(try XCTUnwrap(recorder.requests.first).referenceCandidate)
    }

    /// The default must stay leaf-safe: a controller nobody wired still builds a
    /// request, it just has no reference.
    @MainActor func testDefaultResolverIsAbsentAndRequestStillBuilds() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let recorder = RecordingEvidenceViewer()
        let controller = EsVirituResultViewController()
        controller.classifierAlignmentViewerFactory = { recorder }
        _ = controller.view
        controller.configureFromDatabase(fixture.database, resultURL: fixture.root)
        controller.testDetectionTableView.testOutlineView
            .selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        XCTAssertNil(controller.onResolveReferenceCandidate)
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertNil(recorder.requests[0].referenceCandidate)
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        let database: EsVirituDatabase

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("EsVirituReferenceResolver-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bamURL = root.appendingPathComponent("sample-a.bam")
            let indexURL = root.appendingPathComponent("sample-a.bam.bai")
            for url in [bamURL, indexURL] { try Data().write(to: url) }
            database = try EsVirituDatabase.create(
                at: root.appendingPathComponent("esviritu.sqlite"),
                rows: [Self.row(sample: "sample-a", bamURL: bamURL, indexURL: indexURL)],
                metadata: ["tool": "test"]
            )
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        private static func row(sample: String, bamURL: URL, indexURL: URL) -> EsVirituDetectionRow {
            EsVirituDetectionRow(
                sample: sample,
                virusName: "Reference virus",
                description: nil,
                contigLength: 4_200,
                segment: nil,
                accession: "NC_REF.1",
                assembly: "ASM_\(sample)",
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
                readCount: 24,
                uniqueReads: 20,
                coveredBases: 4_200,
                meanCoverage: 1,
                avgReadIdentity: 0.99,
                pi: nil,
                filteredReadsInSample: 100,
                bamPath: bamURL.path,
                bamIndexPath: indexURL.path
            )
        }
    }
}
