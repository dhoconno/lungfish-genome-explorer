// ProvenanceInspectorAffectedTests.swift - The Inspector shows the sentence of a result an earlier build made wrong
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class ProvenanceInspectorAffectedTests: XCTestCase {
    private func item(_ type: SidebarItemType) -> ProvenanceInspectableItem {
        ProvenanceInspectableItem(
            url: URL(fileURLWithPath: "/tmp/affected-results-test"), sidebarType: type,
            contentMode: .metagenomics, displayName: "result"
        )
    }

    private func model(build appVersion: String) -> ProvenanceInspectorViewModel {
        let model = ProvenanceInspectorViewModel()
        var envelope = ProvenanceEnvelope.fixture()
        envelope.runtimeIdentity = ProvenanceRuntimeIdentity(appVersion: appVersion)
        model.resolvedEnvelope = envelope
        return model
    }

    private func shown(_ model: ProvenanceInspectorViewModel) -> [String] {
        model.warnings.filter { $0.title == ProvenanceInspectorViewModel.affectedResultsWarningTitle }.map(\.message)
    }

    func testTheInspectorOfARecordOfAnAffectedBuildShowsTheSentenceAndWhatToDo() throws {
        let model = model(build: "Lungfish 2026.10.29 (12045)")
        model.applyAffectedResults(item: item(.taxTriageResult))
        let reads = try XCTUnwrap(AffectedResults.rows.first { $0.backlogID == "TTREADS" })
        XCTAssertTrue(shown(model).contains(reads.words), "the sentence then what to do, as the table words them")
        XCTAssertEqual(shown(model).count,
                       AffectedResults.rows(forAppVersion: "Lungfish 2026.10.29 (12045)", kind: .taxTriage).count)
    }

    func testARecordOfAnUnaffectedOrDevBuildShowsNothing() {
        for appVersion in ["Lungfish 2026.11.7 (12972)", "Lungfish 2026.11.7 (dev)", "Lungfish 2026.11.7"] {
            let model = model(build: appVersion)
            model.applyAffectedResults(item: item(.taxTriageResult))
            XCTAssertEqual(shown(model), [], appVersion)
        }
    }

    func testAResultOfAnotherKindOrWithNoRecordShowsNothing() {
        let model = model(build: "Lungfish 2026.10.29 (12045)")
        model.applyAffectedResults(item: item(.sequence))
        XCTAssertEqual(shown(model), [], "no row speaks about a plain sequence")
        model.resolvedEnvelope = nil
        model.applyAffectedResults(item: item(.taxTriageResult))
        XCTAssertEqual(shown(model), [], "a result with no record has no build to hold")
    }

    func testTheSentenceIsNotAddedTwiceByTwoLookups() {
        let model = model(build: "Lungfish 2026.10.29 (12045)")
        model.applyAffectedResults(item: item(.taxTriageResult))
        let once = shown(model)
        model.applyAffectedResults(item: item(.taxTriageResult))
        XCTAssertEqual(shown(model), once)
    }

    func testTheViewersStripIsToldTheMatchedRows() throws {
        let model = model(build: "Lungfish 2026.10.29 (12045)")
        var received: [AffectedResultRow]?
        let token = NotificationCenter.default.addObserver(
            forName: .affectedResultsDidChange, object: model, queue: nil
        ) { note in
            received = note.userInfo?[ProvenanceInspectorViewModel.affectedResultsRowsKey] as? [AffectedResultRow]
        }
        defer { NotificationCenter.default.removeObserver(token) }
        model.applyAffectedResults(item: item(.taxTriageResult))
        XCTAssertEqual(received, AffectedResults.rows(forAppVersion: "Lungfish 2026.10.29 (12045)", kind: .taxTriage))
        model.resolvedEnvelope = ProvenanceEnvelope.fixture()
        model.applyAffectedResults(item: item(.taxTriageResult))
        XCTAssertEqual(received, [], "a fixture record names a build with no number")
    }

    func testTheKindOfAnItemFollowsItsSidebarType() {
        let kinds: [(SidebarItemType, AffectedResultKind)] = [
            (.taxTriageResult, .taxTriage), (.esvirituResult, .esViritu), (.classificationResult, .kraken2),
            (.naoMgsResult, .naoMgs), (.nvdResult, .nvd),
        ]
        for (type, kind) in kinds {
            XCTAssertEqual(ProvenanceInspectorViewModel.affectedResultKind(for: item(type)), kind)
        }
        XCTAssertEqual(ProvenanceInspectorViewModel.affectedResultKind(forTool: "spades"), .assembly)
        XCTAssertNil(ProvenanceInspectorViewModel.affectedResultKind(forTool: "primer-order"))
    }
}
