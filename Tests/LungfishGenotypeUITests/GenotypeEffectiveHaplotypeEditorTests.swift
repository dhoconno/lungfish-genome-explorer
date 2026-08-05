import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeEffectiveHaplotypeEditorTests: XCTestCase {
    func testDynamicRowsSeedValuesAndTrackOnlyChanges() {
        let model = makeModel()

        XCTAssertEqual(model.rows.map(\.locus), ["MHC-A", "MHC-DR", "MHC-DQ"])
        XCTAssertEqual(model.rows[0].h1.label, "M2A")
        XCTAssertEqual(model.rows[0].h2.label, "M4A")
        XCTAssertEqual(model.completenessSummary, "4 of 6 assigned")
        XCTAssertFalse(model.isDirty)

        model.updateLabel("M3A", locus: "MHC-A", slot: .h1)
        model.clear(locus: "MHC-A", slot: .h2)

        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.changedValues, [
            .init(locus: "MHC-A", slot: .h1): "M3A",
            .init(locus: "MHC-A", slot: .h2): "-",
        ])
        XCTAssertEqual(model.rows[0].h2.label, "")
    }

    func testClearingOneSlotStagesExplicitNotCalledOnlyForThatSlot() {
        let model = makeModel()

        model.clear(locus: "MHC-A", slot: .h1)

        XCTAssertEqual(model.changedValues, [
            .init(locus: "MHC-A", slot: .h1): "-",
        ])
        XCTAssertEqual(model.rows[0].h1.label, "")
        XCTAssertEqual(model.rows[0].h2.label, "M4A")
    }

    func testRestoreStagesWorkflowCallWithoutTouchingPartnerSlot() {
        let h1 = GenotypeEffectiveHaplotypeEditorModel.Address(
            locus: "MHC-A",
            slot: .h1
        )
        let h2 = GenotypeEffectiveHaplotypeEditorModel.Address(
            locus: "MHC-A",
            slot: .h2
        )
        let model = GenotypeEffectiveHaplotypeEditorModel(
            snapshot: .init(
                sample: "S1",
                orderedLoci: ["MHC-A"],
                values: [h1: "AnalystA", h2: "M4A"],
                workflowBaselines: [h1: "M2A", h2: "M4A"],
                authoritativeOverrideAddresses: [h1],
                suggestions: ["M2A", "M4A", "AnalystA"],
                isReadOnly: false
            ),
            onSave: { _ in throw CocoaError(.fileWriteUnknown) },
            onReload: { throw CocoaError(.fileReadUnknown) }
        )

        XCTAssertTrue(model.rows[0].h1.canRestoreWorkflowCall)
        XCTAssertFalse(model.rows[0].h2.canRestoreWorkflowCall)

        model.restoreWorkflowCall(locus: "MHC-A", slot: .h1)

        XCTAssertEqual(model.changedValues, [h1: "M2A"])
        XCTAssertEqual(model.rows[0].h1.label, "M2A")
        XCTAssertEqual(model.rows[0].h2.label, "M4A")
    }

    func testValidationAndReadOnlyStatePreventSaving() {
        let model = makeModel()
        model.updateLabel("bad\nlabel", locus: "MHC-A", slot: .h1)
        XCTAssertFalse(model.canSave)
        XCTAssertNotNil(model.rows[0].h1.validationDescription)

        let readOnly = makeModel(isReadOnly: true)
        readOnly.updateLabel("M3A", locus: "MHC-A", slot: .h1)
        XCTAssertEqual(readOnly.rows[0].h1.label, "M2A")
        XCTAssertFalse(readOnly.canSave)
        XCTAssertNotNil(readOnly.readOnlyMessage)
    }

    func testSaveReloadsSnapshotAndFailureRetainsDraft() {
        enum Failure: Error { case expected }
        var shouldFail = true
        var saves: [[GenotypeEffectiveHaplotypeEditorModel.Address: String]] = []
        let model = makeModel(onSave: { changes in
            saves.append(changes)
            if shouldFail { throw Failure.expected }
            return self.snapshot(h1: "M3A")
        })
        model.updateLabel("M3A", locus: "MHC-A", slot: .h1)

        model.save()
        XCTAssertEqual(model.rows[0].h1.label, "M3A")
        XCTAssertTrue(model.isDirty)
        XCTAssertNotNil(model.persistenceErrorMessage)

        shouldFail = false
        model.retry()
        XCTAssertEqual(saves.count, 2)
        XCTAssertFalse(model.isDirty)
        XCTAssertNil(model.persistenceErrorMessage)
        XCTAssertEqual(model.rows[0].h1.label, "M3A")
    }

    func testNoOpSaveDoesNotInvokePersistence() {
        var saveCount = 0
        let model = makeModel(onSave: { _ in
            saveCount += 1
            return self.snapshot()
        })

        model.save()

        XCTAssertEqual(saveCount, 0)
        XCTAssertFalse(model.canSave)
    }

    func testEffectiveEditorUsesSharedAssignmentCard() {
        let view = GenotypeEffectiveHaplotypeEditor(model: makeModel())

        XCTAssertEqual(
            view.testingSharedAssignmentCardIdentifier,
            "shared-haplotype-assignment-card"
        )
    }

    func testSharedAssignmentSlotCarriesOptionalWorkflowRestoreMetadata() {
        let slot = GenotypeHaplotypeAssignmentEditorSlot(
            address: .init(locus: "MHC-A", slot: .h1),
            label: "M2A",
            suggestions: [],
            colorTokenIndex: nil,
            validationDescription: nil,
            accessibilityLabel: "MHC-A H1 haplotype label",
            clearAccessibilityLabel: "Mark MHC-A H1 not called",
            accessibilityIdentifier: "effective-haplotype-MHC-A-h1"
        )
        let fieldNames = Set(
            Mirror(reflecting: slot).children.compactMap(\.label)
        )

        XCTAssertTrue(fieldNames.contains("restoreAccessibilityLabel"))
        XCTAssertTrue(fieldNames.contains("restoreHelp"))
    }

    private func makeModel(
        isReadOnly: Bool = false,
        onSave: (([GenotypeEffectiveHaplotypeEditorModel.Address: String]) throws
            -> GenotypeEffectiveHaplotypeEditorModel.Snapshot)? = nil
    ) -> GenotypeEffectiveHaplotypeEditorModel {
        GenotypeEffectiveHaplotypeEditorModel(
            snapshot: snapshot(isReadOnly: isReadOnly),
            onSave: onSave ?? { _ in self.snapshot(isReadOnly: isReadOnly) },
            onReload: { self.snapshot(isReadOnly: isReadOnly) }
        )
    }

    private func snapshot(
        h1: String = "M2A",
        isReadOnly: Bool = false
    ) -> GenotypeEffectiveHaplotypeEditorModel.Snapshot {
        .init(
            sample: "S1",
            orderedLoci: ["MHC-A", "MHC-DR", "MHC-DQ"],
            values: [
                .init(locus: "MHC-A", slot: .h1): h1,
                .init(locus: "MHC-A", slot: .h2): "M4A",
                .init(locus: "MHC-DR", slot: .h1): "M2DR",
                .init(locus: "MHC-DR", slot: .h2): "M4DR",
                .init(locus: "MHC-DQ", slot: .h1): "",
                .init(locus: "MHC-DQ", slot: .h2): "",
            ],
            suggestions: ["M2A", "M3A", "M4A"],
            isReadOnly: isReadOnly
        )
    }
}
