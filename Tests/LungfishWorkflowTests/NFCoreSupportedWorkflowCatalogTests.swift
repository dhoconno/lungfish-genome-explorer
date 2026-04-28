import XCTest
@testable import LungfishWorkflow

final class NFCoreSupportedWorkflowCatalogTests: XCTestCase {
    func testSupportedWorkflowCatalogExposesOnlyViralRecon() {
        XCTAssertEqual(NFCoreSupportedWorkflowCatalog.supportedWorkflows.map(\.name), ["viralrecon"])
        XCTAssertEqual(NFCoreSupportedWorkflowCatalog.firstWave.map(\.name), ["viralrecon"])
        XCTAssertTrue(NFCoreSupportedWorkflowCatalog.legacyWorkflows.isEmpty)
        XCTAssertTrue(NFCoreSupportedWorkflowCatalog.futureCustomInterfaceWorkflows.isEmpty)

        let workflow = NFCoreSupportedWorkflowCatalog.supportedWorkflows[0]
        XCTAssertEqual(workflow.fullName, "nf-core/viralrecon")
        XCTAssertEqual(workflow.pinnedVersion, "3.0.0")
        XCTAssertEqual(workflow.difficulty, .easy)
        XCTAssertTrue(workflow.resultSurfaces.contains(.variantTracks))
        XCTAssertEqual(workflow.supportedAdapterIDs, ["viralrecon"])
    }

    func testUnsupportedGenericNFCoreWorkflowsAreNotLookupable() {
        XCTAssertNil(NFCoreSupportedWorkflowCatalog.workflow(named: "fetchngs"))
        XCTAssertNil(NFCoreSupportedWorkflowCatalog.workflow(named: "nf-core/seqinspector"))
        XCTAssertNil(NFCoreSupportedWorkflowCatalog.workflow(named: "scrnaseq"))
        XCTAssertNil(NFCoreSupportedWorkflowCatalog.workflow(named: "vipr"))
    }

    func testWorkflowLookupAcceptsFullNFCoreNames() {
        let workflow = NFCoreSupportedWorkflowCatalog.workflow(named: "nf-core/viralrecon")

        XCTAssertEqual(workflow?.name, "viralrecon")
        XCTAssertEqual(workflow?.fullName, "nf-core/viralrecon")
        XCTAssertTrue(workflow?.resultSurfaces.contains(.variantTracks) == true)
    }
}
