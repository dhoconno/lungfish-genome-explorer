import AppKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport
import LungfishKitTestSupport

@MainActor final class AlignmentScientificActionCoordinatorTests: XCTestCase {
    private func context(
        _ source: AlignmentSourceReadResolution = .bamFallback,
        outputCapability: AlignmentOutputCapability = .projectDerivedRoot(URL(fileURLWithPath: "/output"))
    ) throws -> AlignmentActionContext {
        let bam = URL(fileURLWithPath: "/evidence/a.bam"), index = URL(fileURLWithPath: "/evidence/a.bam.bai")
        return try .init(identity: .init(workflow: "map", resultID: "r", sampleID: "s", evidenceID: "e"), alignmentURL: bam, indexURL: index, decodingReferenceURL: nil, contig: "chrSynthetic", contigLength: 100, alignmentSnapshot: .init(url: bam, byteCount: 1, sha256: "a"), indexSnapshot: .init(url: index, byteCount: 1, sha256: "i"), decodingReferenceSnapshot: nil, filters: .init(minimumDepth: 1, minimumMapQ: 30, minimumBaseQuality: 20, excludedFlags: 0x904, readGroups: ["rg"]), outputCapability: outputCapability, sourceReads: source, presentationLabel: "evidence")
    }
    func testConsensusShareSessionCleansOnDismissAndSuccessExactlyOnce() {
        for outcome in [AlignmentConsensusShareSession.Outcome.cancelled, .shared] {
            var cleanupCount = 0
            var outcomes: [AlignmentConsensusShareSession.Outcome] = []
            let session = AlignmentConsensusShareSession(
                cleanup: { cleanupCount += 1 },
                finish: { outcomes.append($0) }
            )
            if outcome == .cancelled {
                session.sharingServicePicker(NSSharingServicePicker(items: []), didChoose: nil)
            } else {
                let service = NSSharingService(title: "test", image: NSImage(), alternateImage: nil, handler: {})
                session.sharingService(service, didShareItems: [])
                session.sharingService(service, didShareItems: [])
            }
            XCTAssertEqual(cleanupCount, 1)
            XCTAssertEqual(outcomes, [outcome])
        }
    }

    func testDestinationResolutionReturnsFinalProjectOrUserURLsBeforeStaging() throws {
        let coordinator = AlignmentScientificActionCoordinator(
            destinationResolver: { capability, basename in
                switch capability {
                case .projectDerivedRoot(let root): return .bundle(root.appendingPathComponent("derived/\(basename).lungfishfastq"))
                case .userSelectedDestination: return .file(URL(fileURLWithPath: "/chosen/\(basename).fastq"))
                }
            }
        )

        XCTAssertEqual(try coordinator.resolveDestination(for: try context().outputCapability, outputBaseName: "region").finalURL.path, "/output/derived/region.lungfishfastq")
        XCTAssertEqual(try coordinator.resolveDestination(for: .userSelectedDestination, outputBaseName: "reads").finalURL.path, "/chosen/reads.fastq")
    }

    func testAsyncUserDestinationChooserNormalizesBundleExtensionBeforeLaunch() async throws {
        let coordinator = AlignmentScientificActionCoordinator()

        let destination = try await coordinator.resolveDestination(
            for: .userSelectedDestination,
            outputBaseName: "selected reads",
            userDestinationChooser: { _ in URL(fileURLWithPath: "/chosen/selected reads") }
        )

        XCTAssertEqual(destination.finalURL.path, "/chosen/selected reads.lungfishfastq")

        let mixedCaseDestination = try await coordinator.resolveDestination(
            for: .userSelectedDestination,
            outputBaseName: "selected reads",
            userDestinationChooser: { _ in URL(fileURLWithPath: "/chosen/selected reads.LUNGFISHFASTQ") }
        )

        XCTAssertEqual(mixedCaseDestination.finalURL.path, "/chosen/selected reads.lungfishfastq")
    }

