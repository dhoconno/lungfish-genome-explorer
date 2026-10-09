// GenotypeCharacterizationExtractionScenarios.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The fixtures behind the characterization tests of the three genotype
// responsibilities Phase 4a extracts next: the matrix projection, review
// eligibility and the haplotype-band disclosure (Phase 2.3, REVIEW.md R6).
// They follow the rules of GenotypeCharacterizationScenarios.swift. Everything
// that varies run to run is pinned before configure, nothing is loaded from
// Tests/Fixtures, every bundle lives under a test temp root, no NSWindow is
// opened, and every `testing*` call the tests make goes through these files
// or the test files beside them, so a later extraction rewires one place.

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishGenotypeUI

// MARK: - P1, the matrix projection

/// The names of the matrix projection fixture, shared with its test.
enum GenotypeMatrixProjectionNames {
    static let rowA1 = "01_Mafa_A1_001_01"
    static let rowA2 = "02_Mafa_A1_002_01"
    static let rowB1 = "03_Mafa_B_075_01"
    static let rowB2 = "04_Mafa_B_082_01"
    static let sharedCluster = "cluster-shared"
    static let sharedName = "Mafa-A1*nov-01"
    static let singletonCluster = "cluster-single"
    static let singletonName = "Mafa-A1*ext-01"
    static let spanCluster = "cluster-span"
    static let spanName = "Mafa-A1*span-01"
    static let animals = ["AnimalA", "AnimalB", "AnimalC", "AnimalD"]
    static let alleleFieldKey = "feature.allele"
}

/// A standalone comparison matrix over a full-length ONT result with known
/// calls, two candidates, one interpreted incomplete-span cluster, a duplicate
/// occurrence (reads 17 and 91), a zero-read call, a zero-read observation,
/// GenBank metadata and a sidecar with reviews, comments and styles. The
/// changed result moves the evidence under the same sidecar.
@MainActor
struct GenotypeMatrixProjectionFixture {
    let root: URL
    let matrix: GenotypeComparisonMatrixView
    let result: ONTGenotypeResultBundleData
    let changedResult: ONTGenotypeResultBundleData
    let sidecar: GenotypeAnnotationSidecar
    let haplotypeEvidence: GenotypeAlleleHaplotypeEvidenceIndex

    func cleanup() {
        TestTempDirectory.cleanup(root)
    }

    /// Runs `body` under the aqua appearance the matrix was given.
    func withAquaDrawingAppearance<Value>(_ body: () throws -> Value) throws -> Value {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        var outcome: Result<Value, Error>?
        appearance.performAsCurrentDrawingAppearance {
            outcome = Result { try body() }
        }
        return try XCTUnwrap(outcome).get()
    }
}

extension GenotypeResultViewportTestCase {
    func makeMatrixProjectionFixture() throws -> GenotypeMatrixProjectionFixture {
        typealias Names = GenotypeMatrixProjectionNames
        let root = try TestTempDirectory.make(prefix: "GenotypeCharacterizationProjection")
        let bundleURL = root.appendingPathComponent("projection.lungfishgenotype", isDirectory: true)
        let result = try makeProjectionResult(bundleURL: bundleURL, changed: false)
        let changedResult = try makeProjectionResult(bundleURL: bundleURL, changed: true)
        let definition = GenotypeHaplotypeDefinitionSet(
            id: "characterization.projection-definitions",
            assayID: "MHC-full-length",
            displayName: "Characterization projection definitions",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(locus: "MHC-A", sourceLocus: "Mafa-A", haplotypes: [
                    GenotypeHaplotypeDefinition(name: "North", diagnosticAlleles: [Names.rowA1], colorTokenIndex: 1),
                    GenotypeHaplotypeDefinition(name: "South", diagnosticAlleles: [Names.rowA2], colorTokenIndex: 2),
                ]),
                GenotypeHaplotypeLocusDefinition(locus: "MHC-B", sourceLocus: "Mafa-B", haplotypes: [
                    GenotypeHaplotypeDefinition(name: "East", diagnosticAlleles: [Names.rowB1], colorTokenIndex: 3),
                    GenotypeHaplotypeDefinition(name: "West", diagnosticAlleles: [Names.rowB2], colorTokenIndex: 4),
                ]),
            ]
        )
        let evidence = GenotypeAlleleHaplotypeEvidenceIndex(calls: result.calls, definitionSet: definition, effectiveCalls: [
            .init(sample: "AnimalA", locus: "MHC-A", haplotypeNames: ["North", "South"]),
            .init(sample: "AnimalA", locus: "MHC-B", haplotypeNames: ["East"]),
            .init(sample: "AnimalB", locus: "MHC-B", haplotypeNames: ["East"]),
            .init(sample: "AnimalC", locus: "MHC-A", haplotypeNames: ["South"]),
            .init(sample: "AnimalD", locus: "MHC-A", haplotypeNames: ["North"]),
            .init(sample: "AnimalD", locus: "MHC-B", haplotypeNames: ["West"]),
        ])

