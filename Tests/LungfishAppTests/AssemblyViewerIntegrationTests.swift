import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
@testable import LungfishAssemblyUI

@MainActor
final class AssemblyViewerIntegrationTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    func testBlastCallbackReceivesRealFastaPayload() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(
            result: makeAssemblyResult(),
            materializationRunner: { _ in
                LungfishCLIRunner.Output(
                    stdout: ">contig_7 annotated header\nAACCGGTT\n",
                    stderr: "",
                    status: 0
                )
            }
        )

        let exp = expectation(description: "blast callback")
        vc.onBlastVerification = { request in
            XCTAssertEqual(request.readCount, 1)
            XCTAssertEqual(request.sourceLabel, "contig contig_7")
            XCTAssertEqual(request.sequences, [">contig_7 annotated header\nAACCGGTT\n"])
            exp.fulfill()
        }

        try await vc.testSelectContig(named: "contig_7")
        vc.testTriggerBlast()

        await fulfillment(of: [exp], timeout: 5)
    }

    func testViewerDisplayAssemblyResultHostsAssemblyController() throws {
        let viewer = ViewerViewController()
        _ = viewer.view

        viewer.displayAssemblyResult(try makeAssemblyResult())

        XCTAssertNotNil(viewer.assemblyResultController)
        XCTAssertTrue(viewer.assemblyResultController?.view.superview === viewer.view)
        XCTAssertNotNil(viewer.assemblyResultController?.onBlastVerification)
    }

    func testViewerDisplayAssemblyResultKeepsSummaryAndFilterInsideWindowSafeAreaAfterResize() throws {
        let viewer = ViewerViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "AssemblyViewerIntegrationTests")
        window.toolbarStyle = .unified
        window.contentViewController = viewer
        defer { window.close() }

        viewer.displayAssemblyResult(try makeAssemblyResult())

        for size in [
            NSSize(width: 960, height: 640),
            NSSize(width: 720, height: 520),
        ] {
            window.setContentSize(size)
            window.layoutIfNeeded()
            viewer.view.layoutSubtreeIfNeeded()

            let assemblyView = try XCTUnwrap(viewer.assemblyResultController?.view)
            let summaryStrip = try XCTUnwrap(
                descendant(in: assemblyView, accessibilityIdentifier: "assembly-result-summary-strip")
            )
            let filter = try XCTUnwrap(
                descendant(in: assemblyView, accessibilityIdentifier: "assembly-result-search")
            )
            let safeAreaFrame = viewer.view.safeAreaLayoutGuide.frame
            let summaryFrame = summaryStrip.convert(summaryStrip.bounds, to: viewer.view)
            let filterFrame = filter.convert(filter.bounds, to: viewer.view)

            XCTAssertGreaterThan(viewer.view.safeAreaInsets.top, 0)
            XCTAssertLessThanOrEqual(summaryFrame.maxY, safeAreaFrame.maxY + 0.5)
            XCTAssertGreaterThanOrEqual(summaryFrame.minY, safeAreaFrame.minY - 0.5)
            XCTAssertLessThanOrEqual(filterFrame.maxY, safeAreaFrame.maxY + 0.5)
            XCTAssertGreaterThanOrEqual(filterFrame.minY, safeAreaFrame.minY - 0.5)
        }
    }

    func testViewerDisplayAssemblyResultHostsAssemblyControllerForEmptyContigOutcome() async throws {
        let viewer = ViewerViewController()
        _ = viewer.view

        viewer.displayAssemblyResult(try makeEmptyAssemblyResult())

        await waitUntil {
            viewer.assemblyResultController?.testEmptyStateMessage == "Assembly completed, but no contigs were generated."
        }

        XCTAssertEqual(viewer.contentMode, .assembly)
        XCTAssertNotNil(viewer.assemblyResultController)
        XCTAssertTrue(viewer.assemblyResultController?.view.superview === viewer.view)
        XCTAssertEqual(
            viewer.assemblyResultController?.testEmptyStateMessage,
            "Assembly completed, but no contigs were generated."
        )
    }

    func testAssemblyBlastVerificationCreatesBottomDrawerHost() throws {
        let viewer = ViewerViewController()
        _ = viewer.view

        viewer.displayAssemblyResult(try makeAssemblyResult())
        viewer.assemblyResultController?.onBlastVerification?(
            BlastRequest(taxId: nil, sequences: [], readCount: 0, sourceLabel: "selected contigs")
        )

        let drawer = findDescendant(
            ofType: BlastResultsDrawerContainerView.self,
            in: viewer.assemblyResultController?.view
        )
        XCTAssertNotNil(drawer)
    }

    func testHideAssemblyViewRestoresViewerChrome() throws {
        let viewer = ViewerViewController()
        _ = viewer.view

        viewer.headerView.isHidden = false
        viewer.annotationDrawerView = AnnotationTableDrawerView(frame: .zero)
        viewer.annotationDrawerView?.isHidden = false
        viewer.fastqMetadataDrawerView = FASTQMetadataDrawerView()
        viewer.fastqMetadataDrawerView?.isHidden = false

        viewer.displayAssemblyResult(try makeAssemblyResult())
        viewer.hideAssemblyView()

        XCTAssertFalse(viewer.enhancedRulerView.isHidden)
        XCTAssertFalse(viewer.viewerView.isHidden)
        XCTAssertFalse(viewer.headerView.isHidden)
        XCTAssertFalse(viewer.statusBar.isHidden)
        XCTAssertFalse(viewer.annotationDrawerView?.isHidden ?? true)
        XCTAssertFalse(viewer.fastqMetadataDrawerView?.isHidden ?? true)
    }

    private func findDescendant<T: NSView>(ofType type: T.Type, in root: NSView?) -> T? {
        guard let root else { return nil }
        if let match = root as? T {
            return match
        }
        for subview in root.subviews {
            if let match = findDescendant(ofType: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func descendant(in root: NSView, accessibilityIdentifier: String) -> NSView? {
        if root.accessibilityIdentifier() == accessibilityIdentifier {
            return root
        }
        return root.subviews.lazy.compactMap {
            self.descendant(in: $0, accessibilityIdentifier: accessibilityIdentifier)
        }.first
    }
}
