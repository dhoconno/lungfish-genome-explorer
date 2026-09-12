import XCTest
import AppKit
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class GenotypeReviewedHaplotypeInferenceTests: GenotypeResultViewportTestCase {
    func testExcelReviewOnlyRecomputesCallsBeforeRefreshAndAfterReload() throws {
        try exerciseExcelEvidenceImport(mixed: false)
    }

    func testExcelMixedReviewOverrideAndCommentSurviveRecomputeAndReload() throws {
        try exerciseExcelEvidenceImport(mixed: true)
    }

    private func exerciseExcelEvidenceImport(mixed: Bool) throws {
        let root = try TestTempDirectory.make(prefix: "ExcelEvidenceImport")
        defer { TestTempDirectory.cleanup(root) }
        try installCallOverrideManifest(in: root)
        let definition = makeDefinition()
        try writeDefinitionSnapshot(definition, to: root)
        let rawCalls = [
            makeCall(sample: "AnimalA", genotype: "01_M1_A_marker", reads: 100),
            makeCall(sample: "AnimalA", genotype: "02_M2_A_marker", reads: 3),
        ]
        let result = makeResult(
            bundleURL: root,
            samples: [.init(sample: "AnimalA", passedAlignments: 103, passedUniqueReads: 103,
                            sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: rawCalls)],
            calls: rawCalls,
            haplotypeAnalysis: GenotypeHaplotypeAnalyzer.analyze(calls: rawCalls, definitionSet: definition)
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectCellEvidence(animalId: "AnimalA", locus: "MHC-A")
        flushMountedController(controller)
        let python = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_TEST_PYTHON"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/envs/openpyxl/bin/python3").path)
        let workbook = root.appendingPathComponent("current.xlsx")
        func run(_ code: String) throws {
            let process = Process()
            process.executableURL = python
            process.arguments = ["-c", "import sys,json\np=sys.argv[1]\n" + code, workbook.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try run("from openpyxl import Workbook\nw=Workbook(); w.active.title='Reads'; w.active.append(['Genotype','Reads']); w.active.append(['01_M1_A_marker',100]); w.active.append(['02_M2_A_marker',3])\n"
            + GenotypeEditableWorkbookService.seedScript
            + "\nseed_editable_tables(w, [{'sample':'AnimalA','locus':'MHC-A','haplotype1':'M1A','haplotype2':'M2A','baselineHaplotype1':'M1A','baselineHaplotype2':'M2A'}], {}, {'samples':['AnimalA'],'rows':[{'locus':'MHC-A','display_name':'02_M2_A_marker','support_by_sample':[{'sample':'AnimalA','support':3}]}]}); w.save(p)")
        let service = GenotypeEditableWorkbookService(pythonExecutableURL: python)
        try service.attestGeneratedWorkbook(workbookURL: workbook, bundleURL: root)
        var edit = "from openpyxl import load_workbook\nw=load_workbook(p)\nfor row in w['Edit Matrix'].iter_rows(min_row=2):\n if json.loads(row[1].value).get('kind') == 'cell':\n  row[5].value='set'; row[6].value='false-positive'\n"
        if mixed {
            edit += "  row[7].value='set'; row[8].value='Reviewed contaminant in Excel'\nw['Edit Calls']['G3']='set'; w['Edit Calls']['H3']='M3A'\n"
        }
        try run(edit + "w.save(p)")
        let inspection = try service.inspect(bundleURL: root)
        XCTAssertEqual(inspection.changes.count, mixed ? 3 : 1)
        try controller.acceptEditableWorkbook(inspection, using: service)
        let accepted = try XCTUnwrap(controller.testingCurrentWorkbookHaplotypeCalls().first)
        XCTAssertEqual(accepted.baselineHaplotype2, "-", "Excel FP review must recompute the raw evidence baseline before refresh")
        XCTAssertEqual(accepted.haplotype2, mixed ? "M3A" : "M1A")
        XCTAssertEqual(controller.testingCurrentCallEvidence?.observedGenotypes, ["01_M1_A_marker"])
        let reopened = GenotypeResultViewController()
        _ = reopened.view
        reopened.configure(result: result)
        reopened.testingSelectCellEvidence(animalId: "AnimalA", locus: "MHC-A")
        flushMountedController(reopened)
        let reloaded = try XCTUnwrap(reopened.testingCurrentWorkbookHaplotypeCalls().first)
        XCTAssertEqual(reloaded.baselineHaplotype2, "-")
        XCTAssertEqual(reloaded.haplotype2, mixed ? "M3A" : "M1A", "Accepted same-batch override must remain authoritative after evidence recompute")
        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(forBundleAt: root)
        XCTAssertEqual(sidecar.matrixReviews.first?.disposition, .falsePositive)
        if mixed {
            XCTAssertEqual(sidecar.matrixComments.first?.body, "Reviewed contaminant in Excel")
            XCTAssertEqual(sidecar.callOverrides.first?.overrideCall, "M3A")
        }
    }

    func testFalsePositiveRefreshesEvidenceAndWorkbookProjectionButPreservesRawCalls() throws {
        let root = try TestTempDirectory.make(prefix: "ReviewedHaplotypeInference")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent(
            "reviewed.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        try installCallOverrideManifest(in: bundleURL)
        let definition = makeDefinition()
        try writeDefinitionSnapshot(definition, to: bundleURL)
        let retained = makeCall(
            sample: "AnimalA",
            genotype: "01_M1_A_marker",
            reads: 100
        )
        let contaminant = makeCall(
            sample: "AnimalA",
            genotype: "02_M2_A_marker",
            reads: 3
        )
        let rawCalls = [retained, contaminant]
        let initialAnalysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: rawCalls,
            definitionSet: definition
        )
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: initialAnalysis.assayID,
            definitionSetID: initialAnalysis.definitionSetID,
            definitionSetName: initialAnalysis.definitionSetName,
            speciesName: initialAnalysis.speciesName,
            generatedAt: initialAnalysis.generatedAt,
            analysisRevisionID: "persisted-before-review",
            source: initialAnalysis.source,
            samples: initialAnalysis.samples
        )
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [
                .init(
                    sample: "AnimalA",
                    passedAlignments: 103,
                    passedUniqueReads: 103,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: rawCalls
                ),
            ],
            calls: rawCalls,
            haplotypeAnalysis: analysis
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: result)
        controller.testingSelectCellEvidence(animalId: "AnimalA", locus: "MHC-A")
        flushMountedController(controller)

        XCTAssertEqual(controller.testingCurrentCallEvidence?.h1Name, "M1A")
        XCTAssertEqual(controller.testingCurrentCallEvidence?.h2Name, "M2A")
        XCTAssertEqual(
            controller.testingCurrentCallEvidence?.observedGenotypes,
            rawCalls.map(\.genotype)
        )
        let originalWorkbookCalls = controller.testingCurrentWorkbookHaplotypeCalls()
        XCTAssertEqual(originalWorkbookCalls.count, 1)
        XCTAssertEqual(originalWorkbookCalls.first?.haplotype1, "M1A")
        XCTAssertEqual(originalWorkbookCalls.first?.haplotype2, "M2A")

        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: contaminant.genotype,
            sample: "AnimalA"
        )
        controller.applyMatrixReview(.init(
            targets: [target],
            intent: .set(.falsePositive)
        ))

        XCTAssertEqual(controller.testingCurrentCallEvidence?.h1Name, "M1A")
        XCTAssertEqual(controller.testingCurrentCallEvidence?.h2Name, "M1A")
        XCTAssertEqual(
            controller.testingCurrentCallEvidence?.observedGenotypes,
            [retained.genotype]
        )
        let retainedRawEvidence = controller.testingCurrentCallEvidence?.animalGenotypes.first {
            $0.genotype == contaminant.genotype
        }
        XCTAssertEqual(retainedRawEvidence?.reads, contaminant.passedUniqueReads)
        XCTAssertEqual(
            controller.testingCurrentCallEvidence?.omittedHaplotypeGenotypes.map(\.genotype),
            [contaminant.genotype]
        )
        XCTAssertEqual(
            controller.testingCurrentCallEvidence?.omittedHaplotypeGenotypes.first?.reason,
            "marked false positive"
        )
        XCTAssertEqual(
            controller.testingCurrentWorkbookHaplotypeCalls().first?.haplotype1,
            "M1A"
        )
        XCTAssertEqual(
            controller.testingCurrentWorkbookHaplotypeCalls().first?.haplotype2,
            "M1A"
        )
        let captured = try XCTUnwrap(controller.testingCurrentExportSnapshot())
        let capturedCall = try XCTUnwrap(captured.haplotypeCalls?.first)
        XCTAssertEqual(capturedCall.sample, "AnimalA")
        XCTAssertEqual(capturedCall.locus, "MHC-A")
        XCTAssertEqual(capturedCall.haplotype1, "M1A")
        XCTAssertEqual(capturedCall.haplotype2, "M1A")
        XCTAssertEqual(capturedCall.haplotype1Status, "called")
        XCTAssertEqual(capturedCall.haplotype2Status, "called")
        XCTAssertEqual(capturedCall.baselineHaplotype1, "M1A")
        XCTAssertEqual(capturedCall.baselineHaplotype2, "-")
        XCTAssertEqual(captured.sourceRevision, .init(
            assayID: definition.assayID,
            analysisRevisionID: nil,
            definitionSetID: definition.id
        ))
        let capturedSidecar = try GenotypeAnnotationSidecar.decode(
            XCTUnwrap(captured.annotationSidecarData)
        )
        XCTAssertEqual(capturedSidecar.matrixReviews.map(\.target), [target])
        let projection = GenotypeViewProjectionSerializer.makeProjection(
            from: captured
        )
        XCTAssertEqual(projection.haplotypeCalls?.first, capturedCall)
        XCTAssertEqual(projection.sourceRevision, captured.sourceRevision)

        // A review exclusion changes inference only; an explicit call
        // override remains authoritative over that derived projection.
        controller.testingApplyOverrideFromInspector(
            haplotype: "M2A",
            slot: .h2
        )
        XCTAssertEqual(controller.testingCurrentCallEvidence?.h2Name, "M2A")
        XCTAssertEqual(
            controller.testingCurrentWorkbookHaplotypeCalls().first?.haplotype2,
            "M2A"
        )
        XCTAssertEqual(rawCalls, [retained, contaminant])

        let persisted = try ONTGenotypeResultBundleData
            .loadOrCreateAnnotationSidecar(forBundleAt: bundleURL)
        XCTAssertEqual(persisted.matrixReviews.map(\.target), [target])
        XCTAssertEqual(
            persisted.matrixReviews.map(\.disposition),
            [.falsePositive]
        )
    }

    func testReopeningUsesPersistedFalsePositiveAndClearingRestoresDerivedCall() throws {
        let root = try TestTempDirectory.make(prefix: "ReviewedHaplotypeReopen")
        defer { TestTempDirectory.cleanup(root) }
        let bundleURL = root.appendingPathComponent(
            "reviewed.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        try installCallOverrideManifest(in: bundleURL)
        let definition = makeDefinition()
        try writeDefinitionSnapshot(definition, to: bundleURL)
        let rawCalls = [
            makeCall(sample: "AnimalA", genotype: "01_M1_A_marker", reads: 100),
            makeCall(sample: "AnimalA", genotype: "02_M2_A_marker", reads: 3),
        ]
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [
                .init(
                    sample: "AnimalA",
                    passedAlignments: 103,
                    passedUniqueReads: 103,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: rawCalls
                ),
            ],
            calls: rawCalls,
            haplotypeAnalysis: GenotypeHaplotypeAnalyzer.analyze(
                calls: rawCalls,
                definitionSet: definition
            )
        )
        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "02_M2_A_marker",
            sample: "AnimalA"
        )
        let first = GenotypeResultViewController()
        _ = first.view
        first.configure(result: result)
        first.testingSelectCellEvidence(animalId: "AnimalA", locus: "MHC-A")
        flushMountedController(first)
        first.applyMatrixReview(.init(
            targets: [target],
            intent: .set(.falsePositive)
        ))
        XCTAssertEqual(first.testingCurrentCallEvidence?.h2Name, "M1A")

        let reopened = GenotypeResultViewController()
        _ = reopened.view
        reopened.configure(result: result)
        reopened.testingSelectCellEvidence(animalId: "AnimalA", locus: "MHC-A")
        flushMountedController(reopened)
        XCTAssertEqual(reopened.testingCurrentCallEvidence?.h2Name, "M1A")

        reopened.applyMatrixReview(.init(
            targets: [target],
            intent: .clear
        ))
        XCTAssertEqual(reopened.testingCurrentCallEvidence?.h1Name, "M1A")
        XCTAssertEqual(reopened.testingCurrentCallEvidence?.h2Name, "M2A")
        XCTAssertEqual(
            reopened.testingCurrentWorkbookHaplotypeCalls().first?.haplotype2,
            "M2A"
        )
    }

    private func makeDefinition() -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: "reviewed-evidence-test",
            assayID: "MHC-exon2-miSeq",
            displayName: "Reviewed evidence test",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                .init(
                    locus: "MHC-A",
                    sourceLocus: "Mafa-A",
                    haplotypes: [
                        .init(
                            name: "M1A",
                            diagnosticAlleles: ["01_M1_A_marker"],
                            minimumMatches: 1
                        ),
                        .init(
                            name: "M2A",
                            diagnosticAlleles: ["02_M2_A_marker"],
                            minimumMatches: 1
                        ),
                    ]
                ),
            ]
        )
    }

    private func writeDefinitionSnapshot(
        _ definition: GenotypeHaplotypeDefinitionSet,
        to bundleURL: URL
    ) throws {
        let inputsURL = bundleURL
            .appendingPathComponent(".amplicon-genotyping", isDirectory: true)
            .appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inputsURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(definition)
        try data.write(
            to: inputsURL.appendingPathComponent("haplotype-definition.json")
        )
    }
}
