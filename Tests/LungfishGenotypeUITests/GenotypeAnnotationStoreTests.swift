import XCTest
import Darwin
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeAnnotationStoreTests: XCTestCase {
    private struct InjectedPublicationFailure: Error {}

    private final class PublicationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func inject(_ point: GenotypeAnnotationPublicationFaultPoint) -> Error? {
            if point == .beforeProvenancePublication {
                lock.lock()
                storage += 1
                lock.unlock()
            }
            return nil
        }
    }

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

    func testMatrixAnnotationWritesAuditEntryAndProvenance() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-B",
            genotype: "Mamu-I*expected",
            sample: "AR3628"
        )

        try store.setMatrixStyle(
            target: target,
            style: .init(fillColor: "#FFF2CC", textColor: "#C00000", borderColor: "#666666", isBold: true, isItalic: true)
        )
        try store.addMatrixComment(target: target, body: "Expected genotype missing from reads.")

        XCTAssertEqual(store.sidecar.matrixStyles.count, 1)
        XCTAssertEqual(store.sidecar.matrixComments.count, 1)
        XCTAssertEqual(store.sidecar.auditLog.suffix(2).map(\.action), ["setMatrixStyle", "addMatrixComment"])
        XCTAssertEqual(store.sidecar.auditLog.last?.sample, "AR3628")
        XCTAssertEqual(store.sidecar.auditLog.last?.locus, "MHC-B")

        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.options.explicit["action"], .string("addMatrixComment"))
        XCTAssertEqual(Array(envelope.argv.prefix(3)), ["lungfish-cli", "genotype", "apply-annotations"])
        XCTAssertTrue(envelope.argv.contains("--bundle"))
        XCTAssertTrue(envelope.argv.contains("--patch"))
        XCTAssertEqual(envelope.options.explicit["targetCount"], .integer(1))
        XCTAssertEqual(envelope.options.explicit["targets"], .array([
            .dictionary([
                "kind": .string("cell"),
                "locus": .string("MHC-B"),
                "genotype": .string("Mamu-I*expected"),
                "sample": .string("AR3628"),
            ]),
        ]))
        XCTAssertEqual(envelope.options.explicit["commentBodies"], .array([
            .string("Expected genotype missing from reads."),
        ]))
        XCTAssertEqual(envelope.options.resolvedDefaults["matrixStyleCount"], .integer(1))
        XCTAssertEqual(envelope.options.resolvedDefaults["matrixCommentCount"], .integer(1))
    }

    func testCandidateCollisionMatrixAnnotationsRemainDistinctByStableClusterID() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        let genotype = "Mafa-A1*018:01:01:01_5nt_nov"
        let targetA = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: genotype,
            stableClusterID: "cluster-a"
        )
        let targetB = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: genotype,
            stableClusterID: "cluster-b"
        )

        try store.setMatrixStyles([
            (target: targetA, style: .init(fillColor: "#112233")),
            (target: targetB, style: .init(fillColor: "#445566")),
        ])
        try store.addMatrixComments([
            (target: targetA, body: "Cluster A note"),
            (target: targetB, body: "Cluster B note"),
        ])

        XCTAssertEqual(Set(store.sidecar.matrixStyles.map(\.target)), Set([targetA, targetB]))
        XCTAssertEqual(Set(store.sidecar.matrixComments.map(\.target)), Set([targetA, targetB]))
        let reloaded = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        XCTAssertEqual(Set(reloaded.sidecar.matrixStyles.map(\.target)), Set([targetA, targetB]))
        XCTAssertEqual(Set(reloaded.sidecar.matrixComments.map(\.target)), Set([targetA, targetB]))
    }

    func testMatrixBatchAnnotationProvenanceCapturesAllTargets() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "test")
        try store.addMatrixComments([
            (
                target: .cell(locus: "MHC-A", genotype: "01_Mafa_A1_001_01", sample: "AR3628"),
                body: "Expected in this animal."
            ),
            (
                target: .cell(locus: "MHC-A", genotype: "01_Mafa_A1_001_01", sample: "AR3629"),
                body: "Expected in this animal."
            ),
        ])

        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.options.explicit["action"], .string("addMatrixComments"))
        XCTAssertEqual(envelope.options.explicit["targetCount"], .integer(2))
        XCTAssertEqual(envelope.options.explicit["commentBodies"], .array([
            .string("Expected in this animal."),
            .string("Expected in this animal."),
        ]))
        XCTAssertEqual(envelope.options.resolvedDefaults["matrixCommentCount"], .integer(2))
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

    func testUpdateMHCCandidateDisplaySettingsIsBundleScopedAndPreservesScientificArtifacts() throws {
        let bundleA = try makeBundleURL()
        let bundleB = try makeBundleURL()
        defer {
            try? FileManager.default.removeItem(at: bundleA)
            try? FileManager.default.removeItem(at: bundleB)
        }
        let scientificPaths = [
            "manifest.json",
            "candidate-alleles.json",
            "artifacts/workbooks/initial.xlsx",
            "artifacts/workbooks/current.xlsx",
            "artifacts/alignments/genotyping-evidence.bam",
        ]
        for (offset, path) in scientificPaths.enumerated() {
            let url = bundleA.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("scientific-\(offset)".utf8).write(to: url)
        }

        let storeA = try GenotypeAnnotationStore(bundleURL: bundleA, author: "candidate-tester")
        let storeB = try GenotypeAnnotationStore(bundleURL: bundleB, author: "candidate-tester")
        let annotationA = bundleA.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let annotationB = bundleB.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let beforeAnnotationA = try Data(contentsOf: annotationA)
        let beforeAnnotationB = try Data(contentsOf: annotationB)
        let scientificBytes = try Dictionary(uniqueKeysWithValues: scientificPaths.map {
            ($0, try Data(contentsOf: bundleA.appendingPathComponent($0)))
        })
        var display = storeA.sidecar.settings.mhcCandidateDisplay
        display.showKnown = false
        display.showSingletonCandidates = false
        display.tints[.sharedNovel] = try XCTUnwrap(AnnotationColor(hex: "#123456"))

        try storeA.updateMHCCandidateDisplaySettings(display)

        XCTAssertNotEqual(try Data(contentsOf: annotationA), beforeAnnotationA)
        XCTAssertEqual(try Data(contentsOf: annotationB), beforeAnnotationB)
        XCTAssertEqual(storeB.sidecar.settings.mhcCandidateDisplay, .default)
        for path in scientificPaths {
            XCTAssertEqual(try Data(contentsOf: bundleA.appendingPathComponent(path)), scientificBytes[path])
        }
    }

    func testUpdateMHCCandidateDisplaySettingsRecordsExactColorsAndFinalChecksumInProvenance() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "candidate-tester")
        var display = store.sidecar.settings.mhcCandidateDisplay
        display.showKnown = false
        display.showSharedCandidates = true
        display.showSingletonCandidates = false
        display.tints = [
            .sharedNovel: AnnotationColor(red: 0.123456789012345, green: 0.234567890123456, blue: 0.345678901234567, alpha: 0.456789012345678),
            .singletonNovel: AnnotationColor(red: 0.223456789012345, green: 0.334567890123456, blue: 0.445678901234567, alpha: 0.556789012345678),
            .sharedExtension: AnnotationColor(red: 0.323456789012345, green: 0.434567890123456, blue: 0.545678901234567, alpha: 0.656789012345678),
            .singletonExtension: AnnotationColor(red: 0.423456789012345, green: 0.534567890123456, blue: 0.645678901234567, alpha: 0.756789012345678),
        ]

        try store.updateMHCCandidateDisplaySettings(display)

        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: provenanceURL))
        XCTAssertEqual(envelope.options.explicit["action"], .string("updateMHCCandidateDisplaySettings"))
        XCTAssertEqual(envelope.options.explicit["showKnown"], .boolean(false))
        XCTAssertEqual(envelope.options.explicit["showSharedCandidates"], .boolean(true))
        XCTAssertEqual(envelope.options.explicit["showSingletonCandidates"], .boolean(false))
        XCTAssertEqual(envelope.options.explicit["candidateTints"], .dictionary([
            "sharedNovel": .dictionary([
                "red": .number(0.123456789012345),
                "green": .number(0.234567890123456),
                "blue": .number(0.345678901234567),
                "alpha": .number(0.456789012345678),
                "hexRGB": .string("#1F3B58"),
            ]),
            "singletonNovel": .dictionary([
                "red": .number(0.223456789012345),
                "green": .number(0.334567890123456),
                "blue": .number(0.445678901234567),
                "alpha": .number(0.556789012345678),
                "hexRGB": .string("#385571"),
            ]),
            "sharedExtension": .dictionary([
                "red": .number(0.323456789012345),
                "green": .number(0.434567890123456),
                "blue": .number(0.545678901234567),
                "alpha": .number(0.656789012345678),
                "hexRGB": .string("#526E8B"),
            ]),
            "singletonExtension": .dictionary([
                "red": .number(0.423456789012345),
                "green": .number(0.534567890123456),
                "blue": .number(0.645678901234567),
                "alpha": .number(0.756789012345678),
                "hexRGB": .string("#6B88A4"),
            ]),
        ]))
        XCTAssertEqual(envelope.outputs.first?.path, annotationURL.path)
        XCTAssertEqual(
            envelope.outputs.first?.checksumSHA256,
            try ProvenanceFileDescriptor.file(url: annotationURL, format: .json, role: .output).checksumSHA256
        )
        XCTAssertEqual(store.sidecar.auditLog.last?.action, "updateMHCCandidateDisplaySettings")
        XCTAssertTrue(store.sidecar.auditLog.last?.after?.contains(
            "sharedNovel={red=0.123456789012345,green=0.234567890123456,blue=0.345678901234567,alpha=0.456789012345678,hexRGB=#1F3B58}"
        ) == true)
    }

    func testUpdateMHCCandidateDisplaySettingsRollsBackWhenAtomicSidecarWriteFails() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "candidate-tester")
        let before = store.sidecar
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try FileManager.default.removeItem(at: annotationURL)
        try FileManager.default.createDirectory(at: annotationURL, withIntermediateDirectories: true)
        var display = before.settings.mhcCandidateDisplay
        display.showKnown = false

        XCTAssertThrowsError(try store.updateMHCCandidateDisplaySettings(display))

        XCTAssertEqual(store.sidecar, before)
    }

    func testCandidateDisplayPublicationRestoresAnnotationAndProvenanceBytesWhenProvenancePublishFails() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let initial = try GenotypeAnnotationStore(bundleURL: dir, author: "initial")
        try initial.updateSettings { $0.viewMode = "matrix" }
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let priorAnnotation = try Data(contentsOf: annotationURL)
        let priorProvenance = try Data(contentsOf: provenanceURL)
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "fault",
            publicationFaultInjector: { point in
                point == .beforeProvenancePublication ? InjectedPublicationFailure() : nil
            }
        )
        var display = store.sidecar.settings.mhcCandidateDisplay
        display.showKnown = false

        XCTAssertThrowsError(try store.updateMHCCandidateDisplaySettings(display))

        XCTAssertEqual(try Data(contentsOf: annotationURL), priorAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), priorProvenance)
        XCTAssertEqual(store.sidecar.settings.mhcCandidateDisplay.showKnown, true)
    }

    func testCandidateDisplayPublicationRestoresBothFilesWhenCommitDirectorySyncFails() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let initial = try GenotypeAnnotationStore(bundleURL: dir, author: "initial")
        try initial.updateSettings { $0.panelLayout = "bLeading" }
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let priorAnnotation = try Data(contentsOf: annotationURL)
        let priorProvenance = try Data(contentsOf: provenanceURL)
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "fault",
            publicationFaultInjector: { point in
                point == .commitDirectorySync ? InjectedPublicationFailure() : nil
            }
        )
        var display = store.sidecar.settings.mhcCandidateDisplay
        display.showSharedCandidates = false

        XCTAssertThrowsError(try store.updateMHCCandidateDisplaySettings(display))

        XCTAssertEqual(try Data(contentsOf: annotationURL), priorAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), priorProvenance)
    }

    func testPublicationReportsPrimaryAndRollbackFailuresTogether() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let initial = try GenotypeAnnotationStore(bundleURL: dir, author: "initial")
        try initial.updateSettings { $0.cardDensity = "compact" }
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let priorAnnotation = try Data(contentsOf: annotationURL)
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "fault",
            publicationFaultInjector: { point in
                guard point == .beforeProvenancePublication else { return nil }
                try? FileManager.default.removeItem(at: provenanceURL)
                try? FileManager.default.createDirectory(
                    at: provenanceURL,
                    withIntermediateDirectories: false
                )
                return InjectedPublicationFailure()
            }
        )
        var display = store.sidecar.settings.mhcCandidateDisplay
        display.showKnown = false

        XCTAssertThrowsError(try store.updateMHCCandidateDisplaySettings(display)) { error in
            let transactionError = error as? GenotypeAnnotationPublicationTransactionError
            XCTAssertTrue(transactionError?.primaryError is InjectedPublicationFailure)
            XCTAssertNotNil(transactionError?.rollbackError)
        }
        XCTAssertEqual(try Data(contentsOf: annotationURL), priorAnnotation)
    }

    func testStaleCandidateStoreMergesOntoLatestUnrelatedSettingsEditUnderLock() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let candidateStore = try GenotypeAnnotationStore(bundleURL: dir, author: "candidate")
        let settingsStore = try GenotypeAnnotationStore(bundleURL: dir, author: "settings")
        try settingsStore.updateSettings { $0.viewMode = "matrix" }
        var display = candidateStore.sidecar.settings.mhcCandidateDisplay
        display.showSingletonCandidates = false

        try candidateStore.updateMHCCandidateDisplaySettings(display)

        let reloaded = try GenotypeAnnotationStore(bundleURL: dir, author: "reader")
        XCTAssertEqual(reloaded.sidecar.settings.viewMode, "matrix")
        XCTAssertFalse(reloaded.sidecar.settings.mhcCandidateDisplay.showSingletonCandidates)
        XCTAssertEqual(
            reloaded.sidecar.auditLog.suffix(2).map(\.action),
            ["updateSettings", "updateMHCCandidateDisplaySettings"]
        )
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        ))
        XCTAssertEqual(
            provenance.outputs.first?.checksumSHA256,
            try ProvenanceFileDescriptor.file(url: annotationURL, format: .json, role: .output).checksumSHA256
        )
    }

    func testStaleCandidateStoreConflictsWithConcurrentCandidateEdit() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let first = try GenotypeAnnotationStore(bundleURL: dir, author: "first")
        let stale = try GenotypeAnnotationStore(bundleURL: dir, author: "stale")
        var firstDisplay = first.sidecar.settings.mhcCandidateDisplay
        firstDisplay.showKnown = false
        try first.updateMHCCandidateDisplaySettings(firstDisplay)
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let firstAnnotation = try Data(contentsOf: annotationURL)
        let firstProvenance = try Data(contentsOf: provenanceURL)
        var staleDisplay = stale.sidecar.settings.mhcCandidateDisplay
        staleDisplay.showSingletonCandidates = false

        XCTAssertThrowsError(try stale.updateMHCCandidateDisplaySettings(staleDisplay))
        XCTAssertEqual(try Data(contentsOf: annotationURL), firstAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), firstProvenance)

        let reloaded = try GenotypeAnnotationStore(bundleURL: dir, author: "reader")
        XCTAssertFalse(reloaded.sidecar.settings.mhcCandidateDisplay.showKnown)
        XCTAssertTrue(reloaded.sidecar.settings.mhcCandidateDisplay.showSingletonCandidates)
        XCTAssertEqual(stale.sidecar, reloaded.sidecar)
    }

    func testHeldCandidatePublicationLockCannotPartiallyMutateBundle() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "candidate")
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let priorAnnotation = try Data(contentsOf: annotationURL)
        let priorProvenance = try Data(contentsOf: provenanceURL)
        let lockURL = dir.appendingPathComponent(".annotations-publication.lock")
        let lockFD = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        defer { if lockFD >= 0 { Darwin.close(lockFD) } }
        XCTAssertEqual(flock(lockFD, LOCK_EX | LOCK_NB), 0)
        defer { if lockFD >= 0 { _ = flock(lockFD, LOCK_UN) } }
        var display = store.sidecar.settings.mhcCandidateDisplay
        display.showKnown = false

        XCTAssertThrowsError(try store.updateMHCCandidateDisplaySettings(display))

        XCTAssertEqual(try Data(contentsOf: annotationURL), priorAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), priorProvenance)
    }

    func testUnsafeCandidatePublicationLockCannotPartiallyMutateBundle() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "candidate")
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let priorAnnotation = try Data(contentsOf: annotationURL)
        let priorProvenance = try Data(contentsOf: provenanceURL)
        let lockURL = dir.appendingPathComponent(".annotations-publication.lock")
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        var display = store.sidecar.settings.mhcCandidateDisplay
        display.showSharedCandidates = false

        XCTAssertThrowsError(try store.updateMHCCandidateDisplaySettings(display))

        XCTAssertEqual(try Data(contentsOf: annotationURL), priorAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), priorProvenance)
    }

    func testGenericStaleStoreConflictsWithoutOverwritingLatestEdit() throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let first = try GenotypeAnnotationStore(bundleURL: dir, author: "first")
        let stale = try GenotypeAnnotationStore(bundleURL: dir, author: "stale")
        try first.setSampleStatus(.reviewed, sample: "sample-1")

        XCTAssertThrowsError(try stale.setCallStatus(
            .needsReview,
            sample: "sample-2",
            locus: "MHC-A",
            slot: .h1
        ))

        let reloaded = try GenotypeAnnotationStore(bundleURL: dir, author: "reader")
        XCTAssertEqual(reloaded.sidecar.sampleStatusFlags.map(\.sample), ["sample-1"])
        XCTAssertTrue(reloaded.sidecar.callStatusFlags.isEmpty)
        XCTAssertEqual(stale.sidecar, reloaded.sidecar)
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
            "genotype",
            "apply-annotations",
            "--bundle", dir.path,
            "--patch", annotationURL.path,
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
        XCTAssertTrue(names.contains("Incomplete haplotypes"))
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

    func testSetFalsePositivePublishesAllSupportedCellsOnce() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let publications = PublicationCounter()
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "construction-author",
            publicationFaultInjector: publications.inject
        )
        let first = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            sample: "Animal-1",
            stableClusterID: "cluster-1"
        )
        let second = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            sample: "Animal-2",
            stableClusterID: "cluster-2"
        )
        let evidence = GenotypeMatrixEvidenceIndex([first: 8, second: 2])

        try await store.setMatrixReview(
            .falsePositive,
            targets: [first, second, first],
            evidence: evidence,
            author: "reviewer"
        )

        XCTAssertEqual(publications.count, 1)
        XCTAssertEqual(store.sidecar.matrixReviews.count, 2)
        XCTAssertEqual(Set(store.sidecar.matrixReviews.map(\.target)), Set([first, second]))
        XCTAssertEqual(Set(store.sidecar.matrixReviews.map(\.author)), ["reviewer"])
        let audit = Array(store.sidecar.auditLog.suffix(2))
        XCTAssertEqual(audit.map(\.action), ["setMatrixReview", "setMatrixReview"])
        XCTAssertEqual(Set(audit.map(\.timestamp)).count, 1)
        XCTAssertTrue(audit.contains { $0.rationale == first.stableAuditDescription })
        XCTAssertTrue(audit.contains { $0.rationale == second.stableAuditDescription })

        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        ))
        XCTAssertEqual(envelope.options.explicit["action"], .string("setMatrixReview"))
        XCTAssertEqual(envelope.options.explicit["eligibilityRule"], .string("passedUniqueReads > 0"))
        XCTAssertEqual(envelope.options.explicit["supportedCount"], .integer(2))
        XCTAssertEqual(envelope.options.explicit["unsupportedCount"], .integer(0))
        XCTAssertEqual(envelope.options.explicit["targetCount"], .integer(2))
        XCTAssertEqual(envelope.options.resolvedDefaults["author"], .string("reviewer"))
        XCTAssertEqual(envelope.options.resolvedDefaults["absentEvidence"], .string("unsupported"))
        let provenanceInput = try XCTUnwrap(envelope.files.first { $0.role == .input })
        XCTAssertEqual(provenanceInput.path, annotationURL.path)
        XCTAssertNotNil(provenanceInput.checksumSHA256)
        XCTAssertNotNil(provenanceInput.fileSize)
        XCTAssertEqual(envelope.outputs.first?.path, annotationURL.path)
        XCTAssertEqual(
            envelope.outputs.first?.checksumSHA256,
            try ProvenanceFileHasher.sha256(of: annotationURL)
        )
        XCTAssertEqual(
            envelope.outputs.first?.fileSize,
            try ProvenanceFileHasher.fileSize(of: annotationURL)
        )
    }

    func testSetFalseNegativeTreatsAbsentEvidenceAsUnsupported() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let zero = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-B",
            genotype: "Mafa-B*001:01",
            sample: "Animal-1"
        )
        let absent = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-B",
            genotype: "Mafa-B*002:01",
            sample: "Animal-2"
        )

        try await store.setMatrixReview(
            .falseNegative,
            targets: [zero, absent],
            evidence: .init([zero: 0]),
            author: "reviewer"
        )

        XCTAssertEqual(store.sidecar.matrixReviews.map(\.disposition), [.falseNegative, .falseNegative])
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        ))
        XCTAssertEqual(envelope.options.explicit["eligibilityRule"], .string("passedUniqueReads <= 0 or absent"))
        XCTAssertEqual(envelope.options.explicit["supportedCount"], .integer(0))
        XCTAssertEqual(envelope.options.explicit["unsupportedCount"], .integer(2))
    }

    func testMixedEvidenceRejectsEntireMutation() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let supported = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1", genotype: "A", sample: "Animal-1"
        )
        let unsupported = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1", genotype: "A", sample: "Animal-2"
        )
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let beforeAnnotation = try Data(contentsOf: annotationURL)
        let beforeProvenance = try Data(contentsOf: provenanceURL)

        do {
            try await store.setMatrixReview(
                .falsePositive,
                targets: [supported, unsupported],
                evidence: .init([supported: 5]),
                author: "reviewer"
            )
            XCTFail("Expected mixed evidence to reject the entire command")
        } catch let error as GenotypeMatrixReviewMutationError {
            XCTAssertEqual(error, .ineligibleEvidence)
        }

        XCTAssertTrue(store.sidecar.matrixReviews.isEmpty)
        XCTAssertEqual(try Data(contentsOf: annotationURL), beforeAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), beforeProvenance)
    }

    func testEvidenceChangedBeforePublishRejectsEntireMutation() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1", genotype: "A", sample: "Animal-1"
        )
        let cached = GenotypeMatrixReviewCapability.evaluate(
            selection: [target],
            evidence: .init([target: 5]),
            reviews: [],
            comments: [],
            isWritable: true
        )
        XCTAssertEqual(cached.falsePositive, .enabled)
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let before = try Data(contentsOf: annotationURL)

        do {
            try await store.setMatrixReview(
                .falsePositive,
                targets: [target],
                evidence: .init([target: 0]),
                author: "reviewer"
            )
            XCTFail("Expected publication-time evidence validation to fail")
        } catch let error as GenotypeMatrixReviewMutationError {
            XCTAssertEqual(error, .ineligibleEvidence)
        }

        XCTAssertTrue(store.sidecar.matrixReviews.isEmpty)
        XCTAssertEqual(try Data(contentsOf: annotationURL), before)
    }

    func testReviewReplacementAndClearAuditBeforeAndAfterValues() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1",
            genotype: "A",
            sample: "Animal-1",
            stableClusterID: "candidate-9"
        )

        try await store.setMatrixReview(
            .falsePositive,
            targets: [target],
            evidence: .init([target: 5]),
            author: "first"
        )
        try await store.setMatrixReview(
            .falseNegative,
            targets: [target],
            evidence: .init([target: 0]),
            author: "second"
        )
        try await store.clearMatrixReview(targets: [target], author: "third")

        XCTAssertTrue(store.sidecar.matrixReviews.isEmpty)
        let audit = Array(store.sidecar.auditLog.suffix(3))
        XCTAssertEqual(audit.map(\.action), ["setMatrixReview", "setMatrixReview", "clearMatrixReview"])
        XCTAssertEqual(audit.map(\.before), [nil, "falsePositive", "falseNegative"])
        XCTAssertEqual(audit.map(\.after), ["falsePositive", "falseNegative", nil])
        XCTAssertEqual(audit.map(\.author), ["first", "second", "third"])
        XCTAssertEqual(audit.map(\.rationale), Array(repeating: target.stableAuditDescription, count: 3))
    }

    func testCommentAddEditRemoveUsesOneCurrentValuePerTarget() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let publications = PublicationCounter()
        let store = try GenotypeAnnotationStore(
            bundleURL: dir,
            author: "construction",
            publicationFaultInjector: publications.inject
        )
        let target = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: "MHC-A1",
            genotype: "Mafa-A1*001:01",
            stableClusterID: "candidate-1"
        )

        try await store.upsertMatrixComment(body: "first complete body", targets: [target], author: "A")
        XCTAssertEqual(store.sidecar.matrixComments.map(\.body), ["first complete body"])
        try await store.upsertMatrixComment(body: "replacement complete body", targets: [target], author: "B")
        XCTAssertEqual(store.sidecar.matrixComments.map(\.body), ["replacement complete body"])
        try await store.removeMatrixComments(targets: [target], author: "C")

        XCTAssertTrue(store.sidecar.matrixComments.isEmpty)
        let audit = Array(store.sidecar.auditLog.suffix(3))
        XCTAssertEqual(audit.map(\.action), ["upsertMatrixComment", "upsertMatrixComment", "removeMatrixComment"])
        XCTAssertEqual(audit.map(\.before), [nil, "first complete body", "replacement complete body"])
        XCTAssertEqual(audit.map(\.after), ["first complete body", "replacement complete body", nil])
        XCTAssertEqual(audit.map(\.author), ["A", "B", "C"])
        XCTAssertEqual(publications.count, 3)
    }

    func testFirstLegacyCommentMutationCanonicalizesAndAuditsMissingHistory() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let seeded = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let target = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "Animal-1")
        let unrelated = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "Animal-2")
        var legacy = seeded.sidecar
        legacy.matrixComments = [
            .init(target: target, body: "superseded without audit", author: "legacy", timestamp: "2025-01-01T00:00:00Z"),
            .init(target: target, body: "current legacy", author: "legacy", timestamp: "2025-02-01T00:00:00Z"),
            .init(target: unrelated, body: "leave both 1", author: "legacy", timestamp: "2025-01-01T00:00:00Z"),
            .init(target: unrelated, body: "leave both 2", author: "legacy", timestamp: "2025-02-01T00:00:00Z"),
        ]
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try legacy.encoded().write(to: annotationURL, options: .atomic)
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "construction")

        try await store.upsertMatrixComment(body: "new current", targets: [target], author: "editor")

        XCTAssertEqual(store.sidecar.matrixComments.filter { $0.target == target }.map(\.body), ["new current"])
        XCTAssertEqual(
            store.sidecar.matrixComments.filter { $0.target == unrelated }.map(\.body),
            ["leave both 1", "leave both 2"]
        )
        let canonicalize = try XCTUnwrap(store.sidecar.auditLog.last {
            $0.action == "canonicalizeLegacyMatrixComments"
        })
        XCTAssertEqual(canonicalize.before, "superseded without audit")
        XCTAssertEqual(canonicalize.after, "current legacy")
        XCTAssertEqual(canonicalize.author, "editor")
        XCTAssertEqual(canonicalize.rationale, target.stableAuditDescription)
        XCTAssertEqual(store.sidecar.auditLog.last?.action, "upsertMatrixComment")
        XCTAssertEqual(store.sidecar.auditLog.last?.before, "current legacy")
        XCTAssertEqual(store.sidecar.auditLog.last?.after, "new current")
    }

    func testReadOnlyAndStaleRevisionPublishNothing() async throws {
        let dir = try makeBundleURL()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        _ = try GenotypeAnnotationStore(bundleURL: dir, author: "seed")
        let stale = try GenotypeAnnotationStore(bundleURL: dir, author: "stale")
        let fresh = try GenotypeAnnotationStore(bundleURL: dir, author: "fresh")
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A1", genotype: "A", sample: "Animal-1"
        )
        try await fresh.setMatrixReview(
            .falsePositive,
            targets: [target],
            evidence: .init([target: 5]),
            author: "fresh"
        )
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let provenanceURL = ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        let freshAnnotation = try Data(contentsOf: annotationURL)
        let freshProvenance = try Data(contentsOf: provenanceURL)

        do {
            try await stale.upsertMatrixComment(body: "stale edit", targets: [target], author: "stale")
            XCTFail("Expected stale revision rejection")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The genotype annotations changed in another process. Reload the bundle before saving this edit.")
        }
        XCTAssertEqual(try Data(contentsOf: annotationURL), freshAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), freshProvenance)
        XCTAssertEqual(stale.sidecar, fresh.sidecar)

        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: dir.path)
        let readOnly = try GenotypeAnnotationStore(bundleURL: dir, author: "read-only")
        XCTAssertTrue(readOnly.isReadOnly)
        do {
            try await readOnly.removeMatrixComments(targets: [target], author: "read-only")
            XCTFail("Expected read-only rejection")
        } catch let error as GenotypeMatrixReviewMutationError {
            XCTAssertEqual(error, .readOnly)
        }
        XCTAssertEqual(try Data(contentsOf: annotationURL), freshAnnotation)
        XCTAssertEqual(try Data(contentsOf: provenanceURL), freshProvenance)
    }

    func testEditTimeAuthorAppearsInAnnotationAuditAndProvenance() async throws {
        let dir = try makeBundleURL()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try GenotypeAnnotationStore(bundleURL: dir, author: "construction-author")
        let target = GenotypeAnnotationSidecar.MatrixTarget.column(sample: "Animal-1")

        try await store.upsertMatrixComment(
            body: "authored at edit time",
            targets: [target],
            author: "Resolved Analyst"
        )

        XCTAssertEqual(store.sidecar.matrixComments.last?.author, "Resolved Analyst")
        XCTAssertEqual(store.sidecar.auditLog.last?.author, "Resolved Analyst")
        let annotationURL = dir.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        ))
        XCTAssertEqual(envelope.options.explicit["resolvedAuthor"], .string("Resolved Analyst"))
        XCTAssertEqual(envelope.options.resolvedDefaults["author"], .string("Resolved Analyst"))
        XCTAssertEqual(envelope.runtimeIdentity.user, WorkflowRun.currentUser)
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertGreaterThanOrEqual(envelope.wallTimeSeconds ?? -1, 0)
    }
}