        let stamp = GenotypeCharacterizationFixture.annotationTimestamp
        var sidecar = GenotypeCharacterizationFixture.baseSidecar(preferredSummaryViewMode: nil)
        sidecar.matrixReviews = [
            // A false positive on a positive cell, a false negative on an attested zero, a review on an absent cell.
            .init(target: .cell(locus: "MHC-A", genotype: Names.rowA1, sample: "AnimalA"), disposition: .falsePositive, author: "Analyst", timestamp: stamp),
            .init(target: .cell(locus: "MHC-A", genotype: Names.rowA1, sample: "AnimalB"), disposition: .falseNegative, author: "Analyst", timestamp: stamp),
            .init(target: .cell(locus: "MHC-A", genotype: Names.rowA1, sample: "AnimalC"), disposition: .falseNegative, author: "Analyst", timestamp: stamp),
            // A duplicate pair on one positive cell.
            .init(target: .cell(locus: "MHC-B", genotype: Names.rowB1, sample: "AnimalB"), disposition: .falsePositive, author: "Analyst", timestamp: stamp),
            .init(target: .cell(locus: "MHC-B", genotype: Names.rowB1, sample: "AnimalB"), disposition: .falsePositive, author: "Reviewer", timestamp: "2026-09-02T11:00:00Z"),
            // Candidate reviews: an exact false positive, a legacy false negative without the stable ID, a false negative on an unobserved cluster.
            .init(target: .cell(locus: "MHC-A1", genotype: Names.sharedName, sample: "AnimalA", stableClusterID: Names.sharedCluster), disposition: .falsePositive, author: "Analyst", timestamp: stamp),
            .init(target: .cell(locus: "MHC-A1", genotype: Names.singletonName, sample: "AnimalD"), disposition: .falseNegative, author: "Analyst", timestamp: stamp),
            .init(target: .cell(locus: "MHC-A1", genotype: Names.sharedName, sample: "AnimalB", stableClusterID: Names.sharedCluster), disposition: .falseNegative, author: "Analyst", timestamp: stamp),
        ]
        sidecar.matrixComments = [
            .init(target: .cell(locus: "MHC-B", genotype: Names.rowB2, sample: "AnimalD"), body: "Low support", author: "Analyst", timestamp: stamp),
            .init(target: .row(locus: "MHC-A", genotype: Names.rowA1), body: "Reference allele row", author: "Analyst", timestamp: stamp),
            .init(target: .column(sample: "AnimalA"), body: "Index animal", author: "Analyst", timestamp: stamp),
            .init(target: .cell(locus: "MHC-A1", genotype: Names.sharedName, sample: "AnimalA", stableClusterID: Names.sharedCluster), body: "Shared candidate", author: "Analyst", timestamp: stamp),
        ]
        sidecar.matrixStyles = [
            .init(target: .row(locus: "MHC-B", genotype: Names.rowB1), style: .init(fillColor: "#FFE0B2", isBold: true), author: "Analyst", timestamp: stamp),
            .init(target: .cell(locus: "MHC-A", genotype: Names.rowA2, sample: "AnimalA"), style: .init(textColor: "#B00020", isItalic: true), author: "Analyst", timestamp: stamp),
        ]

