import XCTest
@testable import LungfishWorkflow

final class NFCoreSupportedWorkflowCatalogTests: XCTestCase {
    func testSupportedWorkflowCatalogExposesOnlyViralRecon() throws {
        XCTAssertEqual(NFCoreSupportedWorkflowCatalog.supportedWorkflows.map(\.name), ["viralrecon"])
        XCTAssertEqual(NFCoreSupportedWorkflowCatalog.firstWave.map(\.name), ["viralrecon"])
        XCTAssertTrue(NFCoreSupportedWorkflowCatalog.legacyWorkflows.isEmpty)
        XCTAssertTrue(NFCoreSupportedWorkflowCatalog.futureCustomInterfaceWorkflows.isEmpty)

        let workflow = NFCoreSupportedWorkflowCatalog.supportedWorkflows[0]
        let spec = try XCTUnwrap(ManagedToolLock.bundled.pipeline(id: "nf-core-viralrecon"))
        XCTAssertEqual(workflow.fullName, "nf-core/viralrecon")
        XCTAssertEqual(workflow.pinnedVersion, spec.revision)
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

    func testViralRecon300RequiresLegacyNextflowSyntaxParser() throws {
        let workflow = try XCTUnwrap(NFCoreSupportedWorkflowCatalog.workflow(named: "viralrecon"))

        // Tag 3.0.0's nextflow.config includes conf/test_full_sispa.config, which the
        // tag does not ship. Nextflow 25+ parses every includeConfig eagerly with the
        // strict syntax parser and aborts before launch (nf-core/viralrecon#606); the
        // legacy parser resolves profile includes lazily like older releases did.
        XCTAssertEqual(workflow.launchEnvironment(forVersion: "3.0.0"), ["NXF_SYNTAX_PARSER": "v1"])
        XCTAssertEqual(workflow.launchEnvironment(forVersion: "3.1.0"), [:])
        XCTAssertEqual(
            workflow.launchEnvironment(forVersion: ""),
            workflow.launchEnvironment(forVersion: workflow.pinnedVersion),
            "An empty revision means the pinned release"
        )
    }

    func testWorkflowLookupAcceptsFullNFCoreNames() {
        let workflow = NFCoreSupportedWorkflowCatalog.workflow(named: "nf-core/viralrecon")

        XCTAssertEqual(workflow?.name, "viralrecon")
        XCTAssertEqual(workflow?.fullName, "nf-core/viralrecon")
        XCTAssertTrue(workflow?.resultSurfaces.contains(.variantTracks) == true)
    }
}
