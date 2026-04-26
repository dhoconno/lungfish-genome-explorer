import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

final class ReferenceBundleViewportInputTests: XCTestCase {
    func testDirectBundleInputBuildsDocumentTitleFromManifestAndHasNoMappingContext() throws {
        let bundleURL = URL(fileURLWithPath: "/tmp/reference.lungfishref", isDirectory: true)
        let manifest = BundleManifest(
            name: "SARS-CoV-2 Reference",
            identifier: "org.lungfish.test.reference",
            source: SourceInfo(organism: "SARS-CoV-2", assembly: "Reference"),
            genome: nil
        )

        let input = ReferenceBundleViewportInput.directBundle(
            bundleURL: bundleURL,
            manifest: manifest
        )

        XCTAssertEqual(input.renderedBundleURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(input.documentTitle, "SARS-CoV-2 Reference")
        XCTAssertNil(input.mappingResult)
        XCTAssertNil(input.mappingResultDirectoryURL)
        XCTAssertFalse(input.hasMappingRunContext)
    }

    func testMappingInputUsesViewerBundleAndKeepsResultDirectoryContext() throws {
        let resultDirectory = URL(fileURLWithPath: "/tmp/project/Analyses/minimap2-run", isDirectory: true)
        let viewerBundle = resultDirectory.appendingPathComponent("viewer.lungfishref", isDirectory: true)
        let bam = resultDirectory.appendingPathComponent("sample.sorted.bam")
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: viewerBundle,
            bamURL: bam,
            baiURL: resultDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: []
        )

        let input = ReferenceBundleViewportInput.mappingResult(
            result: result,
            resultDirectoryURL: resultDirectory,
            provenance: nil as MappingProvenance?
        )

        XCTAssertEqual(input.renderedBundleURL, viewerBundle.standardizedFileURL)
        XCTAssertEqual(input.mappingResultDirectoryURL, resultDirectory.standardizedFileURL)
        XCTAssertTrue(input.hasMappingRunContext)
    }
}
