import AppKit
import XCTest
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishTestSupport

@MainActor
final class GenotypeMatrixHaplotypeSupportTests: GenotypeResultViewportTestCase {
    private let first = "Mafa-A1*101:01"
    private let second = "Mafa-A1*102:01"
    private let shared = "Mafa-A1*103:01"
    private let other = "Mafa-A1*104:01"

    private func fixture() -> (GenotypeComparisonMatrixView, [ONTGenotypeCall], GenotypeHaplotypeDefinitionSet) {
        let calls = [
            makeCall(sample: "AnimalA", genotype: first, reads: 12),
            makeCall(sample: "AnimalB", genotype: first, reads: 9),
            makeCall(sample: "AnimalA", genotype: second, reads: 8),
            makeCall(sample: "AnimalA", genotype: shared, reads: 5),
            makeCall(sample: "AnimalA", genotype: other, reads: 3),
        ]
        // Custom names/palette deliberately avoid MCM-specific assumptions.
        let definitions = GenotypeHaplotypeDefinitionSet(
            id: "custom", assayID: "custom-assay", displayName: "Custom", speciesName: "Test",
            speciesCode: "Test", prefix: "Mafa", locusDefinitions: [
                .init(locus: "MHC-A", sourceLocus: "Mafa-A", haplotypes: [
                    .init(name: "North", diagnosticAlleles: [first, shared], colorOverride: AnnotationColor(red: 0, green: 0, blue: 0)),
                    .init(name: "South", diagnosticAlleles: [second, shared], colorOverride: AnnotationColor(red: 0, green: 0, blue: 1)),
                ]),
            ])
        let matrix = GenotypeComparisonMatrixView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        matrix.configure(result: GenotypeTestFixtures.makeResult(calls: calls))
        matrix.configureHaplotypeEvidence(.init(calls: calls, definitionSet: definitions, effectiveCalls: [
            .init(sample: "AnimalA", locus: "MHC-A", haplotypeNames: ["North", "South"]),
            .init(sample: "AnimalB", locus: "MHC-A", haplotypeNames: []),
        ]))
        return (matrix, calls, definitions)
    }

