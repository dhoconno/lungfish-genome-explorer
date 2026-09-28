import XCTest
@testable import LungfishApp
import LungfishCore

@MainActor
final class MappingInspectorProvenanceTests: XCTestCase {
    private func makeMappingResult(variants: [VariantTrackInfo]) throws -> (result: URL, viewer: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-provenance-\(UUID().uuidString)")
        let resultURL = root.appendingPathComponent("minimap2-2026-09-25T00-00-00")
        let viewerURL = resultURL.appendingPathComponent("GRCh38.lungfishref")
        try FileManager.default.createDirectory(
            at: viewerURL.appendingPathComponent("variants"), withIntermediateDirectories: true)
        let manifest = BundleManifest(
            name: "GRCh38", identifier: "test.grch38",
            source: SourceInfo(organism: "Homo sapiens", assembly: "GRCh38"),
            variants: variants, recordStore: nil)
        try manifest.save(to: viewerURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (resultURL, viewerURL)
    }

    /// The mapping viewport must feed its viewer bundle's variant tracks to the
    /// Provenance Source picker, as the reference-bundle viewer already does.
    func testMappingResultOffersEachVariantTrackAsProvenanceSource() throws {
        let tracks = [
            VariantTrackInfo(id: "a", name: "HG002 bcftools", path: "variants/a.vcf.gz", indexPath: "variants/a.vcf.gz.tbi"),
            VariantTrackInfo(id: "b", name: "HG002 LoFreq", path: "variants/b.vcf.gz", indexPath: "variants/b.vcf.gz.tbi"),
        ]
        let (resultURL, viewerURL) = try makeMappingResult(variants: tracks)
        let inspector = InspectorViewController()
        inspector.updateProvenanceTarget(url: resultURL, sidebarType: .analysisResult, displayName: "minimap2")
        inspector.updateMappingProvenanceSources(resultURL: resultURL, viewerBundleURL: viewerURL)

        let model = inspector.viewModel.provenanceSectionViewModel
        XCTAssertEqual(model.sources.map(\.name), ["Mapping", "HG002 bcftools", "HG002 LoFreq"])
        model.selectSource(id: model.sources[1].id)
        XCTAssertEqual(model.currentItem?.url?.standardizedFileURL,
                       viewerURL.appendingPathComponent("variants/a.vcf.gz").standardizedFileURL)
        model.selectSource(id: model.sources[0].id)
        XCTAssertEqual(model.currentItem?.url?.standardizedFileURL, resultURL.standardizedFileURL)
        model.clear()
    }

    func testMappingResultWithoutVariantTracksShowsNoPicker() throws {
        let (resultURL, viewerURL) = try makeMappingResult(variants: [])
        let inspector = InspectorViewController()
        inspector.updateProvenanceTarget(url: resultURL, sidebarType: .analysisResult, displayName: "minimap2")
        inspector.updateMappingProvenanceSources(resultURL: resultURL, viewerBundleURL: viewerURL)
        XCTAssertLessThanOrEqual(inspector.viewModel.provenanceSectionViewModel.sources.count, 1)
        inspector.viewModel.provenanceSectionViewModel.clear()
    }
}
