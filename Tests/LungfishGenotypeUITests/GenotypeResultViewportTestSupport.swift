import XCTest
import AppKit
import SwiftUI
import CryptoKit
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport

enum WorkbookSnapshotEncodingTestError: Error {
    case injected
}

@MainActor
final class MatrixWorkbookUpdateSchedulerSpy: GenotypeMatrixWorkbookUpdateScheduling {
    private final class Token: GenotypeMatrixWorkbookUpdateCancellation {
        var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    private var entries: [(token: Token, action: @MainActor () -> Void)] = []

    var scheduledCount: Int {
        entries.count
    }

    func schedule(_ action: @escaping @MainActor () -> Void) -> GenotypeMatrixWorkbookUpdateCancellation {
        let token = Token()
        entries.append((token, action))
        return token
    }

    func fireScheduledActions() {
        let pending = entries
        entries.removeAll()
        for entry in pending where !entry.token.isCancelled {
            entry.action()
        }
    }
}

@MainActor
final class MatrixContextMenuSnapshotSourceSpy:
    GenotypeMatrixContextMenuSnapshotProviding {
    private let snapshot: GenotypeMatrixContextMenuSnapshot
    private(set) var snapshotReadCount = 0

    init(snapshot: GenotypeMatrixContextMenuSnapshot) {
        self.snapshot = snapshot
    }

    var cachedSnapshot: GenotypeMatrixContextMenuSnapshot {
        snapshotReadCount += 1
        return snapshot
    }
}

@MainActor
final class MatrixProjectionManualNumericScheduler:
    GenotypeNumericFilterScheduling {
    private final class Token: GenotypeNumericFilterScheduled {
        let action: @MainActor () -> Void
        var isCancelled = false

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }

        func cancel() {
            isCancelled = true
        }
    }

    private var tokens: [Token] = []

    func schedule(
        after _: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any GenotypeNumericFilterScheduled {
        let token = Token(action: action)
        tokens.append(token)
        return token
    }

    func runPending() {
        let pending = tokens
        tokens.removeAll()
        for token in pending where !token.isCancelled {
            token.action()
        }
    }
}

@MainActor
class GenotypeResultViewportTestCase: XCTestCase {
    func makeSampleCurationWorkbench(
        typographyScale: CGFloat = 1
    ) -> GenotypeSampleCurationWorkbenchView {
        GenotypeSampleCurationWorkbenchView(
            headerView: NSView(),
            assignmentView: NSView(),
            evidenceView: NSView(),
            typographyScale: typographyScale
        )
    }


    func constraintsInHierarchy(_ view: NSView) -> [NSLayoutConstraint] {
        view.constraints + view.subviews.flatMap(constraintsInHierarchy)
    }


    func reviewSample(
        _ sample: String,
        loci: [String] = ["MHC-B"]
    ) -> GenotypeHaplotypeSampleAnalysis {
        GenotypeHaplotypeSampleAnalysis(
            sample: sample,
            calls: loci.map { locus in
                GenotypeHaplotypeLocusCall(
                    locus: locus,
                    sourceLocus: locus == "MHC-DRB" ? "Mafa-DRB" : "Mafa-B",
                    haplotype1: locus == "MHC-DRB" ? "ERR: TMH (M1DR, M2DR, M3DR)" : "ERR: TMH (M1B, M2B, M3B)",
                    haplotype2: locus == "MHC-DRB" ? "ERR: TMH (M1DR, M2DR, M3DR)" : "ERR: TMH (M1B, M2B, M3B)",
                    status: .tooManyHaplotypes,
                    matchedHaplotypes: [],
                    observedGenotypeCount: 4,
                    observedGenotypes: locus == "MHC-DRB" ? ["DRB1", "DRB2", "DRB3", "DRB4"] : ["B1", "B2", "B3", "B4"]
                )
            }
        )
    }


    func calledReviewSample(_ sample: String) -> GenotypeHaplotypeSampleAnalysis {
        GenotypeHaplotypeSampleAnalysis(
            sample: sample,
            calls: [
                GenotypeHaplotypeLocusCall(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotype1: "M3B",
                    haplotype2: "-",
                    status: .called,
                    matchedHaplotypes: [],
                    observedGenotypeCount: 1,
                    observedGenotypes: ["12_M3_B_075_01"]
                )
            ]
        )
    }


    struct SampleComparisonSessionSnapshot {
        let workbench: ObjectIdentifier?
        let editorHost: ObjectIdentifier?
        let editorModel: ObjectIdentifier?
        let trailingModel: ObjectIdentifier?
        let comparisonModel: ObjectIdentifier?
        let comboIdentities: [ObjectIdentifier]
        let controlIdentities: [String: ObjectIdentifier]
    }

    func assertSampleComparisonProjectionPreservesMountedSession(
        prepare: (
            GenotypeResultViewController,
            GenotypeComparisonMatrixView
        ) -> Void = { _, _ in },
        trigger: (
            GenotypeResultViewController,
            GenotypeComparisonMatrixView
        ) -> Void
    ) throws {
        let root = try TestTempDirectory.make(prefix: "SampleComparisonProjection")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        func call(_ sample: String, _ genotype: String, _ reads: Int)
            -> ONTGenotypeCall
        {
            ONTGenotypeCall(
                sample: sample,
                genotype: genotype,
                passedAlignments: reads,
                passedUniqueReads: reads,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: 100,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        }
        let calls = [
            call("AnimalA", "01_Mafa_A1_SHARED", 25),
            call("AnimalB", "01_Mafa_A1_SHARED", 4),
            call("AnimalB", "02_Mafa_A1_SOURCE", 8),
            call("AnimalA", "03_Mafa_B_TARGET", 5),
            call("AnimalB", "03_Mafa_B_TARGET", 5),
            call("AnimalC", "04_Mafa_B_OTHER", 30),
        ]
        let controller = GenotypeResultViewController()
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 1_200,
                height: 900
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls
        ))
        let matrix = controller.testingComparisonMatrix
        prepare(controller, matrix)
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        flushMountedController(controller)
        XCTAssertTrue(controller.testingPerformManualHaplotypeCompareAction())
        flushMountedController(controller)
        XCTAssertTrue(
            controller.testingPerformSampleComparisonSourceSelection(
                "AnimalB"
            )
        )
        flushMountedController(controller)
        controller.testingUpdateManualHaplotypeLabel("Persistent draft")
        let combo = try XCTUnwrap(
            controller.testingFirstManualHaplotypeComboBox
        )
        XCTAssertTrue(window.makeFirstResponder(combo))
        let snapshot = SampleComparisonSessionSnapshot(
            workbench: controller.testingSampleWorkbenchIdentity,
            editorHost: controller.testingManualHaplotypeEditorHostIdentity,
            editorModel: controller.testingManualHaplotypeEditorModelIdentity,
            trailingModel:
                controller.testingSampleCurationTrailingModelIdentity,
            comparisonModel:
                controller.testingSampleComparisonModelIdentity,
            comboIdentities:
                controller.testingManualHaplotypeComboIdentities,
            controlIdentities:
                controller.testingSampleCurationControlIdentities
        )