        let matrix = GenotypeComparisonMatrixView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        matrix.appearance = NSAppearance(named: .aqua)
        matrix.configure(result: result, sidecar: sidecar)
        matrix.configureHaplotypeEvidence(evidence)
        pinProjectionMatrixPresentation(matrix)
        return GenotypeMatrixProjectionFixture(
            root: root, matrix: matrix, result: result, changedResult: changedResult,
            sidecar: sidecar, haplotypeEvidence: evidence
        )
    }

    /// Pins every column and Increase Contrast on the standalone matrix
    /// without writing the shared defaults domain. Called again after a
    /// reconfigure, because configure rereads the persisted visibility.
    func pinProjectionMatrixPresentation(_ matrix: GenotypeComparisonMatrixView) {
        matrix.testingSetIncreaseContrastOverride(false)
        let standardColumns = ["genotype": true, "stableClusterID": true, "locus": true, "samples": true, "uniqueReads": true]
        for identifier in standardColumns.keys.sorted() {
            matrix.testingSetStandardColumnVisibleWithoutPersist(identifier, visible: standardColumns[identifier] == true)
        }
        let referenceColumns = [GenotypeMatrixProjectionNames.alleleFieldKey: true, "source.organism": false, "record.definition": false]
        for fieldKey in referenceColumns.keys.sorted() {
            matrix.testingSetReferenceColumnVisibleWithoutPersist(fieldKey: fieldKey, visible: referenceColumns[fieldKey] == true)
        }
    }

    /// The full-length result. The changed variant turns the AnimalB zero of
    /// row 01 into 8 reads, drops the 91-read duplicate of AnimalA on row 03,
    /// raises the AnimalD cell of row 04 to 6 and zeroes the shared
    /// candidate's AnimalC observation.
    private func makeProjectionResult(bundleURL: URL, changed: Bool) throws -> ONTGenotypeResultBundleData {
        typealias Names = GenotypeMatrixProjectionNames
        var calls = [
            makeCall(sample: "AnimalA", genotype: Names.rowA1, reads: 9),
            makeCall(sample: "AnimalB", genotype: Names.rowA1, reads: changed ? 8 : 0),
            makeCall(sample: "AnimalD", genotype: Names.rowA1, reads: 12),
            makeCall(sample: "AnimalA", genotype: Names.rowA2, reads: 3),
            makeCall(sample: "AnimalC", genotype: Names.rowA2, reads: 40),
            makeCall(sample: "AnimalA", genotype: Names.rowB1, reads: 17),
            makeCall(sample: "AnimalB", genotype: Names.rowB1, reads: 40),
            makeCall(sample: "AnimalD", genotype: Names.rowB2, reads: changed ? 6 : 2),
        ]
        if !changed {
            calls.insert(makeCall(sample: "AnimalA", genotype: Names.rowB1, reads: 91), at: 6)
        }
        let candidates = [
            makeCandidate(id: Names.sharedCluster, name: Names.sharedName, classification: .novel, support: .shared, samples: ["AnimalA", "AnimalC"]),
            makeCandidate(id: Names.singletonCluster, name: Names.singletonName, classification: .extension, support: .singleton, samples: ["AnimalB"]),
        ]
        let observations = [
            makeCandidateObservation(cluster: Names.sharedCluster, sample: "AnimalA", reads: 30),
            makeCandidateObservation(cluster: Names.sharedCluster, sample: "AnimalC", reads: changed ? 0 : 25),
            makeCandidateObservation(cluster: Names.singletonCluster, sample: "AnimalB", reads: 6),
            makeCandidateObservation(cluster: Names.singletonCluster, sample: "AnimalD", reads: 0),
        ]
        let base = makeCandidateResult(
            bundleURL: bundleURL,
            calls: calls,
            candidates: candidates,
            observations: observations,
            referenceMetadata: projectionReferenceMetadata()
        )
        let spanCandidate = makeCandidate(
            id: Names.spanCluster, name: Names.spanName, classification: .novel, support: .shared, samples: ["AnimalB", "AnimalD"]
        )
        let spanRecord = ONTMHCUnnameableRecord(
            stableClusterID: Names.spanCluster,
            reason: .incompleteReferenceSpan,
            failedMetrics: ["reference_span": 0.62],
            supportClass: .shared,
            independentSampleCount: 2,
            occurrenceCount: 2,
            totalClusterReads: 21,
            supportingSampleIDs: ["AnimalB", "AnimalD"],
            fastaRecordID: Names.spanCluster,
            sequenceSHA256: String(repeating: "b", count: 64),
            reciprocalHitSummary: try ONTMHCReciprocalQueryHitSummary(
                bamPath: "artifacts/alignments/unmatched-to-reference.bam",
                queryName: Names.spanCluster,
                alignmentCount: 1,
                targetAlignmentCounts: ["Mafa-A1*018:01:01:01": 1],
                exactMatchTargetNames: [],
                closestMatchTargetNames: ["Mafa-A1*018:01:01:01"]
            ),
            selectedEvidence: nil,
            selectedAlignmentIsReverse: nil,
            candidateInterpretation: ONTMHCIncompleteCandidateInterpretation(candidate: spanCandidate)
        )
        let unnameable = ONTMHCUnnameableClustersDocument(
            schemaVersion: 1,
            createdAt: "2026-07-20T00:00:00Z",
            thresholds: .defaults,
            sequenceFASTA: .init(path: "unnameable.fasta", sha256: String(repeating: "a", count: 64), sizeBytes: 1),
            clusters: [spanRecord],
            observations: [
                makeCandidateObservation(cluster: Names.spanCluster, sample: "AnimalB", reads: 14),
                makeCandidateObservation(cluster: Names.spanCluster, sample: "AnimalD", reads: 7),
            ]
        )
        return ONTGenotypeResultBundleData(
            bundleURL: base.bundleURL,
            manifest: base.manifest,
            artifacts: base.artifacts,
            stats: base.stats,
            calls: base.calls,
            samples: base.samples,
            haplotypeAnalysis: nil,
            mhcCandidates: base.mhcCandidates,
            mhcUnnameableClusters: unnameable,
            mhcCandidateSequencesByStableClusterID: [:],
            mhcCandidateGenBankArtifactURLs: base.mhcCandidateGenBankArtifactURLs,
            mhcAlignmentArtifactURLs: base.mhcAlignmentArtifactURLs,
            mhcReferenceVisualizations: nil,
            integrityWarnings: [],
            referenceMetadata: base.referenceMetadata,
            provisionalExon2SequencesByGenotype: [:],
            provisionalExon2ArtifactURLs: base.provisionalExon2ArtifactURLs
        )
    }

    /// GenBank-style metadata with an allele field for the four known rows.
    private func projectionReferenceMetadata() -> ONTGenotypeReferenceMetadata {
        typealias Names = GenotypeMatrixProjectionNames
        func record(_ allele: String, _ locus: String) -> [String: String] {
            [
                Names.alleleFieldKey: allele,
                "source.organism": "Macaca fascicularis",
                "record.definition": "Mafa-\(locus) complete coding sequence",
            ]
        }
        return ONTGenotypeReferenceMetadata(
            fields: [
                GenBankRecordDatabase.FieldDefinition(key: Names.alleleFieldKey, displayTitle: "Allele", valueType: "text", sourceCategory: "feature", preferredOrder: 0),
                GenBankRecordDatabase.FieldDefinition(key: "source.organism", displayTitle: "Organism", valueType: "text", sourceCategory: "source", preferredOrder: 1),
                GenBankRecordDatabase.FieldDefinition(key: "record.definition", displayTitle: "Definition", valueType: "text", sourceCategory: "record", preferredOrder: 2),
            ],
            recordsBySequenceName: [
                Names.rowA1: record("Mafa-A1*001:01", "A1"),
                Names.rowA2: record("Mafa-A1*002:01", "A1"),
                Names.rowB1: record("Mafa-B*075:01", "B"),
                Names.rowB2: record("Mafa-B*082:01", "B"),
            ],
            alleleFieldKey: Names.alleleFieldKey
        )
    }
}

