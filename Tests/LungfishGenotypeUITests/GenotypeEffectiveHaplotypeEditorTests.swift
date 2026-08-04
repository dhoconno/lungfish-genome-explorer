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
            .init(locus: "MHC-A", slot: .h2): "",
        ])
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