        trigger(controller, matrix)
        flushMountedController(controller)

        XCTAssertEqual(controller.testingSampleCurationTrailingMode, .compareAndCopy)
        XCTAssertEqual(controller.testingSampleWorkbenchIdentity, snapshot.workbench)
        XCTAssertEqual(
            controller.testingManualHaplotypeEditorHostIdentity,
            snapshot.editorHost
        )
        XCTAssertEqual(
            controller.testingManualHaplotypeEditorModelIdentity,
            snapshot.editorModel
        )
        XCTAssertEqual(
            controller.testingSampleCurationTrailingModelIdentity,
            snapshot.trailingModel
        )
        XCTAssertEqual(
            controller.testingSampleComparisonModelIdentity,
            snapshot.comparisonModel
        )
        XCTAssertEqual(
            controller.testingManualHaplotypeComboIdentities,
            snapshot.comboIdentities
        )
        XCTAssertEqual(
            controller.testingSampleCurationControlIdentities,
            snapshot.controlIdentities
        )
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(
            controller.testingManualHaplotypeDraftLabel(
                locus: .a,
                slot: .h1
            ),
            "Persistent draft"
        )
        XCTAssertTrue(
            window.firstResponder === combo
                || combo.currentEditor() === window.firstResponder
        )
        XCTAssertEqual(
            controller.testingSampleComparisonRowIDs,
            matrix.testingVisibleRows
                .filter {
                    $0.support(for: "AnimalA") != nil
                        || $0.support(for: "AnimalB") != nil
                }
                .map(\.id)
        )
    }