// MARK: - R1, review eligibility

/// The names of the review eligibility fixture, shared with its test.
enum GenotypeReviewEligibilityNames {
    static let supported = "01_Mafa_A1_SUP"
    static let catalog = "02_Mafa_A1_CAT"
    static let production = "03_Mafa_A1_PROD"
    static let productionCallID = "reference:MHC-A:03_Mafa_A1_PROD"
    static let locus = "MHC-A"
    static let samples = ["S1", "S2", "S3"]
}

/// A guarded controller over a genotype-only bundle whose catalog carries one
/// row in each identity shape. The production-shape row's attested zeros never
/// reach the matrix (plan finding S1).
@MainActor
struct GenotypeReviewEligibilityScenario {
    let root: URL
    let bundleURL: URL
    let result: ONTGenotypeResultBundleData
    let changedResult: ONTGenotypeResultBundleData
    let controller: GenotypeResultViewController
    let isReadOnly: Bool

    /// Restores the bundle permissions a read-only pass changed, then removes the root.
    func cleanup() {
        if isReadOnly {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundleURL.path)
        }
        TestTempDirectory.cleanup(root)
    }
}

extension GenotypeResultViewportTestCase {
    /// Calls SUP (S1 7, S2 0), CAT (S1 12) and PROD (S3 4). Catalog rows CAT in
    /// the `callID == genotype` shape (S2 and S3 at 0) and PROD in the
    /// production shape (S1 and S2 at 0). Reviews on a positive cell, an
    /// attested zero, a catalog zero, a production-shape zero, an absent cell
    /// and a duplicate pair, plus one cell, row and column comment. The
    /// read-only pass makes the bundle folder 0o555 before configure.
    func makeReviewEligibilityScenario(readOnly: Bool) throws -> GenotypeReviewEligibilityScenario {
        typealias Fixture = GenotypeCharacterizationFixture
        typealias Names = GenotypeReviewEligibilityNames
        let (root, bundleURL) = try Fixture.makeBundleFolder(
            prefix: readOnly ? "GenotypeCharacterizationReviewReadOnly" : "GenotypeCharacterizationReview",
            name: "review"
        )
        let catalog = GenotypeReviewableRowCatalog(samples: Names.samples, rows: [
            .init(kind: .reference, callID: Names.catalog, displayName: Names.catalog, locus: Names.locus,
                  stableID: nil, section: "reference", sortKey: "1",
                  supportBySample: ["S1": 12, "S2": 0, "S3": 0]),
            .init(kind: .reference, callID: Names.productionCallID, displayName: Names.production, locus: Names.locus,
                  stableID: nil, section: "reference", sortKey: "2",
                  supportBySample: ["S1": 0, "S2": 0, "S3": 4]),
        ])
        func makeReviewResult(supportedS1: Int, supportedS2: Int) -> ONTGenotypeResultBundleData {
            let calls = [
                makeCall(sample: "S1", genotype: Names.supported, reads: supportedS1),
                makeCall(sample: "S2", genotype: Names.supported, reads: supportedS2),
                makeCall(sample: "S1", genotype: Names.catalog, reads: 12),
                makeCall(sample: "S3", genotype: Names.production, reads: 4),
            ]
            return makeResult(
                bundleURL: bundleURL,
                samples: Fixture.sampleResults(for: calls, order: Names.samples),
                calls: calls,
                reviewableRowCatalog: catalog
            )
        }
        let result = makeReviewResult(supportedS1: 7, supportedS2: 0)
        let changedResult = makeReviewResult(supportedS1: 0, supportedS2: 5)
        try ONTGenotypeResultBundle.writeManifest(result.manifest, to: bundleURL)

        let stamp = Fixture.annotationTimestamp
        func cell(_ genotype: String, _ sample: String) -> GenotypeAnnotationSidecar.MatrixTarget {
            .cell(locus: Names.locus, genotype: genotype, sample: sample)
        }
        var sidecar = Fixture.baseSidecar(preferredSummaryViewMode: nil)
        sidecar.matrixReviews = [
            .init(target: cell(Names.supported, "S1"), disposition: .falsePositive, author: "Analyst", timestamp: stamp),
            .init(target: cell(Names.supported, "S2"), disposition: .falseNegative, author: "Analyst", timestamp: stamp),
            .init(target: cell(Names.catalog, "S3"), disposition: .falseNegative, author: "Analyst", timestamp: stamp),
            .init(target: cell(Names.production, "S1"), disposition: .falseNegative, author: "Analyst", timestamp: stamp),
            .init(target: cell(Names.catalog, "S1"), disposition: .falsePositive, author: "Analyst", timestamp: stamp),
            .init(target: cell(Names.catalog, "S1"), disposition: .falsePositive, author: "Reviewer", timestamp: "2026-09-02T11:00:00Z"),
            .init(target: cell(Names.supported, "S3"), disposition: .falseNegative, author: "Analyst", timestamp: stamp),
        ]
        sidecar.matrixComments = [
            .init(target: cell(Names.catalog, "S1"), body: "Check the catalog count", author: "Analyst", timestamp: stamp),
            .init(target: .row(locus: Names.locus, genotype: Names.supported), body: "Reference allele row", author: "Analyst", timestamp: stamp),
            .init(target: .column(sample: "S2"), body: "Index animal", author: "Analyst", timestamp: stamp),
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        if readOnly {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundleURL.path)
        }

        let controller = makeCharacterizationController()
        configureReviewController(controller, result: result)
        return GenotypeReviewEligibilityScenario(
            root: root, bundleURL: bundleURL, result: result, changedResult: changedResult,
            controller: controller, isReadOnly: readOnly
        )
    }

