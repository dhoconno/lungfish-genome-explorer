import XCTest
@testable import LungfishApp

@MainActor
final class AssemblyViewerIntegrationTests: XCTestCase {
    func testBlastCallbackReceivesRealFastaPayload() async throws {
        let vc = AssemblyResultViewController()
        _ = vc.view
        try await vc.configureForTesting(result: makeAssemblyResult())

        let exp = expectation(description: "blast callback")
        vc.onBlastVerification = { request in
            XCTAssertEqual(request.readCount, 1)
            XCTAssertEqual(request.sourceLabel, "contig contig_7")
            XCTAssertEqual(request.sequences, [">contig_7 annotated header\nAACCGGTT\n"])
            exp.fulfill()
        }

        try await vc.testSelectContig(named: "contig_7")
        vc.testTriggerBlast()

        await fulfillment(of: [exp], timeout: 2.0)
    }

    func testViewerDisplayAssemblyResultHostsAssemblyController() throws {
        let viewer = ViewerViewController()
        _ = viewer.view

        viewer.displayAssemblyResult(try makeAssemblyResult())

        XCTAssertNotNil(viewer.assemblyResultController)
        XCTAssertTrue(viewer.assemblyResultController?.view.superview === viewer.view)
        XCTAssertNotNil(viewer.assemblyResultController?.onBlastVerification)
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
}
