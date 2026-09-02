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
}
