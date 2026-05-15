import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

@MainActor
final class ReferenceBundleViewportControllerTests: XCTestCase {
    func testDirectReferenceBundleShowsSequenceListAndLoadsFirstSequenceDetail() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
                .init(name: "chr2", length: 200),
            ],
            includeAlignment: false,
            includeVariant: false
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))

        XCTAssertEqual(vc.testDisplayedSequenceNames, ["chr1", "chr2"])
        XCTAssertEqual(vc.testSelectedSequenceName, "chr1")
        XCTAssertFalse(vc.testEmbeddedViewerShowsReferenceViewport)
        XCTAssertEqual(vc.testPresentationMode, .listDetail)
    }

    func testReloadViewerBundleForInspectorChangesPreservesSelectedSequence() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
                .init(name: "chr2", length: 200),
            ],
            includeAlignment: false,
            includeVariant: false
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))
        vc.testSelectSequence(named: "chr2")

        XCTAssertEqual(vc.testSelectedSequenceName, "chr2")

        try vc.reloadViewerBundleForInspectorChanges()

        XCTAssertEqual(vc.testSelectedSequenceName, "chr2")
    }

    func testDirectReferenceBundleSequenceOperationContextUsesSelectedEmbeddedSequence() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
                .init(name: "chr2", length: 200),
            ],
            includeAlignment: false,
            includeVariant: false
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))
        vc.testSelectSequence(named: "chr2")

        let context = try XCTUnwrap(vc.testCurrentSequenceAnnotationOperationContext)
        XCTAssertEqual(context.bundleURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(context.chromosome, "chr2")
        XCTAssertEqual(context.range, 0..<200)
        XCTAssertEqual(context.sequenceLength, 200)
    }

    func testFilteringSequenceRowsSelectsFirstVisibleSequenceAndClearsWhenEmpty() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
                .init(name: "chr2", length: 200),
            ],
            includeAlignment: false,
            includeVariant: false
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))

        vc.testApplySequenceFilter("chr2")

        XCTAssertEqual(vc.testDisplayedSequenceNames, ["chr2"])
        XCTAssertEqual(vc.testSelectedSequenceName, "chr2")

        vc.testApplySequenceFilter("missing")

        XCTAssertEqual(vc.testDisplayedSequenceNames, [])
        XCTAssertNil(vc.testSelectedSequenceName)
        XCTAssertEqual(vc.testDetailPlaceholderMessage, "No sequences are available for this reference bundle.")
    }

    func testFocusModeUsesVisibleBackButtonAndRestoresListDetailSelection() throws {
        let bundleURL = try ReferenceViewportFixture.makeReferenceBundle(
            name: "Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
                .init(name: "chr2", length: 200),
            ],
            includeAlignment: false,
            includeVariant: false
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ReferenceBundleViewportController()
        _ = vc.view

        try vc.configureForTesting(input: .directBundle(bundleURL: bundleURL, manifest: manifest))
        vc.testSelectSequence(named: "chr2")

        vc.testEnterFocusedDetailMode()

        XCTAssertEqual(vc.testPresentationMode, .focusedDetail)
        XCTAssertEqual(vc.testBackButtonAccessibilityIdentifier, "reference-viewport-back-button")
        XCTAssertFalse(vc.testBackButtonIsHidden)
        XCTAssertEqual(vc.testSelectedSequenceName, "chr2")

        vc.testTapBackButton()

        XCTAssertEqual(vc.testPresentationMode, .listDetail)
        XCTAssertEqual(vc.testSelectedSequenceName, "chr2")
        XCTAssertFalse(vc.testListContainer.isHidden)
    }
}

private enum ReferenceViewportFixture {
    struct Chromosome {
        let name: String
        let length: Int
    }

    static func makeReferenceBundle(
        name: String,
        chromosomes: [Chromosome],
        includeAlignment: Bool,
        includeVariant: Bool
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-viewport-\(UUID().uuidString)", isDirectory: true)
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

        let indexURL = genomeURL.appendingPathComponent("sequence.fa.fai")
        let index = zip(chromosomes, chromInfos).map { chrom, info in
            "\(chrom.name)\t\(chrom.length)\t\(info.offset)\t\(chrom.length)\t\(chrom.length + 1)\n"
        }.joined()
        try index.write(to: indexURL, atomically: true, encoding: .utf8)

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
                    variantTrackCount: includeVariant ? 1 : 0,
                    alignmentTrackCount: includeAlignment ? 1 : 0,
                    totalMappedReads: includeAlignment ? 10 : nil
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
