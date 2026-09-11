import XCTest
import AppKit
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class GenotypeReviewedHaplotypeInferenceTests: GenotypeResultViewportTestCase {
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
        let analysis = GenotypeHaplotypeAnalyzer.analyze(
            calls: rawCalls,
            definitionSet: definition
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
        XCTAssertEqual(controller.testingCurrentCallEvidence?.h2Name, "-")
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
            "-"
        )

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
        XCTAssertEqual(first.testingCurrentCallEvidence?.h2Name, "-")

        let reopened = GenotypeResultViewController()
        _ = reopened.view
        reopened.configure(result: result)
        reopened.testingSelectCellEvidence(animalId: "AnimalA", locus: "MHC-A")
        flushMountedController(reopened)
        XCTAssertEqual(reopened.testingCurrentCallEvidence?.h2Name, "-")

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
