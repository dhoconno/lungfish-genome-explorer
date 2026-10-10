import XCTest
import AppKit
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
@testable import LungfishGenotypeUI

/// The first manual haplotype save on a genotype-only bundle that has no
/// annotations.json. A genotype-only result leaves the workflow without one and
/// opening it writes none, so every such bundle meets this case on its first
/// save. In the GUI walk of 2026-10-10, WALK3 typed in MHC-A H1 of walk-geno
/// stayed Unsaved after Save Assignments and after Save in the export alert,
/// and only the publication lock file appeared. The store refuses with
/// missingPriorSidecar, because the replay of a manual haplotype replacement
/// starts from the bytes of the file. Every other manual haplotype save test
/// writes an empty sidecar before it saves, so none of them covered this case.
/// The class also covers a first call override on a store without cohorts,
/// which shares the fix, and a save after another process deleted the file.
@MainActor
final class GenotypeManualHaplotypeFirstSaveTests: GenotypeResultViewportTestCase {
    private let sample = "SIMULATED-MHC-A-pairs"
    private let otherSample = "SIMULATED-MHC-B-pairs"
    private let genotype = "01_Mafa_A1_001_01"

    func testFirstReplacementOnABundleWithoutASidecarPublishesTheAssignment() throws {
        let fixture = try makeFreshGenotypeOnlyBundle()
        defer { TestTempDirectory.cleanup(fixture.root) }
        // The viewer opens a genotype-only bundle without the built-in cohorts.
        let store = try GenotypeAnnotationStore(
            bundleURL: fixture.bundleURL,
            author: "Analyst",
            seedBuiltInSmartCohorts: false
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.annotationURL.path))

