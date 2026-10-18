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

    func testMappingInputWithoutViewerBundlePreservesUnavailableRenderableBundleState() throws {
        let resultDirectory = URL(fileURLWithPath: "/tmp/project/Analyses/minimap2-run", isDirectory: true)
        let bam = resultDirectory.appendingPathComponent("sample.sorted.bam")
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: nil,
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

        XCTAssertNil(input.renderedBundleURL)
        XCTAssertEqual(input.documentTitle, "minimap2-run")
        XCTAssertEqual(input.mappingResult, result)
        XCTAssertEqual(input.mappingResultDirectoryURL, resultDirectory.standardizedFileURL)
        XCTAssertTrue(input.hasMappingRunContext)
    }

    // MARK: - Identity compare

    /// Two inputs show the same document when they name the same files at the same saved version. The
    /// compare skips the per-sequence arrays on purpose, since a large reference lists hundreds of
    /// thousands of sequences, so these tests pin what it keeps and what it leaves out.
    func testInputsOfTheSameVersionAreEqualWhateverTheirSequenceArraysHold() {
        let relisted = mappingInput(
            result(contigs: [contig("chr1"), contig("chr2")]),
            viewer: manifest(chromosomeNames: ["a", "b"]),
            modified: stamp
        )
        XCTAssertEqual(
            mappingInput(result(contigs: []), viewer: manifest(chromosomeNames: ["chr1", "chr2"]), modified: stamp),
            relisted,
            "the same files at the same saved version, with other contigs and sequence names"
        )

        XCTAssertEqual(
            ReferenceBundleViewportInput.directBundle(
                bundleURL: referenceBundle, manifest: manifest(chromosomeNames: ["chr1", "chr2"])
            ),
            ReferenceBundleViewportInput.directBundle(
                bundleURL: referenceBundle, manifest: manifest(chromosomeNames: ["x", "y"])
            ),
            "a direct bundle with the same number of sequences under other names"
        )
    }

    func testInputsDifferWhenTheirFilesDiffer() {
        let direct = ReferenceBundleViewportInput.directBundle(bundleURL: referenceBundle, manifest: manifest())
        XCTAssertNotEqual(
            direct,
            ReferenceBundleViewportInput.directBundle(
                bundleURL: URL(fileURLWithPath: "/tmp/other.lungfishref", isDirectory: true), manifest: manifest()
            ),
            "the bundle URL"
        )

        let mapped = mappingInput(result(), viewer: manifest(), modified: stamp)
        XCTAssertNotEqual(
            mapped,
            ReferenceBundleViewportInput.mappingResult(
                result: result(),
                resultDirectoryURL: URL(fileURLWithPath: "/tmp/project/Analyses/other-run", isDirectory: true),
                provenance: nil as MappingProvenance?,
                viewerBundleManifest: manifest(),
                resultModificationDate: stamp
            ),
            "the result folder"
        )
        XCTAssertNotEqual(direct, mapped, "a direct bundle and a mapping result")
    }

    func testMappingInputsDifferWhenTheSavedResultDateDiffers() {
        let saved = mappingInput(result(), modified: stamp)
        XCTAssertEqual(saved, mappingInput(result(), modified: stamp))
        XCTAssertNotEqual(saved, mappingInput(result(), modified: stamp.addingTimeInterval(1)), "a later save")
        XCTAssertNotEqual(saved, mappingInput(result(), modified: nil), "a saved result against one with no date")
        XCTAssertNotEqual(mappingInput(result(), modified: nil), saved, "one with no date against a saved result")
    }

    func testInMemoryMappingResultsCompareTheirValue() {
        XCTAssertEqual(mappingInput(result()), mappingInput(result()))
        XCTAssertNotEqual(mappingInput(result()), mappingInput(result(mappedReads: 8)), "other read counts")
        XCTAssertNotEqual(mappingInput(result()), mappingInput(result(contigs: [contig("chr1")])), "other contigs")
    }

    /// Each change below keeps the modification date, so only the field itself can tell the inputs apart.
    func testInputsDifferWhenTheirManifestsDifferInIdentityTracksOrSequenceCount() {
        func direct(_ manifest: BundleManifest) -> ReferenceBundleViewportInput {
            .directBundle(bundleURL: referenceBundle, manifest: manifest)
        }
        let base = direct(manifest())
        XCTAssertEqual(base, direct(manifest()), "the same manifest values")
        XCTAssertNotEqual(base, direct(manifest(identifier: "org.lungfish.test.other")), "identifier")
        XCTAssertNotEqual(base, direct(manifest(name: "Renamed")), "name")
        XCTAssertNotEqual(base, direct(manifest(chromosomeNames: ["chr1", "chr2", "chr3"])), "sequence count")
        XCTAssertNotEqual(base, direct(manifest(annotations: [annotationTrack])), "one more annotation track")
        XCTAssertNotEqual(base, direct(manifest(variants: [variantTrack])), "one more variant track")
        XCTAssertNotEqual(base, direct(manifest(alignments: [alignmentTrack])), "one more alignment track")
        XCTAssertNotEqual(base, direct(manifest(modifiedDate: stamp.addingTimeInterval(60))), "modification date")

        // The viewer manifest of a mapping result counts the same way.
        let mapped = mappingInput(result(), viewer: manifest(), modified: stamp)
        XCTAssertEqual(mapped, mappingInput(result(), viewer: manifest(), modified: stamp))
        XCTAssertNotEqual(
            mapped,
            mappingInput(result(), viewer: manifest(alignments: [alignmentTrack]), modified: stamp),
            "one more alignment track in the viewer manifest"
        )
        XCTAssertNotEqual(
            mapped,
            mappingInput(result(), viewer: manifest(identifier: "org.lungfish.test.other"), modified: stamp),
            "another identifier in the viewer manifest"
        )
        XCTAssertNotEqual(mapped, mappingInput(result(), viewer: nil, modified: stamp), "no viewer manifest")
    }

    // MARK: - Fixtures

    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    private let referenceBundle = URL(fileURLWithPath: "/tmp/reference.lungfishref", isDirectory: true)
    private let resultDirectory = URL(fileURLWithPath: "/tmp/project/Analyses/minimap2-run", isDirectory: true)
    private let annotationTrack = AnnotationTrackInfo(id: "genes", name: "Genes", path: "annotations/genes.bb")
    private let variantTrack = VariantTrackInfo(
        id: "calls", name: "Calls", path: "variants/calls.vcf.gz", indexPath: "variants/calls.vcf.gz.tbi"
    )
    private let alignmentTrack = AlignmentTrackInfo(
        id: "reads", name: "Reads", sourcePath: "alignments/reads.bam", indexPath: "alignments/reads.bam.bai",
        metadataDBPath: "alignments/reads.metadata.sqlite", mappedReadCount: 1, unmappedReadCount: 0, sampleNames: []
    )

    private func manifest(
        name: String = "Reference",
        identifier: String = "org.lungfish.test.identity",
        modifiedDate: Date? = nil,
        chromosomeNames: [String] = ["chr1", "chr2"],
        annotations: [AnnotationTrackInfo] = [],
        variants: [VariantTrackInfo] = [],
        alignments: [AlignmentTrackInfo] = []
    ) -> BundleManifest {
        let chromosomes = chromosomeNames.enumerated().map { position, chromosomeName in
            ChromosomeInfo(
                name: chromosomeName, length: 100, offset: Int64(position) * 108, lineBases: 100, lineWidth: 101
            )
        }
        return BundleManifest(
            name: name,
            identifier: identifier,
            createdDate: stamp,
            modifiedDate: modifiedDate ?? stamp,
            source: SourceInfo(organism: "Test organism", assembly: "Reference"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(100 * chromosomeNames.count),
                chromosomes: chromosomes
            ),
            annotations: annotations,
            variants: variants,
            alignments: alignments
        )
    }

    private func contig(_ name: String) -> MappingContigSummary {
        MappingContigSummary(
            contigName: name, contigLength: 100, mappedReads: 1, mappedReadPercent: 10,
            meanDepth: 1, coverageBreadth: 1, medianMAPQ: 60, meanIdentity: 1
        )
    }

    private func result(contigs: [MappingContigSummary] = [], mappedReads: Int = 9) -> MappingResult {
        MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: resultDirectory.appendingPathComponent("viewer.lungfishref", isDirectory: true),
            bamURL: resultDirectory.appendingPathComponent("sample.sorted.bam"),
            baiURL: resultDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 10,
            mappedReads: mappedReads,
            unmappedReads: 10 - mappedReads,
            wallClockSeconds: 1.0,
            contigs: contigs
        )
    }

    private func mappingInput(
        _ result: MappingResult,
        viewer: BundleManifest? = nil,
        modified: Date? = nil
    ) -> ReferenceBundleViewportInput {
        ReferenceBundleViewportInput.mappingResult(
            result: result,
            resultDirectoryURL: resultDirectory,
            provenance: nil as MappingProvenance?,
            viewerBundleManifest: viewer,
            resultModificationDate: modified
        )
    }
}