    /// Configures the controller for a result of the review fixture and pins
    /// its matrix columns. Used for the first configure and the reconfigure.
    func configureReviewController(_ controller: GenotypeResultViewController, result: ONTGenotypeResultBundleData) {
        controller.configure(result: result)
        pinCharacterizationMatrixPresentation(
            controller,
            standardColumns: ["genotype": true, "stableClusterID": false, "locus": true, "samples": true, "uniqueReads": true]
        )
        var state = controller.testingDisplayState
        state.summaryViewMode = .matrix
        controller.testingApplyDisplayStateImmediately(state)
    }
}

// MARK: - B1 and B2, the haplotype band

/// A controller over a bundle with a window-owned disclosure store, which a
/// replacement controller shares.
@MainActor
struct GenotypeBandScenario {
    let root: URL
    let bundleURL: URL
    let result: ONTGenotypeResultBundleData
    let store: GenotypeManualHaplotypeBandDisclosureStore
    let standardColumns: [String: Bool]
    var controller: GenotypeResultViewController

    func cleanup() {
        TestTempDirectory.cleanup(root)
    }
}

extension GenotypeResultViewportTestCase {
    /// A guarded controller with a 1200 by 800 view, the shared disclosure
    /// store installed before configure, pinned columns and the matrix view.
    func makeBandController(
        for result: ONTGenotypeResultBundleData,
        store: GenotypeManualHaplotypeBandDisclosureStore,
        standardColumns: [String: Bool]
    ) -> GenotypeResultViewController {
        let controller = makeCharacterizationController()
        controller.manualHaplotypeBandDisclosureStore = store
        controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        controller.configure(result: result)
        pinCharacterizationMatrixPresentation(controller, standardColumns: standardColumns)
        var state = controller.testingDisplayState
        state.summaryViewMode = .matrix
        controller.testingApplyDisplayStateImmediately(state)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    /// Replaces the scenario's controller with a fresh one over the same bundle and store.
    func recreateBandController(_ scenario: inout GenotypeBandScenario) {
        scenario.controller = makeBandController(
            for: scenario.result, store: scenario.store, standardColumns: scenario.standardColumns
        )
    }

    // MARK: B1, effective MiSeq calls

    /// Three animals and three loci over a literal MiSeq analysis with no
    /// resolvable definition. Sample-A has a heterozygous call, a too-many-
    /// genotypes locus with a one-slot exact override and a homozygous call.
    /// Sample-B has an ambiguous call, a heterozygous call and an unresolved
    /// second haplotype. Sample-C has a homozygous call, a heterozygous call
    /// with a stale override and a not-assayed locus.
    func makeEffectiveBandScenario() throws -> GenotypeBandScenario {
        typealias Fixture = GenotypeCharacterizationFixture
        let (root, bundleURL) = try Fixture.makeBundleFolder(prefix: "GenotypeCharacterizationEffectiveBand", name: "band")
        let revision = "band-revision-1"
        let definitionSetID = "characterization.band-definitions"
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: Fixture.assayID,
            definitionSetID: definitionSetID,
            definitionSetName: "Characterization band definitions",
            speciesName: "Test macaque",
            generatedAt: Fixture.analysisGeneratedAt,
            analysisRevisionID: revision,
            source: .deterministic,
            samples: [
                .init(sample: "Sample-A", calls: [
                    Fixture.locusCall("MHC-A", "A1", "A2", .called,
                        matched: ["A1": ["01_Mafa_A1_001_01"], "A2": ["02_Mafa_A1_002_01"]],
                        observed: ["01_Mafa_A1_001_01", "02_Mafa_A1_002_01"]),
                    Fixture.locusCall("MHC-B", "ERR: TMG", "ERR: TMG", .tooManyGenotypes,
                        observed: ["03_Mafa_B_075_01", "04_Mafa_B_082_01", "05_Mafa_B_090_01"],
                        notes: "GEN-05: three genotypes observed where two haplotypes are defined"),
                    Fixture.locusCall("MHC-DRB", "D1", "-", .called,
                        matched: ["D1": ["06_Mafa_DRB_001_01"]], observed: ["06_Mafa_DRB_001_01"]),
                ]),
                .init(sample: "Sample-B", calls: [
                    Fixture.locusCall("MHC-A", "A1|A2", "A1|A2", .ambiguous,
                        matched: ["A1": ["01_Mafa_A1_001_01"], "A2": ["01_Mafa_A1_001_01"]], observed: ["01_Mafa_A1_001_01"],
                        notes: "GEN-02: A1|A2 cannot be distinguished from the observed diagnostic alleles"),
                    Fixture.locusCall("MHC-B", "B1", "B2", .called,
                        matched: ["B1": ["03_Mafa_B_075_01"], "B2": ["04_Mafa_B_082_01"]],
                        observed: ["03_Mafa_B_075_01", "04_Mafa_B_082_01"]),
                    Fixture.locusCall("MHC-DRB", "D2", "?", .unresolvedSecondHaplotype,
                        matched: ["D2": ["07_Mafa_DRB_002_01"]], observed: ["07_Mafa_DRB_002_01", "08_Mafa_DRB_003_01"],
                        notes: "GEN-08: only D2 matched a defined haplotype"),
                ]),
                .init(sample: "Sample-C", calls: [
                    Fixture.locusCall("MHC-A", "A3", "-", .called,
                        matched: ["A3": ["09_Mafa_A1_009_01"]], observed: ["09_Mafa_A1_009_01"]),
                    Fixture.locusCall("MHC-B", "B3", "B1", .called,
                        matched: ["B1": ["03_Mafa_B_075_01"], "B3": ["05_Mafa_B_090_01"]],
                        observed: ["03_Mafa_B_075_01", "05_Mafa_B_090_01"]),
                    Fixture.locusCall("MHC-DRB", "Not assayed", "Not assayed", .notAssayed,
                        notes: "MHC-DRB was not observed anywhere in this run for the active definition set."),
                ]),
            ]
        )
        let calls = [
            makeCall(sample: "Sample-A", genotype: "01_Mafa_A1_001_01", reads: 60),
            makeCall(sample: "Sample-B", genotype: "02_Mafa_A1_002_01", reads: 70),
            makeCall(sample: "Sample-C", genotype: "03_Mafa_B_075_01", reads: 80),
        ]
        let result = makeResult(
            bundleURL: bundleURL,
            samples: Fixture.sampleResults(for: calls, order: ["Sample-A", "Sample-B", "Sample-C"]),
            calls: calls,
            haplotypeAnalysis: analysis
        )
        try ONTGenotypeResultBundle.writeManifest(result.manifest, to: bundleURL)

        let exact = GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity(
            assayID: Fixture.assayID, analysisRevisionID: revision, definitionSetID: definitionSetID
        )
        let stale = GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity(
            assayID: Fixture.assayID, analysisRevisionID: "band-revision-0", definitionSetID: definitionSetID
        )
        var sidecar = Fixture.baseSidecar(preferredSummaryViewMode: "matrix")
        sidecar.callOverrides = [
            Fixture.override(sample: "Sample-A", locus: "MHC-B", slot: .h1, original: "ERR: TMG", call: "B9",
                timestamp: "2026-09-02T10:00:00Z", identity: exact, operation: "one-slot-on-too-many-genotypes"),
            Fixture.override(sample: "Sample-C", locus: "MHC-B", slot: .h2, original: "B1", call: "B7",
                timestamp: "2026-09-02T10:05:00Z", identity: stale, operation: "stale-identity"),
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))

