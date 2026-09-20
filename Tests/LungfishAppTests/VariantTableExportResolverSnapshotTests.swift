import XCTest
import LungfishCore
import LungfishWorkflow
@testable import LungfishApp

final class VariantTableExportResolverSnapshotTests: XCTestCase {
    func testFrozenResolverDerivesCodingFeatureConsequenceAndAAChange() {
        let snapshot = VariantTableExportResolverSnapshot(
            features: [
                .init(
                    chromosome: "chr1",
                    intervals: [.init(start: 100, end: 103)],
                    label: "N • nucleocapsid • YP_009724397.2",
                    isReverse: false,
                    codingBases: Array("ATG"),
                    codingGenomePositions: [100, 101, 102],
                    phaseOffset: 0,
                    codonTable: .standard
                )
            ],
            variantChromosomeAliasMap: [:]
        )
        let row = makeRow(chromosome: "chr1", position: 101, ref: "T", alt: "C")

        let resolved = snapshot.resolve(row)

        XCTAssertEqual(resolved.codingFeature, "N • nucleocapsid • YP_009724397.2")
        XCTAssertEqual(resolved.consequence, "N • nucleocapsid • YP_009724397.2: missense_variant M1T")
        XCTAssertEqual(resolved.aaChange, "M1T")
    }

    func testRecordedInfoWinsWhileCodingFeatureUsesReferenceAlias() {
        let snapshot = VariantTableExportResolverSnapshot(
            features: [
                .init(
                    chromosome: "NC_045512.2",
                    intervals: [.init(start: 100, end: 103)],
                    label: "N • nucleocapsid",
                    isReverse: false,
                    codingBases: Array("ATG"),
                    codingGenomePositions: [100, 101, 102],
                    phaseOffset: 0,
                    codonTable: .standard
                )
            ],
            variantChromosomeAliasMap: ["NC_045512.2": "MN908947.3"]
        )
        let row = makeRow(
            chromosome: "MN908947.3", position: 101, ref: "T", alt: "C",
            info: ["Consequence": "recorded_effect", "HGVSp": "p.Recorded"]
        )

        let resolved = snapshot.resolve(row)

        XCTAssertEqual(resolved.codingFeature, "N • nucleocapsid")
        XCTAssertEqual(resolved.consequence, "recorded_effect")
        XCTAssertEqual(resolved.aaChange, "p.Recorded")
    }

    @MainActor
    func testAllMatchingExportUsesSameDerivedAndCallerFieldsAsTheDisplayedRow() {
        let snapshot = VariantTableExportResolverSnapshot(
            features: [
                .init(
                    chromosome: "chr1",
                    intervals: [.init(start: 100, end: 103)],
                    label: "N • nucleocapsid • YP_009724397.2",
                    isReverse: false,
                    codingBases: Array("ATG"),
                    codingGenomePositions: [100, 101, 102],
                    phaseOffset: 0,
                    codonTable: .standard
                )
            ],
            variantChromosomeAliasMap: [:]
        )
        // An iVar-style row without CSQ/ANN INFO exercises the local CDS fallback.
        let row = makeRow(chromosome: "chr1", position: 101, ref: "T", alt: "C")
        let columns = [
            ScientificTableColumn(id: AnnotationTableDrawerView.callerSettingsColumn.rawValue, title: "Caller Settings"),
            ScientificTableColumn(id: AnnotationTableDrawerView.codingFeatureColumn.rawValue, title: "Gene / Protein"),
            ScientificTableColumn(id: AnnotationTableDrawerView.consequenceColumn.rawValue, title: "Consequence"),
            ScientificTableColumn(id: AnnotationTableDrawerView.aaChangeColumn.rawValue, title: "AA Change"),
        ]

        let allMatching = AnnotationTableDrawerView.backgroundVariantResolvedText(
            rows: [row], columns: columns,
            callerSettingsByTrack: ["variants": "Caller: iVar; Minimum depth: 10"],
            resolverSnapshot: snapshot
        )["variants:1"]

        XCTAssertEqual(allMatching?[AnnotationTableDrawerView.callerSettingsColumn.rawValue], "Caller: iVar; Minimum depth: 10")
        XCTAssertEqual(allMatching?[AnnotationTableDrawerView.codingFeatureColumn.rawValue], tableVariantColumnValue(
            row: row, key: "coding_feature", resolverSnapshot: snapshot
        ))
        XCTAssertEqual(allMatching?[AnnotationTableDrawerView.consequenceColumn.rawValue], tableVariantColumnValue(
            row: row, key: "consequence", resolverSnapshot: snapshot
        ))
        XCTAssertEqual(allMatching?[AnnotationTableDrawerView.aaChangeColumn.rawValue], tableVariantColumnValue(
            row: row, key: "aa_change", resolverSnapshot: snapshot
        ))
    }

