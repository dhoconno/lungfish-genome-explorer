import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class MappingViewportRoutingTests: XCTestCase {
    func testMainSplitRoutesAllReadMappersThroughMappingViewport() throws {
        let source = try loadSource(at: "Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift")

        XCTAssertTrue(source.contains("displayMappingAnalysisFromSidebar(at: url)"))
        XCTAssertTrue(source.contains("toolId == MappingTool.minimap2.rawValue"))
        XCTAssertTrue(source.contains("toolId == MappingTool.bwaMem2.rawValue"))
        XCTAssertTrue(source.contains("toolId == MappingTool.bowtie2.rawValue"))
        XCTAssertTrue(source.contains("toolId == MappingTool.bbmap.rawValue"))
    }

    func testViewerUsesDedicatedMappingViewportExtension() throws {
        let source = try loadSource(at: "Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift")

        XCTAssertTrue(source.contains("displayMappingResult(_ result: MappingResult)"))
        XCTAssertTrue(source.contains("MappingResultViewController()"))
        XCTAssertTrue(source.contains("contentMode = .mapping"))
        XCTAssertTrue(source.contains("hideMappingView()"))
    }

    func testReferenceBundlesRouteThroughHarmonizedReferenceViewport() throws {
        let mainWindowSource = try loadSource(at: "Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift")
        let viewerMappingSource = try loadSource(at: "Sources/LungfishApp/Views/Viewer/ViewerViewController+Mapping.swift")
        let viewerBundleSource = try loadSource(at: "Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift")

        XCTAssertTrue(mainWindowSource.contains("displayReferenceBundleViewportFromSidebar(at: url)"))
        XCTAssertFalse(mainWindowSource.contains("displayBundle(at: url, mode: .browse)"))
        XCTAssertTrue(viewerMappingSource.contains("displayReferenceBundleViewport("))
        XCTAssertTrue(viewerMappingSource.contains("ReferenceBundleViewportController()"))
        XCTAssertTrue(viewerBundleSource.contains("wireDirectReferenceViewportInspectorUpdates()"))
    }

    func testReferenceBundleRouteClearsInspectorBeforeManifestLoadAndWiresDirectInspectorState() throws {
        let mainWindowSource = try loadSource(at: "Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift")
        let routeStart = try XCTUnwrap(
            mainWindowSource.range(of: "private func displayReferenceBundleViewportFromSidebar")
        )
        let routeEnd = try XCTUnwrap(
            mainWindowSource.range(of: "private func displayAssemblyAnalysisFromSidebar")
        )
        let routeSource = String(mainWindowSource[routeStart.lowerBound..<routeEnd.lowerBound])

        let clearRange = try XCTUnwrap(routeSource.range(of: "self.inspectorController.clearSelection()"))
        let manifestRange = try XCTUnwrap(routeSource.range(of: "let manifest = try BundleManifest.load(from: url)"))

        XCTAssertLessThan(clearRange.lowerBound, manifestRange.lowerBound)
        XCTAssertTrue(routeSource.contains("wireDirectReferenceViewportInspectorUpdates()"))
        XCTAssertTrue(routeSource.contains("updateReferenceBundleTrackSections("))
        XCTAssertTrue(routeSource.contains("notifyEmbeddedReferenceBundleLoadedIfAvailable()"))
    }

    func testMappingAnalysisRouteDisplaysReferenceViewportWithMappingResultInput() throws {
        let mainWindowSource = try loadSource(at: "Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift")
        let routeStart = try XCTUnwrap(
            mainWindowSource.range(of: "private func displayMappingAnalysisFromSidebar")
        )
        let routeEnd = try XCTUnwrap(
            mainWindowSource.range(of: "/// Routes a classifier result directory through the DB router.")
        )
        let routeSource = String(mainWindowSource[routeStart.lowerBound..<routeEnd.lowerBound])

        XCTAssertTrue(routeSource.contains("ReferenceBundleViewportInput.mappingResult("))
        XCTAssertTrue(routeSource.contains("resultDirectoryURL: url"))
        XCTAssertTrue(routeSource.contains("provenance: provenance"))
        XCTAssertTrue(routeSource.contains("try viewerController.displayReferenceBundleViewport(input)"))
        XCTAssertFalse(routeSource.contains("viewerController.displayMappingResult(result, resultDirectoryURL: url)"))
    }

    func testViewerDisplaysDirectBundleViewportWithDirectInput() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Route Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
            ]
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ViewerViewController()
        _ = vc.view

        try vc.displayReferenceBundleViewport(.directBundle(bundleURL: bundleURL, manifest: manifest))

        let controller = try XCTUnwrap(vc.referenceBundleViewportController)
        XCTAssertEqual(controller.currentInput?.kind, .directBundle)
        XCTAssertEqual(controller.currentInput?.renderedBundleURL, bundleURL.standardizedFileURL)
    }

    func testViewerExposesReferenceViewportMappingInputAsActiveMappingViewport() throws {
        let resultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Route Mapping Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
            ]
        )
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: bundleURL,
            bamURL: resultDirectory.appendingPathComponent("sample.sorted.bam"),
            baiURL: resultDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: []
        )
        let vc = ViewerViewController()
        _ = vc.view

        try vc.displayReferenceBundleViewport(
            .mappingResult(result: result, resultDirectoryURL: resultDirectory, provenance: nil)
        )

        XCTAssertEqual(vc.activeMappingViewportController?.currentInput?.kind, .mappingResult)
        XCTAssertEqual(
            vc.activeMappingViewportController?.testFilteredAlignmentServiceTarget,
            .mappingResult(resultDirectory.standardizedFileURL)
        )
    }

    func testBundleBackNavigationButtonUsesStableAccessibilityIdentifier() throws {
        let viewerSource = try loadSource(at: "Sources/LungfishApp/Views/Viewer/ViewerViewController.swift")

        XCTAssertTrue(viewerSource.contains("viewer-back-navigation-button"))
    }

    private func loadSource(at relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

private enum MappingRoutingFixture {
    struct Chromosome {
        let name: String
        let length: Int
    }

    static func makeReferenceBundle(
        name: String,
        chromosomes: [Chromosome]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-routing-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)

        let fasta = chromosomes.map { ">\($0.name)\n\(String(repeating: "A", count: $0.length))\n" }.joined()
        let fastaURL = genomeURL.appendingPathComponent("sequence.fa")
        try fasta.write(to: fastaURL, atomically: true, encoding: .utf8)

        var offset = Int64(0)
        let chromInfos = chromosomes.map { chrom in
            let info = ChromosomeInfo(
                name: chrom.name,
                length: Int64(chrom.length),
                offset: offset,
                lineBases: chrom.length,
                lineWidth: chrom.length + 1
            )
            offset += Int64(">\(chrom.name)\n".utf8.count + chrom.length + 1)
            return info
        }

        let index = zip(chromosomes, chromInfos).map { chrom, info in
            "\(chrom.name)\t\(chrom.length)\t\(info.offset)\t\(chrom.length)\t\(chrom.length + 1)\n"
        }.joined()
        try index.write(to: genomeURL.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)

        let manifest = BundleManifest(
            name: name,
            identifier: "org.lungfish.tests.\(UUID().uuidString)",
            source: SourceInfo(organism: "Test organism", assembly: name),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(chromosomes.reduce(0) { $0 + $1.length }),
                chromosomes: chromInfos
            ),
            annotations: [],
            variants: [],
            tracks: [],
            alignments: [],
            browserSummary: BundleBrowserSummary(
                schemaVersion: 1,
                aggregate: .init(
                    annotationTrackCount: 0,
                    variantTrackCount: 0,
                    alignmentTrackCount: 0,
                    totalMappedReads: nil
                ),
                sequences: chromosomes.map {
                    BundleBrowserSequenceSummary(
                        name: $0.name,
                        displayDescription: nil,
                        length: Int64($0.length),
                        aliases: [],
                        isPrimary: true,
                        isMitochondrial: false,
                        metrics: nil
                    )
                }
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }
}