    func flushMountedController(
        _ controller: GenotypeResultViewController
    ) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        controller.view.layoutSubtreeIfNeeded()
    }


    func makeManySampleMatrix(sampleCount: Int) -> GenotypeComparisonMatrixView {
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeManySampleResult(sampleCount: sampleCount))
        return matrix
    }


    func makeManySampleResult(sampleCount: Int) -> ONTGenotypeResultBundleData {
        let genotype = "12_M3_B_075_01"
        var calls: [ONTGenotypeCall] = []
        var samples: [ONTGenotypeSampleResult] = []
        for i in 0..<sampleCount {
            let name = String(format: "SAMPLE_%03d", i)
            let call = makeCall(sample: name, genotype: genotype, reads: 100 + i)
            calls.append(call)
            samples.append(ONTGenotypeSampleResult(
                sample: name,
                passedAlignments: 100 + i,
                passedUniqueReads: 100 + i,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [call]
            ))
        }
        return makeResult(samples: samples, calls: calls)
    }


    func makeRetainedDemuxSizedMatrix() -> GenotypeComparisonMatrixView {
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeRetainedDemuxSizedResult())
        return matrix
    }


    func makeRetainedDemuxSizedResult() -> ONTGenotypeResultBundleData {
        var calls: [ONTGenotypeCall] = []
        var callsBySample: [String: [ONTGenotypeCall]] = [:]
        for sampleIndex in 0..<52 {
            let sample = "LF\(2800 + sampleIndex)"
            for genotypeIndex in 0..<120 {
                let locus = genotypeIndex.isMultiple(of: 2) ? "A1" : "DQB1"
                let reads = genotypeIndex.isMultiple(of: 17) ? 1 : 100
                let call = ONTGenotypeCall(
                    sample: sample,
                    genotype: String(
                        format: "%02d_Mafa_%@_%03d_01",
                        genotypeIndex % 20,
                        locus,
                        genotypeIndex
                    ),
                    passedAlignments: reads,
                    passedUniqueReads: reads,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedReads: 12_000,
                    sampleUniqueRetainedPercent: nil,
                    overallInputReads: nil,
                    overallUniqueRetainedReads: nil,
                    overallUniqueRetainedPercent: nil
                )
                calls.append(call)
                callsBySample[sample, default: []].append(call)
            }
        }
        let samples = callsBySample.keys.sorted().map { sample in
            ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: 12_000,
                passedUniqueReads: 12_000,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: callsBySample[sample] ?? []
            )
        }
        return makeResult(samples: samples, calls: calls)
    }


    func makeManyRowComparisonMatrix(sampleCount: Int = 2) -> GenotypeComparisonMatrixView {
        let matrix = GenotypeComparisonMatrixView()
        var calls: [ONTGenotypeCall] = []
        let sampleNames = (0..<sampleCount).map { "Sample\($0)" }
        var callsBySample = Array(repeating: [ONTGenotypeCall](), count: sampleCount)

        for index in 0..<32 {
            let genotype = String(format: "Mafa-AG*%02d:01", index)
            for (sampleIndex, sample) in sampleNames.enumerated() {
                let call = makeCall(sample: sample, genotype: genotype, reads: 100 + sampleIndex + index)
                calls.append(call)
                callsBySample[sampleIndex].append(call)
            }
        }

        let samples = sampleNames.enumerated().map { sampleIndex, sample in
            ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: 100 + sampleIndex,
                passedUniqueReads: 100 + sampleIndex,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: callsBySample[sampleIndex]
            )
        }
        matrix.configure(result: makeResult(samples: samples, calls: calls))
        return matrix
    }


    func sampleCellFontPointSize(in table: GenotypeResultTableView) throws -> CGFloat {
        let column = try XCTUnwrap(table.tableView.tableColumns.first {
            $0.identifier.rawValue == "sample"
        })
        let cell = try XCTUnwrap(
            table.tableView(table.tableView, viewFor: column, row: 0) as? NSTableCellView
        )
        return try XCTUnwrap(cell.textField?.font).pointSize
    }


    func makeStaleSampleDetailOverrideFixture() throws -> (
        root: URL,
        bundleURL: URL,
        controller: GenotypeResultViewController,
        analysis: GenotypeHaplotypeAnalysis
    ) {
        let root = try TestTempDirectory.make(prefix: "GenotypeSampleDetailStaleOverride")
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        try installCallOverrideManifest(in: bundleURL)
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-08-03T00:00:00Z"
        )
        sidecar.callOverrides = [
            .init(
                sample: "DW472",
                locus: "MHC-DP",
                slot: .h1,
                originalCall: "revision-6-baseline",
                overrideCall: "revision-6-override",
                reasonTag: .analystJudgment,
                rationale: "Belonged to revision 6",
                author: "Earlier Analyst",
                timestamp: "2026-08-03T00:30:00Z",
                analysisIdentity: .init(
                    assayID: "MHC-exon2-miSeq",
                    analysisRevisionID: "revision-6",
                    definitionSetID:
                        "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
                ),
                operationID: "revision-6-operation"
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            forBundleAt: bundleURL
        )
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID:
                "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                .init(sample: "DW472", calls: [
                    .init(
                        locus: "MHC-DP",
                        sourceLocus: "Mafa-DP",
                        haplotype1: "M4DP",
                        haplotype2: "M7DP",
                        status: .tooManyHaplotypes,
                        matchedHaplotypes: [],
                        observedGenotypeCount: 3,
                        observedGenotypes: [
                            "15_M3_DPA1_01", "15_M7_DPB1_01",
                        ]
                    ),
                ]),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            haplotypeAnalysis: analysis
        ))
        return (root, bundleURL, controller, analysis)
    }


    func assertRefinedManualCurationIsAbsent(
        kind: GenotypeResultWorkflowKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let manifest = ONTGenotypeResultBundleManifest(
            kind: kind.rawValue,
            workflowKind: kind,
            workflowMode: .haplotyped,
            outputName: kind.rawValue,
            analysisName: kind.rawValue,
            primaryWorkbookPath: "current.xlsx",
            longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [call],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis(),
            manifest: manifest
        ))
        let matrix = controller.testingComparisonMatrix
        matrix.testingResetManualHaplotypeAutoFitMeasurementCounts()
        controller.testingSetManualHaplotypeBandDisclosureExpanded(true)
        matrix.testingSetManualHaplotypeBandTypographyScale(2)
        controller.testingSelectMatrixColumn(sample: "AnimalA")

        let header = try XCTUnwrap(
            matrix.testingFixedHeaderSnapshot(sample: "AnimalA"),
            kind.rawValue,
            file: file,
            line: line
        )
        XCTAssertTrue(
            header.manualSectionRect.isEmpty,
            kind.rawValue,
            file: file,
            line: line
        )
        XCTAssertTrue(
            matrix.testingManualHaplotypeAutoFitMeasurementCounts.isEmpty,
            kind.rawValue,
            file: file,
            line: line
        )
        XCTAssertNil(
            controller.testingManualHaplotypeEditorModelIdentity,
            kind.rawValue,
            file: file,
            line: line
        )
        XCTAssertNil(
            controller.testingSampleComparisonModelIdentity,
            kind.rawValue,
            file: file,
            line: line
        )
        XCTAssertFalse(
            controller.testingPerformManualHaplotypeCompareAction(),
            kind.rawValue,
            file: file,
            line: line
        )
    }


    func assertManualDisclosurePreservesViewport(
        _ matrix: GenotypeComparisonMatrixView,
        anchor: GenotypeMatrixSemanticScrollSnapshot,
        targets: [GenotypeAnnotationSidecar.MatrixTarget],
        samples: [String],
        genotypes: [String],
        sort: String?,
        filter: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.rowID,
            anchor.rowID,
            file: file,
            line: line
        )
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.withinRowOffset,
            anchor.withinRowOffset,
            accuracy: 0.01,
            file: file,
            line: line
        )
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.leadingSampleID,
            anchor.leadingSampleID,
            file: file,
            line: line
        )
        XCTAssertEqual(
            matrix.testingSemanticScrollAnchor.withinSampleOffset,
            anchor.withinSampleOffset,
            accuracy: 0.01,
            file: file,
            line: line
        )
        XCTAssertEqual(
            matrix.testingSelectedMatrixTargets,
            targets,
            file: file,
            line: line
        )
        XCTAssertEqual(
            matrix.testingVisibleSampleColumnTitles,
            samples,
            file: file,
            line: line
        )
        XCTAssertEqual(
            matrix.testingVisibleGenotypes,
            genotypes,
            file: file,
            line: line
        )
        XCTAssertEqual(
            matrix.testingActiveSortDescriptorKey,
            sort,
            file: file,
            line: line
        )
        XCTAssertEqual(
            matrix.testingFilterModelText,
            filter,
            file: file,
            line: line
        )
    }


    func assertRenderedEvidenceSubmissionRetainsPendingDraft(
        _ view: GenotypeCallEvidenceView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 1_600)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        flushRenderedMutationHost(host)
        let apply = try XCTUnwrap(
            renderedMutationButton(
                "genotype-call-evidence-apply-pending",
                in: host
            ),
            "Expected rendered Apply pending button after staging A3.",
            file: file,
            line: line
        )
        XCTAssertTrue(window.makeFirstResponder(apply), file: file, line: line)

        apply.performClick(nil)
        flushRenderedMutationHost(host)

        let retained = try XCTUnwrap(
            renderedMutationButton(
                "genotype-call-evidence-apply-pending",
                in: host
            ),
            "Expected failed/no-op Apply pending to retain its draft.",
            file: file,
            line: line
        )
        XCTAssertTrue(retained === apply, file: file, line: line)
        XCTAssertTrue(window.firstResponder === apply, file: file, line: line)
        retained.performClick(nil)
        flushRenderedMutationHost(host)
        XCTAssertTrue(
            renderedMutationButton(
                "genotype-call-evidence-apply-pending",
                in: host
            ) === apply,
            file: file,
            line: line
        )
    }


    func assertRenderedSampleDetailSaveRetainsDraft(
        _ view: GenotypeSampleDetailSheet,
        row: GenotypeSampleDetailSheet.CallRow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 1_200)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        flushRenderedMutationHost(host)
        let editIdentifier = "genotype-sample-detail-edit-"
            + "\(row.locus)-\(row.slot.rawValue)"
        let edit = try XCTUnwrap(
            renderedMutationButton(editIdentifier, in: host),
            "Expected rendered detail-sheet Edit control.",
            file: file,
            line: line
        )
        edit.performClick(nil)
        flushRenderedMutationHost(host)
        let save = try XCTUnwrap(
            renderedMutationButton("genotypeOverrideSaveButton", in: host),
            "Expected rendered detail-sheet Save control.",
            file: file,
            line: line
        )
        XCTAssertTrue(window.makeFirstResponder(save), file: file, line: line)

        save.performClick(nil)
        flushRenderedMutationHost(host)

        let retained = try XCTUnwrap(
            renderedMutationButton("genotypeOverrideSaveButton", in: host),
            "Expected failed/no-op Save to retain its draft.",
            file: file,
            line: line
        )
        XCTAssertTrue(retained === save, file: file, line: line)
        XCTAssertTrue(window.firstResponder === save, file: file, line: line)
        retained.performClick(nil)
        flushRenderedMutationHost(host)
        XCTAssertTrue(
            renderedMutationButton("genotypeOverrideSaveButton", in: host)
                === save,
            file: file,
            line: line
        )
    }


    func renderedMutationButton(
        _ identifier: String,
        in root: NSView
    ) -> NSButton? {
        descendants(of: root).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == identifier
        }
    }


    func flushRenderedMutationHost(_ host: NSView) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        host.layoutSubtreeIfNeeded()
    }


    struct SynchronizedMiSeqFixture {
        let root: URL
        let bundleURL: URL
        let result: ONTGenotypeResultBundleData
    }

    func makeSynchronizedMiSeqFixture()
        throws -> SynchronizedMiSeqFixture {
        let root = try TestTempDirectory.make(prefix: "GenotypeMiSeqSynchronizedEdits")
        let bundleURL = root.appendingPathComponent(
            "fixture.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        try installCallOverrideManifest(in: bundleURL)
        let rawCalls = [
            makeCall(sample: "Sample-A", genotype: "A-genotype", reads: 11),
            makeCall(sample: "Sample-B", genotype: "B-genotype", reads: 13),
        ]
        let samples = ["Sample-A", "Sample-B"].map { sample in
            let calls = rawCalls.filter { $0.sample == sample }
            return ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: calls.reduce(0) { $0 + $1.passedAlignments },
                passedUniqueReads: calls.reduce(0) { $0 + $1.passedUniqueReads },
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls
            )
        }
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test.haplotype-definitions",
            definitionSetName: "Test haplotype definitions",
            speciesName: "Test species",
            samples: [
                .init(sample: "Sample-A", calls: [
                    .init(
                        locus: "MHC-A", sourceLocus: "Mafa-A",
                        haplotype1: "A1", haplotype2: "A2",
                        status: .called, matchedHaplotypes: [],
                        observedGenotypeCount: 2,
                        observedGenotypes: ["A1-read", "A2-read"]
                    ),
                    .init(
                        locus: "MHC-B", sourceLocus: "Mafa-B",
                        haplotype1: "B1", haplotype2: "B2",
                        status: .called, matchedHaplotypes: [],
                        observedGenotypeCount: 2,
                        observedGenotypes: ["B1-read", "B2-read"]
                    ),
                ]),
                .init(sample: "Sample-B", calls: [
                    .init(
                        locus: "MHC-A", sourceLocus: "Mafa-A",
                        haplotype1: "C1", haplotype2: "C2",
                        status: .called, matchedHaplotypes: [],
                        observedGenotypeCount: 2,
                        observedGenotypes: ["C1-read", "C2-read"]
                    ),
                    .init(
                        locus: "MHC-B", sourceLocus: "Mafa-B",
                        haplotype1: "D1", haplotype2: "D2",
                        status: .called, matchedHaplotypes: [],
                        observedGenotypeCount: 2,
                        observedGenotypes: ["D1-read", "D2-read"]
                    ),
                ]),
            ]
        )
        return SynchronizedMiSeqFixture(
            root: root,
            bundleURL: bundleURL,
            result: makeResult(
                bundleURL: bundleURL,
                samples: samples,
                calls: rawCalls,
                haplotypeAnalysis: analysis
            )
        )
    }


    func makeResult(
        bundleURL: URL = URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
        samples: [ONTGenotypeSampleResult],
        calls: [ONTGenotypeCall],
        kind: String = GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil,
        haplotypeDefinitionSetID: String? = nil,
        mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest? = nil,
        mhcCandidateGenBankArtifactURLs: ONTMHCCandidateGenBankArtifactURLs = .empty,
        mhcAlignmentArtifactURLs: ONTMHCAlignmentArtifactURLs = .empty,
        stats: ONTGenotypeRunStats = ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 60),
        referenceMetadata: ONTGenotypeReferenceMetadata? = nil,
        mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact? = nil,
        provisionalExon2SequencesByGenotype:
            [String: ONTGenotypeProvisionalExon2Sequence] = [:],
        provisionalExon2ArtifactURLs:
            ONTGenotypeProvisionalExon2ArtifactURLs = .empty,
        manifest: ONTGenotypeResultBundleManifest? = nil,
        reviewableRowCatalog: GenotypeReviewableRowCatalog? = nil
    ) -> ONTGenotypeResultBundleData {
        GenotypeTestFixtures.makeResult(
            bundleURL: bundleURL,
            samples: samples,
            calls: calls,
            kind: kind,
            haplotypeAnalysis: haplotypeAnalysis,
            haplotypeDefinitionSetID: haplotypeDefinitionSetID,
            mhcCandidateArtifacts: mhcCandidateArtifacts,
            mhcCandidateGenBankArtifactURLs: mhcCandidateGenBankArtifactURLs,
            mhcAlignmentArtifactURLs: mhcAlignmentArtifactURLs,
            stats: stats,
            referenceMetadata: referenceMetadata,
            mhcReferenceVisualizations: mhcReferenceVisualizations,
            provisionalExon2SequencesByGenotype: provisionalExon2SequencesByGenotype,
            provisionalExon2ArtifactURLs: provisionalExon2ArtifactURLs,
            manifest: manifest,
            reviewableRowCatalog: reviewableRowCatalog
        )
    }


    func makeEmptyHaplotypeAnalysis() -> GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test.haplotype-definitions",
            definitionSetName: "Test haplotype definitions",
            speciesName: "Test species",
            samples: []
        )
    }


    func makeUsableHaplotypedMiSeqAnalysis(
        sample: String = "AnimalA"
    ) -> GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test.haplotype-definitions",
            definitionSetName: "Test haplotype definitions",
            speciesName: "Test species",
            samples: [
                .init(sample: sample, calls: [
                    .init(
                        locus: "MHC-A",
                        sourceLocus: "Mafa-A",
                        haplotype1: "M1A",
                        haplotype2: "M2A",
                        status: .called,
                        matchedHaplotypes: [],
                        observedGenotypeCount: 2,
                        observedGenotypes: ["A1", "A2"]
                    ),
                ]),
            ]
        )
    }


    func makeMHCReferenceVisualizationRecord(
        rawReferenceID: String,
        alleleName: String
    ) -> ONTMHCReferenceVisualizationRecord {
        ONTMHCReferenceVisualizationRecord(
            rawReferenceID: rawReferenceID,
            sourceOrdinal: 1,
            alleleName: alleleName,
            locus: alleleName.components(separatedBy: "*").first,
            sequence: "ACGTACGTACGT",
            sequenceSHA256: "test-checksum",
            recordFields: ["definition": ["Synthetic known allele"]],
            features: [],
            annotatedTranslation: nil,
            genBankText: "LOCUS       \(rawReferenceID) 12 bp DNA\n//\n",
            fastaText: ">\(rawReferenceID) \(alleleName)\nACGTACGTACGT\n",
            roles: [ONTMHCReferenceVisualizationRoleAssignment(
                role: .exactKnownCall,
                candidateStableClusterIDs: []
            )]
        )
    }


    func knownAlleleDetails(in root: NSView) -> [GenotypeKnownAlleleDetailView] {
        ([root] + descendants(of: root)).compactMap { $0 as? GenotypeKnownAlleleDetailView }
    }


    func candidateAlleleDetails(in root: NSView) -> [GenotypeCandidateAlleleDetailView] {
        ([root] + descendants(of: root)).compactMap { $0 as? GenotypeCandidateAlleleDetailView }
    }


    func onlyAlleleSequenceDetail(
        in root: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> GenotypeAlleleSequenceDetailView? {
        let details = ([root] + descendants(of: root))
            .compactMap { $0 as? GenotypeAlleleSequenceDetailView }
        XCTAssertEqual(details.count, 1, file: file, line: line)
        return details.first
    }


    func onlyKnownAlleleDetail(
        in root: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> GenotypeKnownAlleleDetailView? {
        let details = knownAlleleDetails(in: root)
        XCTAssertEqual(details.count, 1, file: file, line: line)
        return details.first
    }


    func onlyCandidateAlleleDetail(
        in root: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> GenotypeCandidateAlleleDetailView? {
        let details = candidateAlleleDetails(in: root)
        XCTAssertEqual(details.count, 1, file: file, line: line)
        return details.first
    }


    func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }


    func firstAncestor<View: NSView>(
        of view: NSView,
        ofType type: View.Type
    ) -> View? {
        var current = view.superview
        while let ancestor = current {
            if let match = ancestor as? View {
                return match
            }
            current = ancestor.superview
        }
        return nil
    }


    func activeConstraints(in root: NSView) -> [NSLayoutConstraint] {
        ([root] + descendants(of: root)).flatMap(\.constraints).filter(\.isActive)
    }


    func text(_ identifier: String, in root: NSView?) -> String? {
        guard let root else { return nil }
        return ([root] + descendants(of: root))
            .first { $0.accessibilityIdentifier() == identifier }
            .flatMap { ($0 as? NSTextField)?.stringValue }
    }


    func visibleText(in root: NSView) -> String {
        ([root] + descendants(of: root))
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .map(\.stringValue)
            .joined(separator: "\n")
    }


    func assertNoKnownAggregateEvidence(
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for phrase in [
            "Support Summary", "Unique Reads", "Alignments", "Support Metric",
            "Anchor Evidence", "Same-Locus Co-occurrence", "Supporting Samples",
            "Top Sample", "Aggregate Samples", "Aggregate Unique Reads", "Aggregate Alignments",
        ] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(phrase), phrase, file: file, line: line)
        }
        let lines = Set(text.components(separatedBy: .newlines))
        for label in ["Support", "Samples"] {
            XCTAssertFalse(lines.contains(label), label, file: file, line: line)
        }
    }


    func makeGenBankReferenceMetadata() -> ONTGenotypeReferenceMetadata {
        let fields = [
            GenBankRecordDatabase.FieldDefinition(key: "feature.allele", displayTitle: "Allele", valueType: "text", sourceCategory: "feature", preferredOrder: 0),
            GenBankRecordDatabase.FieldDefinition(key: "source.organism", displayTitle: "Organism", valueType: "text", sourceCategory: "source", preferredOrder: 1),
            GenBankRecordDatabase.FieldDefinition(key: "feature.product", displayTitle: "Product", valueType: "text", sourceCategory: "feature", preferredOrder: 2),
            GenBankRecordDatabase.FieldDefinition(key: "record.definition", displayTitle: "Definition", valueType: "text", sourceCategory: "record", preferredOrder: 3),
        ]
        return ONTGenotypeReferenceMetadata(
            fields: fields,
            recordsBySequenceName: [
                "NHP01222": [
                    "feature.allele": "Mafa-A1*001:01",
                    "source.organism": "Macaca fascicularis",
                    "feature.product": "MHC class I A1 antigen",
                    "record.definition": "Mafa-A1 complete coding sequence",
                ],
                "NHP99999": [
                    "feature.allele": "Mafa-B*002:01",
                    "source.organism": "Macaca fascicularis",
                    "feature.product": "MHC class I B antigen",
                    "record.definition": "Mafa-B complete coding sequence",
                ],
            ],
            alleleFieldKey: "feature.allele"
        )
    }


    func makeCandidateResult(
        bundleURL: URL = URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
        calls: [ONTGenotypeCall],
        candidates: [ONTMHCCandidateRecord],
        observations: [ONTMHCCandidateObservation],
        candidateSequences: [String: String] = [:],
        mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact? = nil,
        integrityWarnings: [ONTGenotypeIntegrityWarning] = [],
        candidateDocumentSchemaVersion: Int = 1,
        candidateArtifactManifestSchemaVersion: Int = 1,
        referenceMetadata: ONTGenotypeReferenceMetadata? = nil,
        mhcCandidateGenBankArtifactURLs: ONTMHCCandidateGenBankArtifactURLs = .empty,
        provisionalExon2SequencesByGenotype:
            [String: ONTGenotypeProvisionalExon2Sequence] = [:],
        kind: GenotypeResultWorkflowKind = .fullLengthONTMHCGenotype,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis? = nil
    ) -> ONTGenotypeResultBundleData {
        let sampleIDs = Set(calls.map(\.sample) + observations.map(\.sampleID))
        let samples = sampleIDs.sorted().map { sample in
            let sampleCalls = calls.filter { $0.sample == sample }
            return ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: sampleCalls.reduce(0) { $0 + $1.passedAlignments },
                passedUniqueReads: sampleCalls.reduce(0) { $0 + $1.passedUniqueReads },
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: sampleCalls
            )
        }
        let candidateReference = ONTMHCArtifactReference(
            path: "artifacts/candidates/candidates.json",
            sha256: String(repeating: "c", count: 64),
            sizeBytes: 1
        )
        let fastaReference = ONTMHCArtifactReference(
            path: "artifacts/candidates/candidates.fasta",
            sha256: String(repeating: "d", count: 64),
            sizeBytes: 1
        )
        let base = makeResult(
            bundleURL: bundleURL,
            samples: samples,
            calls: calls,
            kind: kind.rawValue,
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest(
                schemaVersion: candidateArtifactManifestSchemaVersion,
                genotypingEvidence: ONTMHCBAMArtifactPair(
                    bam: .init(path: "artifacts/alignments/genotyping-evidence.bam", sha256: String(repeating: "e", count: 64), sizeBytes: 2),
                    bai: .init(path: "artifacts/alignments/genotyping-evidence.bam.bai", sha256: String(repeating: "f", count: 64), sizeBytes: 3)
                ),
                reciprocalEvidence: ONTMHCBAMArtifactPair(
                    bam: .init(path: "artifacts/alignments/unmatched-to-reference.bam", sha256: String(repeating: "1", count: 64), sizeBytes: 4),
                    bai: .init(path: "artifacts/alignments/unmatched-to-reference.bam.bai", sha256: String(repeating: "2", count: 64), sizeBytes: 5)
                ),
                candidateJSON: candidateReference,
                candidateFASTA: fastaReference,
                unnameableJSON: nil,
                unnameableFASTA: nil
            ),
            referenceMetadata: referenceMetadata,
            provisionalExon2SequencesByGenotype:
                provisionalExon2SequencesByGenotype
        )
        let document = ONTMHCCandidateAllelesDocument(
            schemaVersion: candidateDocumentSchemaVersion,
            createdAt: "2026-07-20T00:00:00Z",
            thresholds: .defaults,
            inputs: [],
            evidence: [],
            sequenceFASTA: .init(path: "candidates.fasta", sha256: String(repeating: "a", count: 64), sizeBytes: 1),
            candidates: candidates,
            observations: observations
        )
        return ONTGenotypeResultBundleData(
            bundleURL: base.bundleURL,
            manifest: base.manifest,
            artifacts: base.artifacts,
            stats: base.stats,
            calls: calls,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidates: document,
            mhcUnnameableClusters: nil,
            mhcCandidateSequencesByStableClusterID: candidateSequences,
            mhcCandidateGenBankArtifactURLs: mhcCandidateGenBankArtifactURLs,
            mhcAlignmentArtifactURLs: base.mhcAlignmentArtifactURLs,
            mhcReferenceVisualizations: mhcReferenceVisualizations,
            integrityWarnings: integrityWarnings,
            referenceMetadata: referenceMetadata,
            provisionalExon2SequencesByGenotype:
                provisionalExon2SequencesByGenotype,
            provisionalExon2ArtifactURLs:
                base.provisionalExon2ArtifactURLs
        )
    }


    func makeCandidateReferenceVisualizationRecord(
        rawReferenceID: String,
        alleleName: String,
        stableClusterID: String
    ) -> ONTMHCReferenceVisualizationRecord {
        let sequence = String(repeating: "A", count: 2_000)
        return ONTMHCReferenceVisualizationRecord(
            rawReferenceID: rawReferenceID,
            sourceOrdinal: 1,
            alleleName: alleleName,
            locus: "MHC-A1",
            sequence: sequence,
            sequenceSHA256: "test-checksum",
            recordFields: ["definition": ["Synthetic closest reference"]],
            features: [],
            annotatedTranslation: nil,
            genBankText: "LOCUS       \(rawReferenceID) 2000 bp DNA\n//\n",
            fastaText: ">\(rawReferenceID) \(alleleName)\n\(sequence)\n",
            roles: [.init(
                role: .closestNovelReference,
                candidateStableClusterIDs: [stableClusterID]
            )]
        )
    }


    func makeSequenceDetailCandidateResult(
        includeKnown: Bool = false,
        includeInvalidCandidate: Bool = false
    ) throws -> (
        root: URL,
        result: ONTGenotypeResultBundleData
    ) {
        let root = try TestTempDirectory.make(prefix: "GenotypeSequenceDetail")
        let bundleURL = root.appendingPathComponent("fixture.lungfishgenotype", isDirectory: true)
        let candidateURL = bundleURL.appendingPathComponent(
            "artifacts/candidates/candidate_alleles.gb"
        )
        try FileManager.default.createDirectory(
            at: candidateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sequence = "ACGTACGT"
        var genBankText = """
        LOCUS       candidate-accession 8 bp DNA linear
        DEFINITION  Exact candidate record.
        ACCESSION   candidate-accession
        FEATURES             Location/Qualifiers
             CDS             1..8
                             /allele="Mafa-A1*001:01_1nt_nov"
        ORIGIN
                1 acgtacgt
        //
        """
        if includeInvalidCandidate {
            genBankText += """

            LOCUS       invalid-accession 8 bp DNA linear
            DEFINITION  Checksum-invalid candidate record.
            ACCESSION   invalid-accession
            ORIGIN
                    1 cccccccc
            //
            """
        }
        try genBankText.write(to: candidateURL, atomically: true, encoding: .utf8)
        let checksum = SHA256.hash(data: Data(sequence.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let stableID = "candidate-stable"
        let candidate = makeCandidate(
            id: stableID,
            name: "Mafa-A1*001:01_1nt_nov",
            classification: .novel,
            support: .singleton,
            samples: ["AnimalA"],
            fastaRecordID: "candidate-accession",
            sequenceSHA256: checksum
        )
        let invalidCandidate = makeCandidate(
            id: "candidate-invalid",
            name: "Mafa-A1*002:01_1nt_nov",
            classification: .novel,
            support: .singleton,
            samples: ["AnimalA"],
            fastaRecordID: "invalid-accession",
            sequenceSHA256: checksum
        )
        let closest = makeCandidateReferenceVisualizationRecord(
            rawReferenceID: "closest-reference",
            alleleName: "Mafa-A1*001:01",
            stableClusterID: stableID
        )
        let known = makeMHCReferenceVisualizationRecord(
            rawReferenceID: "known-a",
            alleleName: "Mafa-A1*000:01"
        )
        return (
            root,
            makeCandidateResult(
                bundleURL: bundleURL,
                calls: includeKnown
                    ? [makeCall(sample: "AnimalA", genotype: "known-a", reads: 6)]
                    : [],
                candidates: includeInvalidCandidate ? [candidate, invalidCandidate] : [candidate],
                observations: [
                    makeCandidateObservation(cluster: stableID, sample: "AnimalA", reads: 5),
                ] + (includeInvalidCandidate
                    ? [makeCandidateObservation(
                        cluster: "candidate-invalid",
                        sample: "AnimalA",
                        reads: 4
                    )]
                    : []),
                mhcReferenceVisualizations: .init(
                    schemaVersion: 1,
                    records: includeKnown ? [known, closest] : [closest]
                ),
                referenceMetadata: includeKnown ? ONTGenotypeReferenceMetadata(
                    fields: [.init(
                        key: "feature.allele",
                        displayTitle: "Allele",
                        valueType: "text",
                        sourceCategory: "feature",
                        preferredOrder: 0
                    )],
                    recordsBySequenceName: [
                        "known-a": ["feature.allele": "Mafa-A1*000:01"],
                    ],
                    alleleFieldKey: "feature.allele"
                ) : nil,
                mhcCandidateGenBankArtifactURLs: .init(
                    candidateAlleles: candidateURL,
                    unnameableClusters: nil,
                    candidateFASTA: nil,
                    unnameableFASTA: nil
                )
            )
        )
    }


    func makeCandidate(
        id: String,
        name: String,
        classification: ONTMHCCandidateClassification,
        support: ONTMHCCandidateSupportClass,
        samples: [String],
        fastaRecordID: String? = nil,
        sequenceSHA256: String = String(repeating: "b", count: 64)
    ) -> ONTMHCCandidateRecord {
        ONTMHCCandidateRecord(
            stableClusterID: id,
            provisionalName: name,
            locus: "MHC-A1",
            classification: classification,
            supportClass: support,
            closestReferenceName: "Mafa-A1*018:01:01:01",
            closestReferenceClass: .genomicDNA,
            snpCount: classification == .novel ? 5 : 0,
            insertedBases: 0,
            deletedBases: 0,
            longGapBases: classification == .extension ? 100 : 0,
            comparableBases: 2_000,
            shorterCoverage: 1,
            identity: 0.99,
            mappingQuality: 60,
            alignmentScore: 2_000,
            independentSampleCount: samples.count,
            occurrenceCount: samples.count,
            totalClusterReads: samples.count * 5,
            supportingSampleIDs: samples,
            fastaRecordID: fastaRecordID ?? id,
            sequenceSHA256: sequenceSHA256,
            selectedEvidence: .init(
                bamPath: "artifacts/alignments/unmatched-to-reference.bam",
                queryName: id,
                referenceName: "Mafa-A1*018:01:01:01",
                readGroupID: nil,
                referenceStart: 1,
                cigar: "2000M"
            )
        )
    }


    func makeCandidateObservation(
        cluster: String,
        sample: String,
        reads: Int,
        evidenceCount: Int = 1
    ) -> ONTMHCCandidateObservation {
        let evidence = (0..<evidenceCount).map { index in
            ONTMHCEvidenceLocator(
                bamPath: "artifacts/alignments/genotyping-evidence.bam",
                queryName: evidenceCount == 1
                    ? "\(cluster)|\(sample)"
                    : "\(cluster)|\(sample)|\(index)",
                referenceName: "Mafa-A1*018:01:01:01",
                readGroupID: sample,
                referenceStart: 1,
                cigar: "2000M"
            )
        }
        return ONTMHCCandidateObservation(
            stableClusterID: cluster,
            sampleID: sample,
            readGroupID: sample,
            sourceClusterIDs: ["source-\(cluster)-\(sample)"],
            sourceClusterReadCounts: ["source-\(cluster)-\(sample)": reads],
            aggregatedSampleReadCount: reads,
            evidence: evidence
        )
    }


    func makeCall(sample: String, genotype: String, reads: Int) -> ONTGenotypeCall {
        GenotypeTestFixtures.makeCall(sample: sample, genotype: genotype, reads: reads)
    }


    func makeWeakSupportAnalysis(
        h1: String,
        h2: String,
        h1Allele: String,
        h2Allele: String
    ) -> GenotypeHaplotypeAnalysis {
        GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: h1,
                            haplotype2: h2,
                            status: .called,
                            matchedHaplotypes: [
                                GenotypeHaplotypeMatchedDefinition(
                                    name: h1,
                                    diagnosticAlleles: [h1Allele],
                                    observedDiagnosticAlleles: [h1Allele]
                                ),
                                GenotypeHaplotypeMatchedDefinition(
                                    name: h2,
                                    diagnosticAlleles: [h2Allele],
                                    observedDiagnosticAlleles: [h2Allele]
                                ),
                            ],
                            observedGenotypeCount: 2,
                            observedGenotypes: [h1Allele, h2Allele]
                        )
                    ]
                )
            ]
        )
    }


    func makeCustomHaplotypeDefinitionSet(
        id: String,
        haplotypeName: String,
        diagnosticAllele: String
    ) -> GenotypeHaplotypeDefinitionSet {
        makeCustomHaplotypeDefinitionSet(
            id: id,
            haplotypeName: haplotypeName,
            diagnosticAlleles: [diagnosticAllele]
        )
    }


    func makeCustomHaplotypeDefinitionSet(
        id: String,
        haplotypeName: String,
        diagnosticAlleles: [String]
    ) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id,
            assayID: "custom-assay",
            displayName: "Custom Test Definition",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(
                            name: haplotypeName,
                            diagnosticAlleles: diagnosticAlleles
                        )
                    ]
                )
            ]
        )
    }


    func installCallOverrideManifest(in bundleURL: URL) throws {
        try Data(#"{"analysis":"viewport-test-fixture"}"#.utf8).write(
            to: bundleURL.appendingPathComponent(
                ONTGenotypeResultBundleManifest.filename
            )
        )
    }

    // MARK: - Modal-hazard hardening

    /// `GenotypeResultViewController.presentManualHaplotypeDraftDecision` shows a
    /// real, blocking `NSAlert` ("Save Haplotype Assignment Changes?") whenever a
    /// manual-haplotype draft is dirty and no testing decision provider has been
    /// installed on that controller instance. The provider
    /// (`testingSetManualHaplotypeDraftDecisionProvider`) is a per-instance,
    /// last-write-wins closure — it is NOT global/static state, so installing a
    /// default here cannot retroactively cover a controller a test already built
    /// with the bare `GenotypeResultViewController()` initializer, and it can
    /// never clobber a provider a test installs on its own controller afterward.
    ///
    /// Any new test that constructs a controller and may dirty a manual-haplotype
    /// draft should prefer this factory over the bare initializer: it returns a
    /// controller pre-armed with a safe default (`.cancel`) so a forgotten
    /// `testingSetManualHaplotypeDraftDecisionProvider` call can never surface a
    /// real blocking alert. Tests that need to observe or steer the decision call
    /// `testingSetManualHaplotypeDraftDecisionProvider` afterward as usual — that
    /// call always wins because it runs strictly after this default is installed.
    func makeManualHaplotypeGuardedController() -> GenotypeResultViewController {
        let controller = GenotypeResultViewController()
        controller.testingSetManualHaplotypeDraftDecisionProvider { _ in
            .cancel
        }
        return controller
    }
}