    func testVisibleColumnsMenuTracksHeaderVisibilityIncludingReadTotals() throws {
        let (matrix, _, _) = fixture()
        let button = try XCTUnwrap(descendants(of: matrix).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityIdentifier() == "genotype-matrix-columns"
        })
        XCTAssertFalse(button.isHidden)
        matrix.testingSetStandardColumnVisibleWithoutPersist("uniqueReads", visible: true)
        XCTAssertEqual(button.menu?.items.first { $0.title == "Total reads" }?.state, .on)
        XCTAssertTrue(matrix.testingPinnedColumnTitles.contains("Total reads"))
        matrix.testingSetStandardColumnVisibleWithoutPersist("uniqueReads", visible: false)
        XCTAssertEqual(button.menu?.items.first { $0.title == "Total reads" }?.state, .off)
        XCTAssertFalse(matrix.testingPinnedColumnTitles.contains("Total reads"))
    }

    func testCompleteLegendIncludesEveryHaplotypeAndLocusBeyondCompactLimit() throws {
        let (matrix, calls, _) = fixture()
        let names = (1...9).map { "Family \($0)" }
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "large-legend", assayID: "test", displayName: "Large", speciesName: "Test",
            speciesCode: "TEST", prefix: "", locusDefinitions: [
                .init(locus: "MHC-A", sourceLocus: "Mafa-A", haplotypes: names.map {
                    .init(name: $0, diagnosticAlleles: [], colorOverride: AnnotationColor(red: 0, green: 0, blue: 0))
                }),
                .init(locus: "MHC-B", sourceLocus: "Mafa-B", haplotypes: [
                    .init(name: "Family 1", diagnosticAlleles: [], colorOverride: AnnotationColor(red: 0, green: 0, blue: 0)),
                ]),
            ])
        matrix.configureHaplotypeEvidence(.init(calls: calls, definitionSet: definition, effectiveCalls: []))
        let legend = matrix.haplotypeLegendContent()
        for name in names { XCTAssertTrue(legend.string.contains(name)) }
        XCTAssertTrue(legend.string.contains("MHC-A"))
        XCTAssertTrue(legend.string.contains("MHC-B"))
        XCTAssertTrue(legend.string.contains("Shared support: gray"))
        let range = (legend.string as NSString).range(of: "Family 9")
        let color = try XCTUnwrap(legend.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(color.usingColorSpace(.deviceRGB)?.redComponent ?? 0, 1, accuracy: 0.01)
        var state = GenotypeResultDisplayState()
        state.cellColorMode = .haplotype
        matrix.applyDisplayState(state)
        let button = try XCTUnwrap(descendants(of: matrix).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "genotype-matrix-haplotype-legend-button"
        })
        XCTAssertFalse(button.isHidden)
        XCTAssertNotNil(button.action)
        state.cellColorMode = .support
        matrix.applyDisplayState(state)
        XCTAssertTrue(button.isHidden)
    }

    func testCustomHaplotypeColorsAreReadableAndSharedSupportIsExplicit() throws {
        let (matrix, _, _) = fixture()
        var state = GenotypeResultDisplayState()
        state.cellColorMode = .haplotype
        matrix.applyDisplayState(state)
        let firstStyle = try XCTUnwrap(matrix.testingRenderedStyle(genotype: first, sample: "AnimalA"))
        XCTAssertEqual(firstStyle.fillColor, AnnotationColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(firstStyle.textColor, AnnotationColor(red: 1, green: 1, blue: 1))
        let secondStyle = try XCTUnwrap(matrix.testingRenderedStyle(genotype: second, sample: "AnimalA"))
        XCTAssertEqual(secondStyle.fillColor, AnnotationColor(red: 0, green: 0, blue: 1))
        XCTAssertEqual(secondStyle.textColor, AnnotationColor(red: 1, green: 1, blue: 1))
        let sharedStyle = try XCTUnwrap(matrix.testingRenderedStyle(genotype: shared, sample: "AnimalA"))
        XCTAssertEqual(sharedStyle.fillColor, AnnotationColor(red: 0.85, green: 0.85, blue: 0.85))
        XCTAssertTrue(matrix.testingCellToolTip(genotype: shared, sample: "AnimalA")?.contains("shared support") == true)
        XCTAssertTrue(matrix.testingCellToolTip(genotype: shared, sample: "AnimalA")?.contains("North") == true)
        XCTAssertTrue(matrix.testingCellToolTip(genotype: shared, sample: "AnimalA")?.contains("South") == true)
        XCTAssertNil(matrix.testingRenderedStyle(genotype: other, sample: "AnimalA")?.fillColor)
        XCTAssertNil(matrix.testingRenderedStyle(genotype: first, sample: "AnimalB")?.fillColor)
    }

    func testDiagnosticFilterRetainsUnresolvedSampleEvidenceAndCanShowAllAgain() {
        let (matrix, _, _) = fixture()
        var state = GenotypeResultDisplayState()
        state.diagnosticAllelesOnly = true
        matrix.applyDisplayState(state)
        XCTAssertEqual(Set(matrix.testingVisibleRows.map(\.genotype)), [first, second, shared])
        XCTAssertEqual(matrix.testingCellValue(genotype: first, sample: "AnimalB"), "9")
        state.diagnosticAllelesOnly = false
        matrix.applyDisplayState(state)
        XCTAssertEqual(Set(matrix.testingVisibleRows.map(\.genotype)), [first, second, shared, other])
    }

    func testReadSumAndDiagnosticColorSettingsReachViewportExport() throws {
        let (matrix, _, _) = fixture()
        matrix.testingSetStandardColumnVisibleWithoutPersist("uniqueReads", visible: true)
        var state = GenotypeResultDisplayState()
        state.diagnosticAllelesOnly = true
        state.cellColorMode = .haplotype
        matrix.applyDisplayState(state)
        let snapshot = matrix.exportSnapshot(bundleURL: URL(fileURLWithPath: "/tmp/test.lungfishgenotype"), analysisName: "test", lens: "matrix")
        XCTAssertTrue(matrix.testingPinnedColumnTitles.contains("Total reads"))
        XCTAssertEqual(snapshot.filters["includeTotalReads"], "true")
        XCTAssertEqual(snapshot.filters["diagnosticAllelesOnly"], "true")
        XCTAssertEqual(snapshot.rows.first { $0.genotype == first }?.totalUniqueReads, 21)
        XCTAssertFalse(snapshot.rows.contains { $0.genotype == other })
        let style = try XCTUnwrap(snapshot.rows.first { $0.genotype == first }?.cellStyles["AnimalA"])
        XCTAssertEqual(style.fillColor, AnnotationColor(red: 0, green: 0, blue: 0))
    }

    func testAllAndFilteredExportShareNativeExplicitCellStyleColorSpace() throws {
        let (matrix, _, _) = fixture()
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-09-12T00:00:00Z")
        sidecar.matrixStyles = [.init(target: .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            style: .init(fillColor: "#123456", textColor: "#ABCDEF", borderColor: "#654321", isBold: true, isItalic: true),
            author: "Analyst", timestamp: "2026-09-12T00:00:00Z")]
        matrix.applyAnnotationSidecar(sidecar)
        var state = GenotypeResultDisplayState()
        state.cellColorMode = .highlights
        matrix.applyDisplayState(state)
        let filtered = matrix.exportSnapshot(bundleURL: URL(fileURLWithPath: "/tmp/style"), analysisName: "test", lens: "matrix")
        let all = matrix.exportSnapshot(bundleURL: URL(fileURLWithPath: "/tmp/style"), analysisName: "test", lens: "matrix", unfiltered: true)
        let expected = try exportedStyle(filtered, genotype: first, sample: "AnimalA") as NSDictionary
        XCTAssertEqual(try exportedStyle(all, genotype: first, sample: "AnimalA") as NSDictionary, expected)
    }

    func testAllExportHaplotypeStyleUsesRawSupportWithoutChangingFilteredViewport() throws {
        let (matrix, _, _) = fixture()
        var state = GenotypeResultDisplayState()
        state.cellColorMode = .haplotype
        matrix.applyDisplayState(state)
        let before = matrix.exportSnapshot(bundleURL: URL(fileURLWithPath: "/tmp/style"), analysisName: "test", lens: "matrix")
        XCTAssertEqual(matrix.testingRenderedStyle(genotype: second, sample: "AnimalA")?.fillColor, AnnotationColor(red: 0, green: 0, blue: 1))
        let nativeBlue = try XCTUnwrap(exportedStyle(before, genotype: second, sample: "AnimalA")["fillHex"] as? String)
        state.matrixMinimumReads = 10
        matrix.applyDisplayState(state)
        let visibleBefore = matrix.testingVisibleRows.map(\.genotype)
        let all = matrix.exportSnapshot(bundleURL: URL(fileURLWithPath: "/tmp/style"), analysisName: "test", lens: "matrix", unfiltered: true)
        XCTAssertEqual(try exportedStyle(all, genotype: second, sample: "AnimalA")["fillHex"] as? String, nativeBlue)
        XCTAssertEqual(matrix.testingVisibleRows.map(\.genotype), visibleBefore)
    }

    func testReplacingEffectiveCallsRefreshesExistingColoredCells() {
        let (matrix, calls, definitions) = fixture()
        var state = GenotypeResultDisplayState()
        state.cellColorMode = .haplotype
        matrix.applyDisplayState(state)
        matrix.configureHaplotypeEvidence(.init(calls: calls, definitionSet: definitions, effectiveCalls: [
            .init(sample: "AnimalA", locus: "MHC-A", haplotypeNames: ["South"]),
        ]))
        XCTAssertNil(matrix.testingRenderedStyle(genotype: first, sample: "AnimalA")?.fillColor)
        XCTAssertEqual(matrix.testingRenderedStyle(genotype: shared, sample: "AnimalA")?.fillColor,
                       AnnotationColor(red: 0, green: 0, blue: 1))
    }
}