    func testBackgroundPreparationBuildsMissingContextFromFrozenSequenceWindow() {
        let snapshot = VariantTableExportResolverSnapshot(
            features: [
                .init(
                    chromosome: "chr1", intervals: [.init(start: 100, end: 103)],
                    label: "N", isReverse: false, codingBases: nil,
                    codingGenomePositions: nil, phaseOffset: 0, codonTable: .standard
                )
            ],
            variantChromosomeAliasMap: [:],
            cachedSequence: "ATG",
            cachedSequenceRegion: GenomicRegion(chromosome: "chr1", start: 100, end: 103)
        )

        let prepared = try! snapshot.preparingForBackgroundExport()
        let resolved = prepared.resolve(makeRow(chromosome: "chr1", position: 101, ref: "T", alt: "C"))

        XCTAssertEqual(resolved.consequence, "N: missense_variant M1T")
        XCTAssertEqual(resolved.aaChange, "M1T")
    }

    func testBackgroundPreparationNeverBuildsFromPartialCDSIntervals() throws {
        let snapshot = VariantTableExportResolverSnapshot(
            features: [
                .init(
                    chromosome: "chr1",
                    intervals: [.init(start: 100, end: 103), .init(start: 200, end: 203)],
                    label: "split-CDS", isReverse: false, codingBases: nil,
                    codingGenomePositions: nil, phaseOffset: 0, codonTable: .standard
                )
            ],
            variantChromosomeAliasMap: [:], cachedSequence: "ATG",
            cachedSequenceRegion: GenomicRegion(chromosome: "chr1", start: 100, end: 103)
        )

        let prepared = try snapshot.preparingForBackgroundExport()
        let resolved = prepared.resolve(makeRow(chromosome: "chr1", position: 101, ref: "T", alt: "C"))

        XCTAssertNil(prepared.features[0].codingBases)
        XCTAssertEqual(resolved.codingFeature, "split-CDS")
        XCTAssertEqual(resolved.consequence, "")
        XCTAssertEqual(resolved.aaChange, "")
    }

    func testBackgroundPreparationHonorsCancellation() {
        let snapshot = VariantTableExportResolverSnapshot(
            features: [
                .init(
                    chromosome: "chr1", intervals: [.init(start: 100, end: 103)],
                    label: "N", isReverse: false, codingBases: nil,
                    codingGenomePositions: nil, phaseOffset: 0, codonTable: .standard
                )
            ],
            variantChromosomeAliasMap: [:]
        )

        XCTAssertThrowsError(try snapshot.preparingForBackgroundExport(shouldCancel: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testResolverTypesAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(VariantTableExportResolverSnapshot.self)
        requireSendable(VariantTableExportResolvedFields.self)
    }

    private func makeRow(
        chromosome: String,
        position: Int,
        ref: String,
        alt: String,
        info: [String: String] = [:]
    ) -> AnnotationSearchIndex.SearchResult {
        AnnotationSearchIndex.SearchResult(
            name: "variant", chromosome: chromosome, start: position, end: position + ref.count,
            trackId: "variants", type: "SNP", strand: ".", ref: ref, alt: alt,
            variantRowId: 1, infoDict: info
        )
    }
}
