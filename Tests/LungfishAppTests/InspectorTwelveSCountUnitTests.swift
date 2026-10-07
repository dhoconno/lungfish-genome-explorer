import LungfishTwelveSUI
import SwiftUI
import ViewInspector
import XCTest
@testable import LungfishApp

/// The Inspector's 12S detail names its counts in the unit of the result,
/// fragments when the run read unmerged pairs and reads otherwise, so a
/// merged-only result reads as before. VoiceOver reads the same labels
/// (Phase 2.1 round F4, review B N1).
@MainActor
final class InspectorTwelveSCountUnitTests: XCTestCase {

    private func targetPayload(_ unit: TwelveSCountUnit) -> TwelveSDetailPayload {
        TwelveSDetailPayload(
            kind: .target(.init(
                scientificName: "Homo sapiens",
                totalExactReads: 50,
                referenceTargetCount: 2,
                sampleEvidence: [
                    .init(sampleID: "s1", displayName: "Sample One", exactReads: 1, percentOfSampleExactReads: 100),
                ],
                alternateTexts: []
            )),
            countUnit: unit
        )
    }

    private func unresolvedPayload(_ unit: TwelveSCountUnit) -> TwelveSDetailPayload {
        TwelveSDetailPayload(
            kind: .unresolved(.init(
                sequenceID: "unresolved_1",
                readCount: 3,
                chimeraStatusName: "Not reviewed",
                sequence: "ACGT",
                sampleEvidence: [
                    .init(sampleID: "s1", displayName: "Sample One", exactReads: 3, percentOfSampleExactReads: 0),
                ]
            )),
            countUnit: unit
        )
    }

    private func inspected(_ payload: TwelveSDetailPayload) throws -> InspectableView<ViewType.ClassifiedView> {
        let viewModel = TwelveSDetailSectionViewModel()
        viewModel.apply(payload)
        return try TwelveSDetailSection(viewModel: viewModel).inspect()
    }

    /// The field labels. `findAll` is used because `find` stops at the
    /// section's symbol image, which ViewInspector cannot classify.
    private func fieldLabels(_ payload: TwelveSDetailPayload) throws -> [String] {
        try inspected(payload).findAll(ViewType.LabeledContent.self).compactMap {
            try? $0.labelView().text().string()
        }
    }

    private func texts(_ payload: TwelveSDetailPayload) throws -> [String] {
        try inspected(payload).findAll(ViewType.Text.self).compactMap { try? $0.string() }
    }

    func testTargetDetailNamesItsCountsInTheResultsUnit() throws {
        let fragments = try fieldLabels(targetPayload(.fragments))
        XCTAssertTrue(fragments.contains("Exact Fragments"), "\(fragments)")
        XCTAssertTrue(try texts(targetPayload(.fragments)).contains("1 fragment (100.0%)"))

        let reads = try fieldLabels(targetPayload(.reads))
        XCTAssertTrue(reads.contains("Exact Reads"), "a merged-only result reads as before, \(reads)")
        XCTAssertTrue(try texts(targetPayload(.reads)).contains("1 read (100.0%)"))
    }

    func testResultFiltersNameTheResultsUnit() throws {
        func texts(_ unit: TwelveSCountUnit) throws -> [String] {
            let viewModel = TwelveSResultDisplaySectionViewModel()
            viewModel.update(isAvailable: true)
            viewModel.updateSummary(TwelveSResultDisplaySummary(
                rowLabel: "Target Rows", visibleRows: 2, totalRows: 2, countUnit: unit
            ))
            return try TwelveSResultDisplaySection(viewModel: viewModel).inspect()
                .findAll(ViewType.Text.self).compactMap { try? $0.string() }
        }

        let fragments = try texts(.fragments)
        XCTAssertTrue(fragments.contains("Minimum Exact Fragments"), "\(fragments)")
        XCTAssertTrue(fragments.contains("Minimum Unresolved Fragments"), "\(fragments)")
        XCTAssertTrue(fragments.contains("Unmatched Fragments"), "\(fragments)")

        let reads = try texts(.reads)
        XCTAssertTrue(reads.contains("Minimum Exact Reads"), "a merged-only result reads as before, \(reads)")
        XCTAssertTrue(reads.contains("Minimum Unresolved Reads"), "\(reads)")
        XCTAssertTrue(reads.contains("Unmatched Reads"), "\(reads)")
    }

    func testUnresolvedDetailNamesItsCountsInTheResultsUnit() throws {
        let fragments = try fieldLabels(unresolvedPayload(.fragments))
        XCTAssertTrue(fragments.contains("Fragments"), "\(fragments)")
        XCTAssertTrue(try texts(unresolvedPayload(.fragments)).contains("3 fragments"))

        let reads = try fieldLabels(unresolvedPayload(.reads))
        XCTAssertTrue(reads.contains("Reads"), "a merged-only result reads as before, \(reads)")
        XCTAssertTrue(try texts(unresolvedPayload(.reads)).contains("3 reads"))
    }
}
