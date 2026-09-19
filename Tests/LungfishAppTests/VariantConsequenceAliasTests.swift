import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

@MainActor
final class VariantConsequenceAliasTests: XCTestCase {
    private func makeViewer(annotationChromosome: String = "test.1") -> SequenceViewerView {
        let manifest = BundleManifest(
            formatVersion: "1.0", name: "Synthetic", identifier: "synthetic",
            source: SourceInfo(organism: "Synthetic", assembly: "test"),
            genome: GenomeInfo(path: "sequence.fa", indexPath: "sequence.fa.fai", totalLength: 9,
                chromosomes: [ChromosomeInfo(name: "test", length: 9, offset: 0, lineBases: 9, lineWidth: 10, aliases: ["test.1"])])
        )
        let viewer = SequenceViewerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        viewer.setReferenceBundle(ReferenceBundle(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), manifest: manifest))
        viewer.cachedBundleSequence = "ATGAAATTT"
        viewer.cachedSequenceRegion = GenomicRegion(chromosome: "test", start: 0, end: 9)
        viewer.cachedBundleAnnotations = [SequenceAnnotation(type: .cds, name: "Synthetic CDS", chromosome: annotationChromosome, start: 0, end: 9, strand: .forward)]
        return viewer
    }

    func testTableConsequenceResolvesDeclaredChromosomeAlias() {
        let viewer = makeViewer()
        let result = viewer.fallbackConsequenceForTableVariant(chromosome: "test", position: 3, ref: "A", alt: "G")
        XCTAssertEqual(result.consequence, "Synthetic CDS: missense_variant K2E")
        XCTAssertEqual(result.aaChange, "K2E")
    }

    func testHoverConsequenceResolvesSameAlias() {
        let viewer = makeViewer()
        let controller = ViewerViewController()
        controller.referenceFrame = ReferenceFrame(chromosome: "test", start: 0, end: 9, pixelWidth: 800, sequenceLength: 9)
        viewer.viewController = controller
        let site = VariantSite(position: 3, ref: "A", alt: "G", variantType: "SNP", genotypes: ["sample": .homAlt])
        let result = viewer.predictedCDSConsequences(for: site, sampleName: "sample", genotypeData: GenotypeDisplayData(sampleNames: ["sample"], sites: [site], region: GenomicRegion(chromosome: "test", start: 0, end: 9)))
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.joined().contains("K2E"))
    }

    func testHoverDoesNotMixCallersAtSamePosition() {
        let viewer = makeViewer()
        let controller = ViewerViewController()
        controller.referenceFrame = ReferenceFrame(chromosome: "test", start: 0, end: 9, pixelWidth: 800, sequenceLength: 9)
        viewer.viewController = controller
        let other = VariantSite(position: 3, ref: "A", alt: "T", variantType: "SNP", genotypes: ["sample": .homAlt], sourceTrackId: "other")
        let site = VariantSite(position: 3, ref: "A", alt: "G", variantType: "SNP", genotypes: ["sample": .homAlt], sourceTrackId: "selected")
        let result = viewer.predictedCDSConsequences(for: site, sampleName: "sample", genotypeData: GenotypeDisplayData(sampleNames: ["sample"], sites: [other, site], region: GenomicRegion(chromosome: "test", start: 0, end: 9)))
        XCTAssertEqual(result, ["Synthetic CDS: missense_variant K2E"])
    }

    func testInputRefreshInvalidatesHoverAndTableConsequences() {
        let viewer = makeViewer()
        let controller = ViewerViewController()
        viewer.viewController = controller
        let drawer = AnnotationTableDrawerView(frame: .zero)
        controller.annotationDrawerView = drawer
        drawer.fallbackConsequenceCache["stale"] = ("old", "old")
        viewer.lastHoveredGenotypeTooltipText = "old"
        viewer.consequenceInputsDidChange()
        XCTAssertTrue(drawer.fallbackConsequenceCache.isEmpty)
        XCTAssertNil(viewer.lastHoveredGenotypeTooltipText)
    }

    func testGeneAndProteinNamesLabelConsequencesAndHoverDetails() {
        let viewer = makeViewer()
        viewer.cachedBundleAnnotations[0].qualifiers = [
            "gene": AnnotationQualifier("TEST"), "product": AnnotationQualifier("Synthetic protein"),
            "protein_id": AnnotationQualifier("protein-1")
        ]
        let label = "TEST • Synthetic protein • protein-1"
        XCTAssertEqual(viewer.codingFeatureText(chromosome: "test", position: 3, referenceLength: 1), label)
        let effect = viewer.fallbackConsequenceForTableVariant(chromosome: "test", position: 3, ref: "A", alt: "G")
        XCTAssertEqual(effect.consequence, "\(label): missense_variant K2E")
        let row = AnnotationSearchIndex.SearchResult(name: ".", chromosome: "test", start: 3, end: 4, trackId: "calls", type: "SNP", ref: "A", alt: "G")
        XCTAssertTrue(viewer.variantDetailsText(for: row).contains("Gene / Protein: \(label)"))
        XCTAssertNil(viewer.codingFeatureText(chromosome: "other", position: 3, referenceLength: 1))
        XCTAssertNil(viewer.codingFeatureText(chromosome: "test", position: 12, referenceLength: 1))
    }

    func testOverlappingProteinsKeepTheirOwnAminoAcidLabels() {
        let viewer = makeViewer()
        viewer.cachedBundleAnnotations[0].qualifiers = ["gene": AnnotationQualifier("GENE-A"), "protein_id": AnnotationQualifier("protein-a")]
        viewer.cachedBundleAnnotations.append(SequenceAnnotation(type: .cds, name: "Second CDS", chromosome: "test.1", start: 0, end: 9, strand: .forward,
            qualifiers: ["gene": AnnotationQualifier("GENE-B"), "protein_id": AnnotationQualifier("protein-b")]))
        let effect = viewer.fallbackConsequenceForTableVariant(chromosome: "test", position: 3, ref: "A", alt: "G")
        XCTAssertEqual(effect.aaChange, "GENE-A • protein-a: K2E, GENE-B • protein-b: K2E")
    }

    func testGeneProteinColumnUsesReferenceLabelsAndExportsThem() throws {
        let controller = ViewerViewController()
        controller.loadView()
        let fixture = makeViewer()
        controller.viewerView.setReferenceBundle(fixture.currentReferenceBundle!)
        controller.viewerView.cachedBundleAnnotations = fixture.cachedBundleAnnotations
        controller.viewerView.cachedBundleAnnotations[0].qualifiers = ["gene": AnnotationQualifier("TEST"), "protein_id": AnnotationQualifier("protein-1")]
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.delegate = controller
        drawer.activeTab = .variants
        let row = AnnotationSearchIndex.SearchResult(name: ".", chromosome: "test", start: 3, end: 4, trackId: "calls", type: "SNP", ref: "A", alt: "G")
        drawer.displayedAnnotations = [row]
        XCTAssertTrue(AnnotationTableDrawerView.variantColumnDefs.contains { $0.0 == AnnotationTableDrawerView.codingFeatureColumn })
        XCTAssertEqual(drawer.variantCodingFeatureText(for: row), "TEST • protein-1")
        XCTAssertEqual(drawer.cellValueString(for: AnnotationTableDrawerView.codingFeatureColumn, row: 0), "TEST • protein-1")
        let provenanceSources = try controller.annotationDrawerAdditionalExportSources(drawer)
        XCTAssertEqual(Set(provenanceSources.map(\.lastPathComponent)), ["sequence.fa", BundleManifest.filename])
    }

    func testUnrelatedChromosomeDoesNotAcquireConsequence() {
        let viewer = makeViewer(annotationChromosome: "other")
        let result = viewer.fallbackConsequenceForTableVariant(chromosome: "test", position: 3, ref: "A", alt: "G")
        XCTAssertNil(result.consequence)
        XCTAssertNil(result.aaChange)
    }
}