@MainActor
final class MutableGenotypeTextSizePreference {
    var value: ContentTextSizePreference

    init(_ value: ContentTextSizePreference) {
        self.value = value
    }
}

@MainActor
final class MutableGenotypePreferredFonts: ContentPreferredFontProviding {
    var pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
    }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .monospaced:
            return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: pointSize, weight: .semibold)
        default:
            return .systemFont(ofSize: pointSize)
        }
    }

    func canonicalUnscaledPointSize(for role: ContentTypography.Role) -> CGFloat {
        13
    }
}

actor DeferredGenotypeResultLoader {
    private var hasStarted = false
    private(set) var invocationCount = 0
    private var continuation: CheckedContinuation<ONTGenotypeResultBundleData, Never>?

    func load(_ url: URL) async -> ONTGenotypeResultBundleData {
        invocationCount += 1
        hasStarted = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !hasStarted {
            await Task.yield()
        }
    }

    func currentInvocationCount() -> Int {
        invocationCount
    }

    func resume(returning result: ONTGenotypeResultBundleData) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

actor KnownSelectionResultLoaderSpy {
    private let result: ONTGenotypeResultBundleData
    private(set) var invocationCount = 0

    init(result: ONTGenotypeResultBundleData) {
        self.result = result
    }

    func load(_ url: URL) -> ONTGenotypeResultBundleData {
        invocationCount += 1
        return result
    }

    func currentInvocationCount() -> Int {
        invocationCount
    }
}

actor ManualHaplotypeViewportDecisionGate {
    private var continuation:
        CheckedContinuation<GenotypeManualHaplotypeDraftDecision, Never>?

    func wait() async -> GenotypeManualHaplotypeDraftDecision {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilPending() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resume(with decision: GenotypeManualHaplotypeDraftDecision) {
        continuation?.resume(returning: decision)
        continuation = nil
    }
}

@MainActor
final class FixedViewportIntrinsicView: NSView {
    private let height: CGFloat

    init(height: CGFloat) {
        self.height = height
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height)
    }
}

@MainActor
final class EvidenceAvailableHeightSpy:
    NSView,
    GenotypeSupportedAllelesAvailableHeightReceiving
{
    private(set) var availableHeight: CGFloat = 0
    private(set) var usesCompactHeight = false

    func updateSupportedAllelesAvailableHeight(
        _ availableHeight: CGFloat,
        compact: Bool
    ) {
        self.availableHeight = availableHeight
        usesCompactHeight = compact
    }
}

@MainActor
final class RecordingGenotypeSearchAnnouncements:
    AccessibilityAnnouncementPosting {
    private(set) var messages: [String] = []

    func post(
        _ message: String,
        priority _: ContentAccessibilityAnnouncementPriority
    ) {
        messages.append(message)
    }
}

extension GenotypeHaplotypeTapeView.Cell {
    var testingLabel: String? {
        switch self {
        case .reference(_, let label),
             .weakReference(_, let label),
             .manual(_, let label),
             .recombinant(_, _, let label),
             .notAssayed(let label),
             .error(let label):
            return label
        case .empty, .unanalyzed:
            return nil
        }
    }

    var testingIsError: Bool {
        if case .error = self { return true }
        return false
    }

    var testingIsWeakSupport: Bool {
        if case .weakReference = self { return true }
        return false
    }
}

extension NSColor {
    var testingSRGBComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }
}

extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }
        return nil
    }
}