        let result = try store.replaceManualHaplotypeAssignments(
            for: sample,
            with: [
                ManualHaplotypeAssignment(
                    sample: sample,
                    locus: "MHC-A",
                    slot: .h1,
                    label: "WALK3",
                    colorTokenIndex: 12,
                    diagnosticAlleles: [],
                    notes: ""
                ),
            ],
            copySource: nil,
            author: "Analyst"
        )

        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.added.map(\.label), ["WALK3"])
        XCTAssertEqual(store.sidecar.manualHaplotypeAssignments.map(\.label), ["WALK3"])
        let persisted = try ONTGenotypeResultBundleData
            .loadOrCreateAnnotationSidecar(forBundleAt: fixture.bundleURL)
        XCTAssertEqual(persisted.manualHaplotypeAssignments.map(\.label), ["WALK3"])
        // The record beside the file is the replayable record of this edit.
        let record = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.provenanceURL)
            ) as? [String: Any]
        )
        let options = record["options"] as? [String: Any]
        let explicit = options?["explicit"] as? [String: Any]
        let action = explicit?["action"] as? [String: Any]
        XCTAssertEqual(action?["value"] as? String, "replaceManualHaplotypeAssignments")
    }

    /// The replay of a manual haplotype replacement checks the exact bytes of
    /// its prior file, and a fresh bundle has no file. So the first save writes
    /// the sidecar the analyst sees just before the edit, and the record names
    /// that sidecar as the prior and embeds its bytes. For a genotype-only
    /// bundle it is the empty sidecar with the published file's generatedAt. A
    /// replay from the post-save bundle puts the embedded prior back, reads it
    /// as `lungfish-cli genotype replay-manual-haplotype-assignments` does and
    /// reproduces the published file byte for byte.
    func testAReplayFromThePostSaveBundleReproducesTheFirstSave() throws {
        let fixture = try makeFreshGenotypeOnlyBundle()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let store = try GenotypeAnnotationStore(
            bundleURL: fixture.bundleURL,
            author: "Analyst",
            seedBuiltInSmartCohorts: false
        )
        try store.replaceManualHaplotypeAssignments(
            for: sample,
            with: [
                ManualHaplotypeAssignment(
                    sample: sample,
                    locus: "MHC-A",
                    slot: .h1,
                    label: "WALK3",
                    colorTokenIndex: 12,
                    diagnosticAlleles: [],
                    notes: ""
                ),
            ],
            copySource: nil,
            author: "Analyst"
        )
        let publishedData = try Data(contentsOf: fixture.annotationURL)
        let published = try GenotypeAnnotationSidecar.decode(publishedData)
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: fixture.provenanceURL)
        )
        let payloadData = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(
            envelope.options.explicit["replayPayloadBase64"]?.stringValue
        )))
        let payload = try GenotypeManualHaplotypeAssignmentReplayPayload
            .decode(payloadData)

        let priorData = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(
            envelope.options.explicit["replayPriorSidecarBase64"]?.stringValue
        )))

        // The recorded prior is the empty sidecar written just before the edit.
        var emptyPrior = GenotypeAnnotationSidecar.empty(generatedAt: published.generatedAt)
        try emptyPrior.promoteToCurrentSchema()
        XCTAssertEqual(priorData, try emptyPrior.encoded())
        XCTAssertEqual(payload.priorSidecar.revisionSHA256, sha256Hex(priorData))
        XCTAssertEqual(payload.beforeAssignments, [])
        XCTAssertEqual(payload.afterAssignments, published.manualHaplotypeAssignments)

        // Replay from the post-save bundle with the embedded prior back in place.
        try priorData.write(to: fixture.annotationURL, options: .atomic)
        let snapshot = try ONTGenotypeResultBundleData
            .loadAnnotationSidecarSnapshot(forBundleAt: fixture.bundleURL)
        let replayed = try payload.applying(
            to: XCTUnwrap(snapshot.data),
            targetBundleURL: fixture.bundleURL,
            targetManifestData: ONTGenotypeResultBundle
                .readManifestDataNoFollow(from: fixture.bundleURL)
        )
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            replayed,
            expectedRevision: snapshot.revision,
            forBundleAt: fixture.bundleURL
        )
        XCTAssertEqual(try Data(contentsOf: fixture.annotationURL), publishedData)
    }

    func testSaveAssignmentsOnAFreshGenotypeOnlyBundleKeepsTheLabel() throws {
        let fixture = try makeFreshGenotypeOnlyBundle()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = makeManualHaplotypeGuardedController()
        _ = controller.view
        controller.configure(result: fixture.result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.annotationURL.path))

        controller.testingShowMatrixTargetSelection([.column(sample: sample)])
        XCTAssertEqual(controller.testingManualHaplotypeEditorSample, sample)
        controller.testingUpdateManualHaplotypeLabel("WALK3")
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertTrue(controller.testingManualHaplotypeEditorCanSave)

        controller.testingSaveManualHaplotypeDraft()

        XCTAssertNil(controller.testingManualHaplotypeEditorPersistenceError)
        XCTAssertFalse(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(controller.testingManualHaplotypeAssignments.map(\.label), ["WALK3"])
        XCTAssertEqual(
            controller.testingComparisonMatrix
                .testingManualHaplotypeBandValues(sample: sample).first,
            "WALK3 · —"
        )
        let persisted = try ONTGenotypeResultBundleData
            .loadOrCreateAnnotationSidecar(forBundleAt: fixture.bundleURL)
        XCTAssertEqual(persisted.manualHaplotypeAssignments.map(\.label), ["WALK3"])
    }

    /// The walk's second path. Export to Excel with WALK3 unsaved raises the
    /// alert, and Save there now keeps the label and opens the export sheet.
    func testSaveInTheExportAlertOnAFreshBundleSavesAndOpensTheSheet() async throws {
        let fixture = try makeFreshGenotypeOnlyBundle()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let controller = makeManualHaplotypeGuardedController()
        _ = controller.view
        controller.configure(result: fixture.result)
        controller.testingShowMatrixTargetSelection([.column(sample: sample)])
        controller.testingUpdateManualHaplotypeLabel("WALK3")
        var transitions: [String] = []
        controller.testingSetManualHaplotypeDraftDecisionProvider { transition in
            transitions.append(transition.rawValue)
            return .save
        }
        var panels = 0
        controller.excelSavePanelPresenter = { _, _, completion in
            panels += 1
            completion(nil)
        }

        controller.presentExcelExportPanel(expectedDisplayState: controller.testingDisplayState)
        await controller.testingWaitForManualHaplotypeTransitions()

        XCTAssertEqual(transitions, ["export"])
        XCTAssertEqual(panels, 1, "the export sheet opens after the save")
        XCTAssertFalse(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertNil(controller.testingManualHaplotypeEditorPersistenceError)
        let persisted = try ONTGenotypeResultBundleData
            .loadOrCreateAnnotationSidecar(forBundleAt: fixture.bundleURL)
        XCTAssertEqual(persisted.manualHaplotypeAssignments.map(\.label), ["WALK3"])
    }

    /// A bundle whose annotations.json was deleted after the store read it is
    /// not a fresh bundle. The viewed sidecar no longer matches the missing
    /// file, so the store refuses the save as stale and writes nothing.
    func testASaveAfterTheSidecarWasDeletedIsRefusedAsStaleAndWritesNothing() throws {
        let fixture = try makeFreshGenotypeOnlyBundle()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let store = try GenotypeAnnotationStore(
            bundleURL: fixture.bundleURL,
            author: "Analyst",
            seedBuiltInSmartCohorts: false
        )
        try store.replaceManualHaplotypeAssignments(
            for: sample,
            with: [assignment("WALK3")],
            copySource: nil,
            author: "Analyst"
        )
        // Another process deletes the file the store last read.
        try FileManager.default.removeItem(at: fixture.annotationURL)
        let recordBefore = try Data(contentsOf: fixture.provenanceURL)

        XCTAssertThrowsError(try store.replaceManualHaplotypeAssignments(
            for: sample,
            with: [assignment("WALK4")],
            copySource: nil,
            author: "Analyst"
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The genotype annotations changed in another process. Reload the bundle before saving this edit."
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.annotationURL.path))
        XCTAssertEqual(try Data(contentsOf: fixture.provenanceURL), recordBefore)
    }

    /// Call overrides share the helper. Before it, only a store holding unsaved
    /// built-in cohorts published the viewed sidecar first, so a store opened
    /// without them refused a first override with missingPriorSidecar.
    func testAFirstCallOverrideOnAStoreWithoutCohortsPublishesTheViewedSidecarFirst() throws {
        let fixture = try makeFreshGenotypeOnlyBundle()
        defer { TestTempDirectory.cleanup(fixture.root) }
        let store = try GenotypeAnnotationStore(
            bundleURL: fixture.bundleURL,
            author: "Analyst",
            seedBuiltInSmartCohorts: false
        )

        let result = try store.mutateCallOverrides(
            [
                CallOverrideMutation(
                    target: .init(sample: sample, locus: "MHC-A", slot: .h1),
                    baseline: "M1A",
                    after: "M2A",
                    reason: .analystJudgment,
                    rationale: "First override on a bundle without annotations.json."
                ),
            ],
            author: "Analyst",
            analysisIdentity: nil
        )

        XCTAssertTrue(result.didChange)
        let written = try GenotypeAnnotationSidecar.decode(
            Data(contentsOf: fixture.annotationURL)
        )
        XCTAssertEqual(written.callOverrides.map(\.overrideCall), ["M2A"])
        XCTAssertEqual(written, store.sidecar)
    }

    private func assignment(_ label: String) -> ManualHaplotypeAssignment {
        ManualHaplotypeAssignment(
            sample: sample,
            locus: "MHC-A",
            slot: .h1,
            label: label,
            colorTokenIndex: 12,
            diagnosticAlleles: [],
            notes: ""
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Fixture {
        let root: URL
        let bundleURL: URL
        let annotationURL: URL
        let provenanceURL: URL
        let result: ONTGenotypeResultBundleData
    }

    /// A MiSeq genotype-only bundle as the workflow leaves it, with its
    /// manifest and no annotations.json beside it.
    private func makeFreshGenotypeOnlyBundle() throws -> Fixture {
        let root = try TestTempDirectory.make(prefix: "ManualHaplotypeFirstSave")
        let bundleURL = root.appendingPathComponent(
            "walk-geno.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let kind = GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype
        let manifest = ONTGenotypeResultBundleManifest(
            kind: kind.rawValue,
            workflowKind: kind,
            workflowMode: .genotypeOnly,
            outputName: "walk-geno",
            analysisName: "walk-geno",
            primaryWorkbookPath: "walk-geno.xlsx",
            longSummaryCSVPath: "walk-geno.retained_demux_genotypes.csv",
            sampleSummaryCSVPath: "walk-geno.retained_demux_samples.csv",
            statsJSONPath: "walk-geno.retained_demux_stats.json",
            provenancePath: "walk-geno.retained_demux_provenance.json"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(sample: sample, genotype: genotype, reads: 42),
                makeCall(sample: otherSample, genotype: genotype, reads: 17),
            ],
            manifest: manifest
        )
        XCTAssertEqual(
            GenotypeManualHaplotypeEligibility.evaluate(result),
            .eligible(resultKind: kind)
        )
        let annotationURL = ONTGenotypeResultBundleData
            .annotationSidecarURL(forBundleAt: bundleURL)
        return Fixture(
            root: root,
            bundleURL: bundleURL,
            annotationURL: annotationURL,
            provenanceURL: ProvenanceRecorder.fileSidecarURL(for: annotationURL),
            result: result
        )
    }
}
