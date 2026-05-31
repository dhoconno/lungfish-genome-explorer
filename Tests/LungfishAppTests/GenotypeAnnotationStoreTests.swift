import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class GenotypeAnnotationStoreTests: XCTestCase {
    private func makeBundleURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".lungfishgenotype")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testLoadEmptyAndAppendOverride() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        XCTAssertEqual(store.sidecar.callOverrides.count, 0)

        try store.applyOverride(
            sample: "H22C112", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .crossContamination, rationale: "Adjacent contamination"
        )
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        XCTAssertEqual(store.sidecar.auditLog.count, 1)
        XCTAssertEqual(store.sidecar.auditLog[0].action, "override")

        let reloaded = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        XCTAssertEqual(reloaded.sidecar.callOverrides.count, 1)
    }

    func testApplyOverrideTwiceReplacesSameCellEntry() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.applyOverride(
            sample: "H1", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .crossContamination, rationale: "first"
        )
        try store.applyOverride(
            sample: "H1", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "M3A",
            reasonTag: .misCall, rationale: "second"
        )
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        XCTAssertEqual(store.sidecar.callOverrides[0].overrideCall, "M3A")
        XCTAssertEqual(store.sidecar.auditLog.count, 2)
    }

    func testReplacingOverrideAuditsPreviousManualValueAndPreservesAutomatedOriginal() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.applyOverride(
            sample: "DW472", locus: "MHC-B", slot: .h2,
            originalCall: "M3B", overrideCall: "M2B",
            reasonTag: .misCall, rationale: "first manual correction"
        )
        try store.applyOverride(
            sample: "DW472", locus: "MHC-B", slot: .h2,
            originalCall: "M3B", overrideCall: "M4B",
            reasonTag: .misCall, rationale: "second manual correction"
        )

        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        XCTAssertEqual(store.sidecar.callOverrides[0].originalCall, "M3B")
        XCTAssertEqual(store.sidecar.callOverrides[0].overrideCall, "M4B")
        XCTAssertEqual(store.sidecar.auditLog[1].before, "M2B")
        XCTAssertEqual(store.sidecar.auditLog[1].after, "M4B")
    }

    func testSettingOverrideBackToAutomatedCallClearsOverrideAndAuditsRevert() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.applyOverride(
            sample: "DW472", locus: "MHC-B", slot: .h2,
            originalCall: "M3B", overrideCall: "M2B",
            reasonTag: .misCall, rationale: "manual correction"
        )
        try store.applyOverride(
            sample: "DW472", locus: "MHC-B", slot: .h2,
            originalCall: "M3B", overrideCall: "M3B",
            reasonTag: .misCall, rationale: "restore automated call"
        )

        XCTAssertTrue(store.sidecar.callOverrides.isEmpty)
        XCTAssertEqual(store.sidecar.auditLog.count, 2)
        XCTAssertEqual(store.sidecar.auditLog[1].action, "clearOverride")
        XCTAssertEqual(store.sidecar.auditLog[1].before, "M2B")
        XCTAssertEqual(store.sidecar.auditLog[1].after, "M3B")
    }

    func testManualHaplotypeAssignmentsWriteAuditEntries() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let assignment = ManualHaplotypeAssignment(
            sample: "DW472",
            locus: "MHC-B",
            slot: .h1,
            label: "Manual-M2B",
            colorTokenIndex: 2,
            diagnosticAlleles: ["12_M2_B_019_03"],
            notes: "reviewed in matrix"
        )

        try store.addManualHaplotypeAssignment(assignment)

        XCTAssertEqual(store.sidecar.manualHaplotypeAssignments, [assignment])
        XCTAssertEqual(store.sidecar.auditLog.count, 1)
        XCTAssertEqual(store.sidecar.auditLog[0].action, "addManualHaplotypeAssignment")
        XCTAssertEqual(store.sidecar.auditLog[0].sample, "DW472")
        XCTAssertEqual(store.sidecar.auditLog[0].locus, "MHC-B")
        XCTAssertEqual(store.sidecar.auditLog[0].slot, .h1)
        XCTAssertNil(store.sidecar.auditLog[0].before)
        XCTAssertEqual(store.sidecar.auditLog[0].after, "Manual-M2B")
        XCTAssertEqual(store.sidecar.lastEditor, "test")

        try store.removeManualHaplotypeAssignments { $0.label == "Manual-M2B" }

        XCTAssertTrue(store.sidecar.manualHaplotypeAssignments.isEmpty)
        XCTAssertEqual(store.sidecar.auditLog.count, 2)
        XCTAssertEqual(store.sidecar.auditLog[1].action, "removeManualHaplotypeAssignment")
        XCTAssertEqual(store.sidecar.auditLog[1].before, "Manual-M2B")
        XCTAssertNil(store.sidecar.auditLog[1].after)
    }

    func testUndoOverride() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.applyOverride(
            sample: "H22C112", locus: "MHC-A", slot: .h2,
            originalCall: "M2A", overrideCall: "A1_063",
            reasonTag: .crossContamination, rationale: ""
        )
        XCTAssertEqual(store.sidecar.callOverrides.count, 1)
        try store.undoLastOverride()
        XCTAssertEqual(store.sidecar.callOverrides.count, 0)
        XCTAssertEqual(store.sidecar.auditLog.count, 2)
        XCTAssertEqual(store.sidecar.auditLog[1].action, "undoOverride")
    }

    func testSetSampleStatusOverrideExistingValue() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.setSampleStatus(.needsReview, sample: "H1")
        try store.setSampleStatus(.reviewed, sample: "H1")
        XCTAssertEqual(store.sidecar.sampleStatusFlags.count, 1)
        XCTAssertEqual(store.sidecar.sampleStatusFlags[0].value, .reviewed)
    }

    func testHighlightAndComment() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.setCellHighlight(
            sample: "H1", locus: "MHC-A", slot: .h1,
            fillHex: "#FFEB3B", borderHex: nil
        )
        XCTAssertEqual(store.sidecar.cellHighlights.count, 1)

        try store.setCellHighlight(
            sample: "H1", locus: "MHC-A", slot: .h1,
            fillHex: nil, borderHex: nil
        )
        XCTAssertEqual(store.sidecar.cellHighlights.count, 0)

        try store.addCellComment(
            sample: "H1", locus: "MHC-A", slot: .h1, body: "needs review"
        )
        XCTAssertEqual(store.sidecar.cellComments.count, 1)
    }

    func testConfirmCallWritesAuditWithoutOverride() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.confirmCall(
            sample: "DW472",
            locus: "MHC-B",
            h1: "M3B",
            h2: "M3B"
        )

        XCTAssertEqual(store.sidecar.callOverrides.count, 0)
        XCTAssertEqual(store.sidecar.auditLog.count, 1)
        let audit = store.sidecar.auditLog[0]
        XCTAssertEqual(audit.action, "confirmed")
        XCTAssertEqual(audit.sample, "DW472")
        XCTAssertEqual(audit.locus, "MHC-B")
        XCTAssertNil(audit.slot)
        XCTAssertEqual(audit.before, "M3B/M3B")
        XCTAssertEqual(audit.after, "M3B/M3B")
        XCTAssertEqual(audit.reason, "confirmed")
    }

    func testUpdateSettingsWritesAuditWithBeforeAndAfterValues() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.updateSettings { settings in
            settings.dropoutLocusFraction = 0.05
            settings.viewMode = "matrix"
        }

        XCTAssertEqual(store.sidecar.auditLog.count, 1)
        let audit = store.sidecar.auditLog[0]
        XCTAssertEqual(audit.action, "updateSettings")
        XCTAssertEqual(audit.sample, "bundle")
        XCTAssertEqual(audit.reason, "settings")
        XCTAssertTrue(audit.before?.contains("viewMode=outline") ?? false)
        XCTAssertTrue(audit.before?.contains("dropoutLocusFraction=0.01") ?? false)
        XCTAssertTrue(audit.after?.contains("viewMode=matrix") ?? false)
        XCTAssertTrue(audit.after?.contains("dropoutLocusFraction=0.05") ?? false)
    }

    func testUpdateSettingsRollsBackWhenSidecarCannotPersist() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let before = store.sidecar.settings
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try FileManager.default.removeItem(at: annotationURL)
        try FileManager.default.createDirectory(at: annotationURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(try store.updateSettings { settings in
            settings.dropoutAbsolute = 999
        })

        XCTAssertEqual(store.sidecar.settings, before)
    }

    func testSmartCohortPersistence() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        // GenotypeAnnotationStore seeds three default cohorts on first open
        // (Needs review, Homozygous, Recombinants). Saving an analyst cohort
        // with a colliding name replaces the seeded one; deleting it does
        // not remove the others.
        let initialCount = store.sidecar.smartCohorts.count
        XCTAssertGreaterThanOrEqual(initialCount, 3)

        let customCohort = GenotypeCohortSmartFilter(
            name: "Analyst custom",
            scope: "bundle",
            isStarred: true,
            predicate: .hasErrorAtAnyLocus
        )
        try store.saveSmartCohort(customCohort)
        XCTAssertEqual(store.sidecar.smartCohorts.count, initialCount + 1)

        // saving with same name+scope replaces
        try store.saveSmartCohort(customCohort)
        XCTAssertEqual(store.sidecar.smartCohorts.count, initialCount + 1)

        try store.deleteSmartCohort(name: "Analyst custom", scope: "bundle")
        XCTAssertEqual(store.sidecar.smartCohorts.count, initialCount)
    }

    func testAnnotationSidecarMutationWritesProvenanceSidecar() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let cohort = GenotypeCohortSmartFilter(
            name: "Metadata cohort",
            scope: "bundle",
            isStarred: true,
            predicate: .metadataFieldContains(field: "Cohort", value: "Kenyon20")
        )

        try store.saveSmartCohort(cohort)

        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.workflowName, "Genotype annotation sidecar edit")
        XCTAssertEqual(envelope.toolName, "Lungfish Genome Explorer")
        XCTAssertEqual(envelope.argv, [
            "lungfish-cli",
            "edit-genotype-annotations",
            "--bundle", dir.path,
            "--action", "saveSmartCohort",
        ])
        XCTAssertEqual(envelope.options.explicit["bundle"]?.fileValue?.path, dir.path)
        XCTAssertEqual(envelope.options.explicit["annotationSidecar"]?.fileValue?.path, annotationURL.path)
        XCTAssertEqual(envelope.options.explicit["action"], .string("saveSmartCohort"))
        XCTAssertEqual(envelope.options.resolvedDefaults["author"], .string("test"))
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.outputs.map(\.path), [annotationURL.path])
        XCTAssertEqual(envelope.outputs.first?.role, .output)
        XCTAssertNotNil(envelope.outputs.first?.checksumSHA256)
        XCTAssertNotNil(envelope.outputs.first?.fileSize)
    }

    func testDefaultCohortsSeededOnFirstOpen() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let names = Set(store.sidecar.smartCohorts.map(\.name))
        XCTAssertTrue(names.contains("Needs review"))
        XCTAssertTrue(names.contains("Homozygous"))
        XCTAssertTrue(names.contains("Recombinants"))
    }

    func testDefaultCohortsDoNotOverwriteAnalystCustomVersion() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First open: seed.
        let initial = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let customNeedsReview = GenotypeCohortSmartFilter(
            name: "Needs review",
            description: "Custom analyst predicate.",
            scope: "bundle",
            isStarred: true,
            predicate: .commentContains("escalate")
        )
        try initial.saveSmartCohort(customNeedsReview)

        // Reopen: should not re-seed Needs review now that one exists.
        let reopened = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let needsReview = reopened.sidecar.smartCohorts.first { $0.name == "Needs review" }
        XCTAssertEqual(needsReview?.description, "Custom analyst predicate.")
    }
}
