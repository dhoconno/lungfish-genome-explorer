import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit

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

    /// First selection after opening a project changes the viewport content
    /// mode (empty -> mapping) after the display path has already offered the
    /// variant tracks. The mode change re-resolves the provenance target and
    /// must keep the Source picker (Preview 2026.9.57 click-test defect).
    func testContentModeChangeAfterFirstSelectionKeepsSourcePicker() throws {
        let tracks = [
            VariantTrackInfo(id: "a", name: "HG002 bcftools", path: "variants/a.vcf.gz", indexPath: "variants/a.vcf.gz.tbi"),
        ]
        let (resultURL, viewerURL) = try makeMappingResult(variants: tracks)
        let inspector = InspectorViewController()
        let scope = WindowStateScope()
        inspector.testingWindowStateScope = scope
        inspector.updateProvenanceTarget(url: resultURL, sidebarType: .analysisResult, displayName: "minimap2")
        inspector.updateMappingProvenanceSources(resultURL: resultURL, viewerBundleURL: viewerURL)

        inspector.handleContentModeChanged(Notification(
            name: .viewportContentModeDidChange,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.contentMode: ViewportContentMode.mapping.rawValue,
                NotificationUserInfoKey.windowStateScope: scope,
            ]
        ))

        let model = inspector.viewModel.provenanceSectionViewModel
        XCTAssertEqual(model.sources.map(\.name), ["Mapping", "HG002 bcftools"])
        XCTAssertEqual(model.selectedSourceID, resultURL.standardizedFileURL.path)
        XCTAssertEqual(model.currentItem?.contentMode, .mapping)
        XCTAssertEqual(model.sources.first?.item.contentMode, .mapping)
        model.clear()
    }

    /// A late sidebar selection notification for the same mapping result
    /// re-targets provenance without dropping the Source picker.
    func testSidebarReselectionOfSameResultKeepsSourcePicker() throws {
        let tracks = [
            VariantTrackInfo(id: "a", name: "HG002 bcftools", path: "variants/a.vcf.gz", indexPath: "variants/a.vcf.gz.tbi"),
        ]
        let (resultURL, viewerURL) = try makeMappingResult(variants: tracks)
        let inspector = InspectorViewController()
        inspector.updateProvenanceTarget(url: resultURL, sidebarType: .analysisResult, displayName: "minimap2")
        inspector.updateMappingProvenanceSources(resultURL: resultURL, viewerBundleURL: viewerURL)

        inspector.retargetProvenancePreservingSources(
            url: resultURL, sidebarType: .analysisResult, displayName: "minimap2"
        )
        let model = inspector.viewModel.provenanceSectionViewModel
        XCTAssertEqual(model.sources.map(\.name), ["Mapping", "HG002 bcftools"])

        // A different item drops the picker.
        let other = resultURL.deletingLastPathComponent().appendingPathComponent("README.md")
        inspector.retargetProvenancePreservingSources(url: other, sidebarType: nil, displayName: "README")
        XCTAssertTrue(model.sources.isEmpty)
        model.clear()
    }
}