    func testAsyncUserDestinationCancellationIsTypedBeforeLaunch() async throws {
        let coordinator = AlignmentScientificActionCoordinator()
        do {
            _ = try await coordinator.resolveDestination(
                for: .userSelectedDestination,
                outputBaseName: "selected reads",
                userDestinationChooser: { _ in nil }
            )
            XCTFail("Expected destination cancellation")
        } catch let error as AlignmentScientificActionError {
            guard case .destinationCancelled = error else {
                return XCTFail("Expected typed destination cancellation, got \(error)")
            }
        }
    }

    func testProjectDestinationBypassesUserChooser() async throws {
        var chooserCalls = 0
        let coordinator = AlignmentScientificActionCoordinator()
        let destination = try await coordinator.resolveDestination(
            for: .projectDerivedRoot(URL(fileURLWithPath: "/project")),
            outputBaseName: "selected reads",
            userDestinationChooser: { _ in
                chooserCalls += 1
                return URL(fileURLWithPath: "/must-not-be-used")
            }
        )

        XCTAssertEqual(chooserCalls, 0)
        XCTAssertTrue(destination.finalURL.path.hasPrefix("/project/alignment-read-extractions/selected_reads-"))
        XCTAssertEqual(destination.finalURL.pathExtension, "lungfishfastq")
    }

    func testRealViewerRoutesCancelBeforeOperationOrScientificLaunch() async throws {
        let operationIDsBefore = Set(OperationCenter.shared.items.map(\.id))
        let read = AlignedRead(
            name: "qname",
            flag: 0,
            chromosome: "chrSynthetic",
            position: 4,
            mapq: 60,
            cigar: [],
            sequence: "ACGT",
            qualities: [30, 30, 30, 30]
        )

        for route in ["region", "reads"] {
            let viewer = ViewerViewController()
            let window = NSWindow()
            window.contentViewController = viewer
            _ = viewer.view
            viewer.alignmentActionContext = try context(outputCapability: .userSelectedDestination)
            viewer.setExplicitAlignmentSelection(contig: "chrSynthetic", start: 4, end: 9)
            let presenter = CancellingSavePanelPresenter()
            viewer.alignmentExtractionSavePanelPresenter = presenter

            if route == "region" {
                viewer.extractReadsInSelectedAlignmentRegion()
            } else {
                viewer.extractSelectedReads([read])
            }

            await waitUntil { presenter.callCount != 0 }

            XCTAssertEqual(presenter.callCount, 1, route)
            XCTAssertNil(viewer.activeSelectedReadsExtractionTask, route)
            XCTAssertEqual(Set(OperationCenter.shared.items.map(\.id)), operationIDsBefore, route)
            window.contentViewController = nil
        }
    }

    func testViewerRoutesUseSharedFinalPublicationCoordinatorWithoutMappingResult() throws {
        let source = try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/LungfishAppViewTests/AlignmentScientificActionCoordinatorTests.swift",
                with: "Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("resolveDestination(\n            for: context.outputCapability"))
        XCTAssertTrue(source.contains("resolveAlignmentExtractionDestination("))
        XCTAssertTrue(source.contains("alignmentExtractionSavePanelPresenter.present("))
        XCTAssertTrue(source.contains("catch AlignmentScientificActionError.destinationCancelled"))
        XCTAssertTrue(source.contains("launchAlignmentRegionExtraction("))
        XCTAssertTrue(source.contains("launchSelectedReadsExtraction("))
        XCTAssertFalse(source.contains("selectedReadsExtractionRunner"))
        XCTAssertFalse(source.contains("defaultSelectedReadsExtraction"))
        let selectedReadRoute = String(source[source.range(of: "func extractSelectedReads(_ reads: [AlignedRead])")!.lowerBound...])
        XCTAssertFalse(selectedReadRoute.contains("guard let result = activeMappingViewportController?.currentResult"))
        XCTAssertFalse(source.contains("selected-region.lungfishfastq"))
    }

    private final class CancellingSavePanelPresenter: SavePanelPresenting {
        private(set) var callCount = 0

        func present(suggestedName: String, on window: NSWindow) async -> URL? {
            callCount += 1
            return nil
        }
    }
}