        let store = GenotypeManualHaplotypeBandDisclosureStore()
        let standardColumns = ["genotype": true, "stableClusterID": false, "locus": true, "samples": true, "uniqueReads": true]
        let controller = makeBandController(for: result, store: store, standardColumns: standardColumns)
        return GenotypeBandScenario(
            root: root, bundleURL: bundleURL, result: result, store: store,
            standardColumns: standardColumns, controller: controller
        )
    }

    // MARK: B2, manual assignments

    /// Three animals over a genotype-only result whose calls span the seven
    /// manual loci, so the locus popup offers MHC-DQA1. AnimalA has both
    /// MHC-A slots assigned, AnimalB only MHC-DQA H2, AnimalC nothing.
    func makeManualBandScenario() throws -> GenotypeBandScenario {
        typealias Fixture = GenotypeCharacterizationFixture
        let (root, bundleURL) = try Fixture.makeBundleFolder(prefix: "GenotypeCharacterizationManualBand", name: "manual-band")
        let calls = [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 42),
            makeCall(sample: "AnimalA", genotype: "21_Mafa_DRB_001_01", reads: 30),
            makeCall(sample: "AnimalA", genotype: "41_Mafa_DQB1_001_01", reads: 12),
            makeCall(sample: "AnimalB", genotype: "01_Mafa_A1_001_01", reads: 21),
            makeCall(sample: "AnimalB", genotype: "12_Mafa_B_001_01", reads: 33),
            makeCall(sample: "AnimalB", genotype: "31_Mafa_DQA1_001_01", reads: 18),
            makeCall(sample: "AnimalC", genotype: "12_Mafa_B_001_01", reads: 5),
            makeCall(sample: "AnimalC", genotype: "51_Mafa_DPA1_001_01", reads: 9),
            makeCall(sample: "AnimalC", genotype: "61_Mafa_DPB1_001_01", reads: 11),
        ]
        let result = makeResult(
            bundleURL: bundleURL,
            samples: Fixture.sampleResults(for: calls, order: ["AnimalA", "AnimalB", "AnimalC"]),
            calls: calls
        )
        try ONTGenotypeResultBundle.writeManifest(result.manifest, to: bundleURL)
        var sidecar = Fixture.baseSidecar(preferredSummaryViewMode: nil)
        sidecar.manualHaplotypeAssignments = [
            .init(sample: "AnimalA", locus: GenotypeManualHaplotypeLocus.a.workbookLabel, slot: .h1, label: "Hap-1",
                  colorTokenIndex: 1, diagnosticAlleles: ["01_Mafa_A1_001_01"], notes: "Pedigree confirmed"),
            .init(sample: "AnimalA", locus: GenotypeManualHaplotypeLocus.a.workbookLabel, slot: .h2, label: "Hap-2",
                  colorTokenIndex: 2, diagnosticAlleles: [], notes: ""),
            .init(sample: "AnimalB", locus: GenotypeManualHaplotypeLocus.dqa.workbookLabel, slot: .h2, label: "Hap-3",
                  colorTokenIndex: 3, diagnosticAlleles: ["31_Mafa_DQA1_001_01"], notes: "Provisional"),
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))

        let store = GenotypeManualHaplotypeBandDisclosureStore()
        let standardColumns = ["genotype": true, "stableClusterID": false, "locus": true, "samples": true, "uniqueReads": true]
        let controller = makeBandController(for: result, store: store, standardColumns: standardColumns)
        return GenotypeBandScenario(
            root: root, bundleURL: bundleURL, result: result, store: store,
            standardColumns: standardColumns, controller: controller
        )
    }
}
