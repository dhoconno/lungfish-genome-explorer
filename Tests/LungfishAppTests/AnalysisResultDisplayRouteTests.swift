import XCTest
@testable import LungfishApp

final class AnalysisResultDisplayRouteTests: XCTestCase {
    func testRoutesAssemblyToolPrefixesToAssemblyViewer() {
        for toolID in ["spades", "spades-2026-05-17", "megahit", "skesa", "flye", "hifiasm"] {
            XCTAssertEqual(AnalysisResultDisplayRoute.route(forToolID: toolID), .assembly)
        }
    }

    func testRoutesKnownMappingToolIDsToMappingViewer() {
        for toolID in ["minimap2", "bwa-mem2", "bowtie2", "bbmap"] {
            XCTAssertEqual(AnalysisResultDisplayRoute.route(forToolID: toolID), .mapping)
        }
    }

    func testRoutesMetagenomicsPrefixesToDedicatedViewers() {
        XCTAssertEqual(AnalysisResultDisplayRoute.route(forToolID: "naomgs-batch"), .naoMgs)
        XCTAssertEqual(AnalysisResultDisplayRoute.route(forToolID: "nvd-run"), .nvd)
        XCTAssertEqual(AnalysisResultDisplayRoute.route(forToolID: "cz-id-import"), .czId)
    }

    func testUnknownToolIDStaysUnknown() {
        XCTAssertEqual(AnalysisResultDisplayRoute.route(forToolID: "mystery-tool"), .unknown)
    }
}

/// Selecting a Viral Recon node has to reach a viewer. Without a route the
/// sidebar renders the node (it is a known tool) and clicking it logs
/// "Unknown analysis type" and shows nothing.
final class AnalysisResultDisplayRouteViralReconTests: XCTestCase {
    func testViralReconToolIDRoutesToItsOwnDisplay() {
        XCTAssertEqual(AnalysisResultDisplayRoute.route(forToolID: "viralrecon"), .viralRecon)
    }

    func testViralReconRouteToleratesSurroundingWhitespace() {
        XCTAssertEqual(AnalysisResultDisplayRoute.route(forToolID: "  viralrecon  "), .viralRecon)
    }

    func testViralReconDoesNotStealTheMappingRoute() {
        XCTAssertEqual(AnalysisResultDisplayRoute.route(forToolID: "minimap2"), .mapping)
    }

    // A batch run's tool ID is what the sidebar hands the router for a
    // multi-sample run, and it must reach the same viewer as a single sample.
    func testViralReconBatchToolIDRoutesToItsOwnDisplay() {
        XCTAssertEqual(AnalysisResultDisplayRoute.route(forToolID: "viralrecon-batch"), .viralRecon)
    }

    // Every tool-ID shape a Viral Recon analysis directory can carry reaches
    // the Viral Recon viewer and is claimed by no other one. Verified by
    // mutation: deleting the route case fails these; note it does NOT pin the
    // check's position above the assembly and mapping prefixes, because no
    // AssemblyTool or MappingTool raw value matches a viralrecon ID today.
    func testEveryViralReconToolIDShapeReachesItsOwnViewer() {
        for toolID in ["viralrecon", "viralrecon-batch", "viralrecon-2026-09-02T10-00-00"] {
            let route = AnalysisResultDisplayRoute.route(forToolID: toolID)
            XCTAssertEqual(route, .viralRecon, "\(toolID) must not be claimed by another viewer")
            XCTAssertNotEqual(route, .assembly)
            XCTAssertNotEqual(route, .mapping)
        }
    }
}
