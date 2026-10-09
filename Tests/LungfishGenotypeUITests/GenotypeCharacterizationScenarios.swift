// GenotypeCharacterizationScenarios.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The scenarios the genotype GUI characterization tests build, and the capture
// helpers that turn a configured controller into canonical bytes. Every
// `testing*` call the characterization tests make lives here, so a later
// extraction rewires one file.
//
// Each scenario is built in code from GenotypeTestFixtures and the viewport
// test case builders, inside a real bundle folder nested like
// <root>/Project/Analyses/run/<name>.lungfishgenotype. Nothing is loaded from
// Tests/Fixtures. Everything that varies run to run is pinned before
// configure: the sidecar is pre-written with fixed times and author, the
// definition is written directly with a fixed lastModified, the summary view
// preference is already matrix so no settings audit is appended, the built-in
// smart cohorts are already present so the store seeds nothing, the author
// provider is a constant, the appearance is aqua with Increase Contrast off,
// and every matrix column is pinned without touching UserDefaults.

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishGenotypeUI

/// A configured controller over a real bundle folder in a test temp root.
@MainActor
struct GenotypeCharacterizationScenario {
    let root: URL
    let bundleURL: URL
    let result: ONTGenotypeResultBundleData
    let controller: GenotypeResultViewController

    func cleanup() {
        TestTempDirectory.cleanup(root)
    }

    /// The canonical frozen Excel capture. Call it before
    /// `canonicalViewportSnapshot`, because the Excel capture settles pending
    /// search and filter state.
    func canonicalExcelCapture() throws -> Data {
        let start = Date()
        let snapshot = try withAquaDrawingAppearance { try controller.captureExcelExportSnapshot() }
        let end = Date()
        let frozen = try JSONDecoder().decode(
            GenotypeWorkbookPresentation.Snapshot.self,
            from: XCTUnwrap(snapshot.excelSnapshotData)
        )
        try GenotypeExcelSnapshotBuilder.validate(frozen)
        return try GenotypeCharacterizationCanonicalizer(
            root: root,
            generatedAtWindow: GenotypeCharacterizationCanonicalizer.window(from: start, to: end)
        ).encode(snapshot)
    }

    /// The canonical delimited viewport snapshot, the production-dead path
    /// that `testingCurrentExportSnapshot` still reaches.
    func canonicalViewportSnapshot() throws -> Data {
        let snapshot = try XCTUnwrap(withAquaDrawingAppearance { controller.testingCurrentExportSnapshot() })
        return try GenotypeCharacterizationCanonicalizer(root: root).encode(snapshot)
    }

    /// Both expected files of a scenario, keyed by file name.
    func canonicalExportFiles(prefix: String) throws -> [String: Data] {
        let excel = try canonicalExcelCapture()
        let viewport = try canonicalViewportSnapshot()
        return [
            "\(prefix).excel-capture.json": excel,
            "\(prefix).viewport-snapshot.json": viewport,
        ]
    }

    /// Runs `body` under the aqua appearance, the one the scenario pinned.
    func withAquaDrawingAppearance<Value>(_ body: () throws -> Value) throws -> Value {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        var outcome: Result<Value, Error>?
        appearance.performAsCurrentDrawingAppearance {
            outcome = Result { try body() }
        }
        return try XCTUnwrap(outcome).get()
    }
}

/// Fixed values shared by the scenarios.
enum GenotypeCharacterizationFixture {
    static let author = "characterization"
    static let assayID = "MHC-exon2-miSeq"
    static let sidecarGeneratedAt = "2026-09-01T00:00:00Z"
    static let annotationTimestamp = "2026-09-02T10:00:00Z"
    static let analysisGeneratedAt = "2026-09-01T00:00:00Z"

    /// The smart cohorts `GenotypeAnnotationStore` seeds into a haplotyped
    /// bundle. Written up front so the store finds every name and writes nothing.
    static func builtInSmartCohorts() -> [GenotypeCohortSmartFilter] {
        [
            GenotypeCohortSmartFilter(
                name: "Incomplete haplotypes",
                description: "Samples with unresolved, not-assayed, or error haplotype slots.",
                scope: "bundle", isStarred: true, predicate: .needsHaplotypeReview
            ),
            GenotypeCohortSmartFilter(
                name: "Needs review",
                description: "Incomplete haplotypes, low support, or analyst-flagged samples.",
                scope: "bundle", isStarred: true,
                predicate: .any([.needsHaplotypeReview, .qcStatus([.review, .lowSupport]), .hasAnalystFlag(.needsReview)])
            ),
            GenotypeCohortSmartFilter(
                name: "Homozygous",
                description: "Samples whose H1 equals H2 at every called locus.",
                scope: "bundle", isStarred: false, predicate: .isHomozygousAcrossAll
            ),
            GenotypeCohortSmartFilter(
                name: "Recombinants",
                description: "Samples carrying a rec* haplotype at any locus.",
                scope: "bundle", isStarred: false, predicate: .hasRegionalRecombinant
            ),
        ]
    }

    /// A sidecar with fixed times, the built-in cohorts and the matrix view
    /// already preferred, so configure persists nothing.
    static func baseSidecar(preferredSummaryViewMode: String?) -> GenotypeAnnotationSidecar {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: sidecarGeneratedAt)
        sidecar.smartCohorts = builtInSmartCohorts()
        sidecar.settings.preferredSummaryViewMode = preferredSummaryViewMode
        return sidecar
    }

    /// The deterministic definition the haplotyped MiSeq scenario resolves.
    static func exon2DefinitionSet() -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: "characterization.exon2-definitions",
            assayID: assayID,
            displayName: "Characterization exon 2 definitions",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(locus: "MHC-A", sourceLocus: "Mafa-A", haplotypes: [
                    GenotypeHaplotypeDefinition(name: "M1A", diagnosticAlleles: ["01_Mafa_A1_001_01"], colorTokenIndex: 0),
                    GenotypeHaplotypeDefinition(name: "M2A", diagnosticAlleles: ["02_Mafa_A1_002_01"], colorTokenIndex: 1),
                ]),
                GenotypeHaplotypeLocusDefinition(locus: "MHC-B", sourceLocus: "Mafa-B", haplotypes: [
                    GenotypeHaplotypeDefinition(name: "M1B", diagnosticAlleles: ["03_Mafa_B_075_01"], colorTokenIndex: 2),
                    GenotypeHaplotypeDefinition(name: "M2B", diagnosticAlleles: ["04_Mafa_B_082_01"], colorTokenIndex: 3),
                ]),
            ],
            schemaVersion: 3,
            lastModified: "2026-08-15T12:00:00Z",
            changeNote: "Frozen for the GUI export characterization"
        )
    }

    /// GenBank-style metadata with an allele field for the four exon 2 references.
    static func exon2ReferenceMetadata() -> ONTGenotypeReferenceMetadata {
        func record(_ allele: String, _ locus: String) -> [String: String] {
            [
                "feature.allele": allele,
                "source.organism": "Macaca fascicularis",
                "record.definition": "Mafa-\(locus) exon 2 reference",
            ]
        }
        return ONTGenotypeReferenceMetadata(
            fields: [
                GenBankRecordDatabase.FieldDefinition(key: "feature.allele", displayTitle: "Allele", valueType: "text", sourceCategory: "feature", preferredOrder: 0),
                GenBankRecordDatabase.FieldDefinition(key: "source.organism", displayTitle: "Organism", valueType: "text", sourceCategory: "source", preferredOrder: 1),
                GenBankRecordDatabase.FieldDefinition(key: "record.definition", displayTitle: "Definition", valueType: "text", sourceCategory: "record", preferredOrder: 2),
            ],
            recordsBySequenceName: [
                "01_Mafa_A1_001_01": record("Mafa-A1*001:01", "A1"),
                "02_Mafa_A1_002_01": record("Mafa-A1*002:01", "A1"),
                "03_Mafa_B_075_01": record("Mafa-B*075:01", "B"),
                "04_Mafa_B_082_01": record("Mafa-B*082:01", "B"),
            ],
            alleleFieldKey: "feature.allele"
        )
    }

    /// Writes a definition set where the resolver finds a bundle snapshot.
    static func writeDefinitionSnapshot(_ definition: GenotypeHaplotypeDefinitionSet, in bundleURL: URL) throws {
        let folder = bundleURL
            .appendingPathComponent(".amplicon-genotyping", isDirectory: true)
            .appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(definition).write(to: folder.appendingPathComponent("haplotype-definition.json"))
    }

    /// `<root>/Project/Analyses/run/<name>.lungfishgenotype`, so the project
    /// root is three levels up and holds no Haplotype Definitions folder.
    static func makeBundleFolder(prefix: String, name: String) throws -> (root: URL, bundleURL: URL) {
        let root = try TestTempDirectory.make(prefix: prefix)
        let bundleURL = root
            .appendingPathComponent("Project", isDirectory: true)
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent("\(name).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return (root, bundleURL)
    }

    static func sampleResults(for calls: [ONTGenotypeCall], order: [String]) -> [ONTGenotypeSampleResult] {
        order.map { sample in
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
    }

    static func override(
        sample: String, locus: String, slot: HaplotypeSlot, original: String, call: String,
        timestamp: String, identity: GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity?, operation: String
    ) -> GenotypeAnnotationSidecar.CallOverride {
        GenotypeAnnotationSidecar.CallOverride(
            sample: sample, locus: locus, slot: slot, originalCall: original, overrideCall: call,
            reasonTag: .analystJudgment, rationale: "Characterization override \(operation)",
            author: "Analyst", timestamp: timestamp, analysisIdentity: identity, operationID: operation
        )
    }

    static func locusCall(
        _ locus: String, _ h1: String, _ h2: String, _ status: GenotypeHaplotypeCallStatus,
        matched: [String: [String]] = [:], observed: [String] = [], notes: String = ""
    ) -> GenotypeHaplotypeLocusCall {
        GenotypeHaplotypeLocusCall(
            locus: locus,
            sourceLocus: "Mafa-\(locus.dropFirst(4))",
            haplotype1: h1,
            haplotype2: h2,
            status: status,
            matchedHaplotypes: matched.keys.sorted().map { name in
                GenotypeHaplotypeMatchedDefinition(
                    name: name, diagnosticAlleles: matched[name] ?? [], observedDiagnosticAlleles: matched[name] ?? []
                )
            },
            observedGenotypeCount: observed.count,
            observedGenotypes: observed,
            notes: notes
        )
    }
}

extension GenotypeResultViewportTestCase {
    /// A guarded controller with a constant author, a loaded view and the aqua
    /// appearance, so no draft decision reaches an alert and no author or
    /// appearance varies between runs.
    func makeCharacterizationController() -> GenotypeResultViewController {
        let controller = makeManualHaplotypeGuardedController()
        controller.annotationAuthorProvider = { GenotypeCharacterizationFixture.author }
        _ = controller.view
        controller.view.appearance = NSAppearance(named: .aqua)
        return controller
    }

    /// Pins every matrix column and Increase Contrast after configure, without
    /// writing the shared defaults domain. Unit-tier classes in other processes
    /// write the `GenotypeMatrix.*` keys mid-run, so resetting them is not enough.
    func pinCharacterizationMatrixPresentation(
        _ controller: GenotypeResultViewController,
        standardColumns: [String: Bool],
        referenceColumns: [String: Bool] = [:]
    ) {
        let matrix = controller.testingComparisonMatrix
        matrix.testingSetIncreaseContrastOverride(false)
        for identifier in standardColumns.keys.sorted() {
            matrix.testingSetStandardColumnVisibleWithoutPersist(identifier, visible: standardColumns[identifier] == true)
        }
        for fieldKey in referenceColumns.keys.sorted() {
            matrix.testingSetReferenceColumnVisibleWithoutPersist(fieldKey: fieldKey, visible: referenceColumns[fieldKey] == true)
        }
    }

    // MARK: Scenario A, haplotyped MiSeq with a resolvable definition

    /// Five animals, two loci, a definition snapshot in the bundle so the live
    /// analysis is re-inferred, GenBank metadata, a catalog with one
    /// overlapping row, one catalog-only reference row, one production-shape
    /// row for an allele the native matrix spells differently and one
    /// catalog-only animal (AnimalF) that is in no call and no sample, reviews,
    /// comments and styles in the sidecar, an identity-bound override, min
    /// reads 5 and min percent 10, AnimalD hidden, AnimalE outside the smart
    /// cohort and AnimalC moved first. The reference row 01_Mafa_A1_001_01
    /// then holds a positive cell (AnimalA), a catalog zero (AnimalB) and an
    /// unknown cell (AnimalC) in the Filtered sheet at once, and the All sheet
    /// gains the AnimalF column from the catalog alone.
    func makeHaplotypedMiSeqScenario() throws -> GenotypeCharacterizationScenario {
        try makeHaplotypedMiSeqScenario(.catalogExtended)
    }

    /// Scenario D, the data of scenario A with the four-animal catalog and
    /// three more viewport inputs. The global percent is 7.5 with Hide Low
    /// Support off, so the capture's global filter must stay 0.0 while the
    /// filter context records 7.5. Prevalence is 40, which drops
    /// 02_Mafa_A1_002_01 (one of five animals) and keeps 04_Mafa_B_082_01 at
    /// exactly 40 percent, counting AnimalE outside the cohort. The sidecar
    /// carries a locus display order of MHC-B before MHC-A.
    func makeThresholdedMiSeqScenario() throws -> GenotypeCharacterizationScenario {
        try makeHaplotypedMiSeqScenario(.thresholded)
    }

    /// Scenario E, the data of scenario A with its five-animal catalog, which
    /// holds the catalog-only AnimalF, matrix prevalence 40, and the Samples
    /// and Unique Reads matrix columns hidden. It pins the roster discrepancy
    /// of finding T2 in the bioinformatics report. The matrix counts prevalence
    /// over the five animals the result holds, so 04_Mafa_B_082_01 stays
    /// visible at 2 of 5, exactly 40 percent. The Excel builder counts over the
    /// union of the result, call, catalog and analysis samples, so AnimalF
    /// makes the roster six, the row falls to 2 of 6 and leaves the Filtered
    /// sheet. The two count columns are hidden because the builder recomputes
    /// them over its own roster and refuses the whole capture when they differ
    /// from the GUI's, which the next scenario pins. Scenario D keeps the same
    /// row with its four-animal catalog, where both rosters agree.
    func makeCatalogPrevalenceMiSeqScenario() throws -> GenotypeCharacterizationScenario {
        try makeHaplotypedMiSeqScenario(.catalogPrevalence)
    }

    /// Scenario E with the Samples and Unique Reads columns visible, the GUI's
    /// default. The Excel builder recomputes both columns over its six-animal
    /// roster, finds the GUI's five-animal values for 04_Mafa_B_082_01
    /// different and refuses the capture, so the export publishes one failed
    /// event and opens no save panel. The other consequence of finding T2.
    func makeCatalogPrevalenceWithCountColumnsMiSeqScenario() throws -> GenotypeCharacterizationScenario {
        try makeHaplotypedMiSeqScenario(.catalogPrevalenceWithCountColumns)
    }

    /// The four scenarios that share the haplotyped MiSeq data.
    enum HaplotypedMiSeqVariant {
        /// Scenario A, with the catalog-only animal and the production-shape row.
        case catalogExtended
        /// Scenario D, with the global percent, prevalence and a locus order.
        case thresholded
        /// Scenario E, the catalog of scenario A with prevalence 40 and the count columns hidden.
        case catalogPrevalence
        /// Scenario E with the count columns visible, so the Excel capture is refused.
        case catalogPrevalenceWithCountColumns

        var temporaryPrefix: String {
            switch self {
            case .catalogExtended: return "GenotypeCharacterizationHaplotyped"
            case .thresholded: return "GenotypeCharacterizationThresholded"
            case .catalogPrevalence: return "GenotypeCharacterizationCatalogPrevalence"
            case .catalogPrevalenceWithCountColumns: return "GenotypeCharacterizationCatalogPrevalenceCounts"
            }
        }

        /// Prevalence 40 is the one viewport input both scenario E states add.
        var appliesPrevalence: Bool {
            self == .catalogPrevalence || self == .catalogPrevalenceWithCountColumns
        }

        /// Scenario E hides the two columns the Excel builder recomputes over its roster.
        var hidesCountColumns: Bool {
            self == .catalogPrevalence
        }
    }

    private func makeHaplotypedMiSeqScenario(_ variant: HaplotypedMiSeqVariant) throws -> GenotypeCharacterizationScenario {
        typealias Fixture = GenotypeCharacterizationFixture
        let (root, bundleURL) = try Fixture.makeBundleFolder(prefix: variant.temporaryPrefix, name: "haplotyped")
        let definition = Fixture.exon2DefinitionSet()
        try Fixture.writeDefinitionSnapshot(definition, in: bundleURL)
        let calls = [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 9),
            makeCall(sample: "AnimalA", genotype: "02_Mafa_A1_002_01", reads: 3),
            makeCall(sample: "AnimalA", genotype: "03_Mafa_B_075_01", reads: 40),
            makeCall(sample: "AnimalB", genotype: "02_Mafa_A1_002_01", reads: 40),
            makeCall(sample: "AnimalB", genotype: "04_Mafa_B_082_01", reads: 9),
            makeCall(sample: "AnimalC", genotype: "02_Mafa_A1_002_01", reads: 0),
            makeCall(sample: "AnimalC", genotype: "03_Mafa_B_075_01", reads: 9),
            makeCall(sample: "AnimalC", genotype: "04_Mafa_B_082_01", reads: 3),
            makeCall(sample: "AnimalD", genotype: "01_Mafa_A1_001_01", reads: 40),
            makeCall(sample: "AnimalD", genotype: "03_Mafa_B_075_01", reads: 40),
            makeCall(sample: "AnimalE", genotype: "01_Mafa_A1_001_01", reads: 12),
            makeCall(sample: "AnimalE", genotype: "04_Mafa_B_082_01", reads: 40),
        ]
        let animals = ["AnimalA", "AnimalB", "AnimalC", "AnimalD", "AnimalE"]
        let pipeline = GenotypeHaplotypeAnalyzer.analyze(calls: calls, definitionSet: definition)
        let persisted = GenotypeHaplotypeAnalysis(
            schemaVersion: pipeline.schemaVersion,
            assayID: pipeline.assayID,
            definitionSetID: pipeline.definitionSetID,
            definitionSetName: pipeline.definitionSetName,
            speciesName: pipeline.speciesName,
            generatedAt: Fixture.analysisGeneratedAt,
            analysisRevisionID: "characterization-persisted-1",
            source: .deterministic,
            samples: pipeline.samples
        )
        // AnimalF exists only in the catalog, so the All sheet must extend its
        // sample columns and remap colours and styles for a sample the native
        // matrix never had. The production-shape row names the allele of
        // 01_Mafa_A1_001_01 in a spelling the native matrix does not carry, so
        // it stands alone as a second All row for the same allele, which is
        // how the shared catalog mapping treats an unmatched row (finding S1).
        let catalog: GenotypeReviewableRowCatalog
        switch variant {
        case .catalogExtended, .catalogPrevalence, .catalogPrevalenceWithCountColumns:
            catalog = GenotypeReviewableRowCatalog(samples: ["AnimalA", "AnimalB", "AnimalD", "AnimalE", "AnimalF"], rows: [
                .init(kind: .reference, callID: "01_Mafa_A1_001_01", displayName: "Mafa-A1*001:01", locus: "MHC-A",
                      stableID: nil, section: "reference", sortKey: "1",
                      supportBySample: ["AnimalA": 9, "AnimalB": 0, "AnimalD": 40, "AnimalE": 12, "AnimalF": 7]),
                .init(kind: .reference, callID: "reference:MHC-B:Mafa-B*099:01", displayName: "Mafa-B*099:01", locus: "MHC-B",
                      stableID: nil, section: "reference", sortKey: "2",
                      supportBySample: ["AnimalA": 0, "AnimalB": 0, "AnimalD": 0, "AnimalE": 0, "AnimalF": 0]),
                .init(kind: .reference, callID: "reference:MHC-A:Mafa-A1*001:01", displayName: "Mafa-A1*001:01", locus: "MHC-A",
                      stableID: nil, section: "reference", sortKey: "3",
                      supportBySample: ["AnimalA": 9, "AnimalB": 0, "AnimalD": 40, "AnimalE": 12, "AnimalF": 7]),
            ])
        case .thresholded:
            catalog = GenotypeReviewableRowCatalog(samples: ["AnimalA", "AnimalB", "AnimalD", "AnimalE"], rows: [
                .init(kind: .reference, callID: "01_Mafa_A1_001_01", displayName: "Mafa-A1*001:01", locus: "MHC-A",
                      stableID: nil, section: "reference", sortKey: "1",
                      supportBySample: ["AnimalA": 9, "AnimalB": 0, "AnimalD": 40, "AnimalE": 12]),
                .init(kind: .reference, callID: "reference:MHC-B:Mafa-B*099:01", displayName: "Mafa-B*099:01", locus: "MHC-B",
                      stableID: nil, section: "reference", sortKey: "2",
                      supportBySample: ["AnimalA": 0, "AnimalB": 0, "AnimalD": 0, "AnimalE": 0]),
            ])
        }
        let result = makeResult(
            bundleURL: bundleURL,
            samples: Fixture.sampleResults(for: calls, order: animals),
            calls: calls,
            haplotypeAnalysis: persisted,
            referenceMetadata: Fixture.exon2ReferenceMetadata(),
            reviewableRowCatalog: catalog
        )
        try ONTGenotypeResultBundle.writeManifest(result.manifest, to: bundleURL)

        let stamp = Fixture.annotationTimestamp
        let cohort = GenotypeCohortSmartFilter(
            name: "Characterization cohort",
            description: "Four of the five animals of the characterization fixture",
            scope: "bundle", isStarred: false,
            predicate: .animalIdIn(["AnimalA", "AnimalB", "AnimalC", "AnimalD"])
        )
        var sidecar = Fixture.baseSidecar(preferredSummaryViewMode: "matrix")
        if variant == .thresholded {
            sidecar.settings.genotypeLocusDisplayOrder = ["MHC-B", "MHC-A"]
        }
        sidecar.smartCohorts.append(cohort)
        sidecar.callOverrides = [
            Fixture.override(
                sample: "AnimalB", locus: "MHC-A", slot: .h2, original: "-", call: "M1A", timestamp: stamp,
                identity: .init(assayID: Fixture.assayID, analysisRevisionID: nil, definitionSetID: definition.id),
                operation: "live-identity"
            ),
        ]
        sidecar.matrixReviews = [
            .init(target: .cell(locus: "MHC-A", genotype: "02_Mafa_A1_002_01", sample: "AnimalA"), disposition: .falsePositive, author: "Analyst", timestamp: stamp),
            .init(target: .cell(locus: "MHC-A", genotype: "01_Mafa_A1_001_01", sample: "AnimalB"), disposition: .falseNegative, author: "Analyst", timestamp: stamp),
            .init(target: .cell(locus: "MHC-A", genotype: "01_Mafa_A1_001_01", sample: "AnimalC"), disposition: .falseNegative, author: "Analyst", timestamp: stamp),
            .init(target: .cell(locus: "MHC-B", genotype: "03_Mafa_B_075_01", sample: "AnimalD"), disposition: .falsePositive, author: "Analyst", timestamp: stamp),
            .init(target: .cell(locus: "MHC-B", genotype: "03_Mafa_B_075_01", sample: "AnimalD"), disposition: .falsePositive, author: "Reviewer", timestamp: "2026-09-02T11:00:00Z"),
        ]
        sidecar.matrixComments = [
            .init(target: .cell(locus: "MHC-B", genotype: "04_Mafa_B_082_01", sample: "AnimalB"), body: "Verify B*082 support before sign-off", author: "Analyst", timestamp: stamp),
            .init(target: .row(locus: "MHC-A", genotype: "01_Mafa_A1_001_01"), body: "Reference allele row", author: "Analyst", timestamp: stamp),
            .init(target: .column(sample: "AnimalA"), body: "Index animal", author: "Analyst", timestamp: stamp),
        ]
        sidecar.matrixStyles = [
            .init(target: .row(locus: "MHC-B", genotype: "03_Mafa_B_075_01"), style: .init(fillColor: "#FFE0B2", isBold: true), author: "Analyst", timestamp: stamp),
            .init(target: .cell(locus: "MHC-A", genotype: "02_Mafa_A1_002_01", sample: "AnimalA"), style: .init(textColor: "#B00020", isItalic: true), author: "Analyst", timestamp: stamp),
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))

        let controller = makeCharacterizationController()
        controller.configure(result: result)
        let countColumnsVisible = !variant.hidesCountColumns
        pinCharacterizationMatrixPresentation(
            controller,
            standardColumns: ["genotype": true, "stableClusterID": false, "locus": true, "samples": countColumnsVisible, "uniqueReads": countColumnsVisible],
            referenceColumns: ["feature.allele": true, "source.organism": true, "record.definition": false]
        )
        var state = controller.testingDisplayState
        state.summaryViewMode = .matrix
        state.matrixMinimumReads = 5
        state.matrixMinimumPercent = 10
        if variant == .thresholded {
            state.hideLowSupport = false
            state.minimumSupportPercent = 7.5
            state.matrixMinimumPrevalencePercent = 40
        }
        if variant.appliesPrevalence {
            state.matrixMinimumPrevalencePercent = 40
        }
        controller.testingApplyDisplayStateImmediately(state)
        let matrix = controller.testingComparisonMatrix
        matrix.testingHideSamples(["AnimalD"])
        matrix.testingMoveSampleColumn(sample: "AnimalC", to: 0)
        controller.testingApplySmartCohort(cohort)
        return GenotypeCharacterizationScenario(root: root, bundleURL: bundleURL, result: result, controller: controller)
    }

    // MARK: Scenario B, genotype-only with manual haplotypes

    /// Three animals, no analysis and no metadata. Manual assignments for two
    /// animals at MHC-A and MHC-B, one label the validator rejects, one cell
    /// comment, haplotype cell colouring, the manual band expanded, min
    /// percent 10 on sample-retained reads and a pending quick search for one
    /// animal that the Excel capture settles.
    func makeGenotypeOnlyManualScenario() throws -> GenotypeCharacterizationScenario {
        typealias Fixture = GenotypeCharacterizationFixture
        let (root, bundleURL) = try Fixture.makeBundleFolder(prefix: "GenotypeCharacterizationManual", name: "manual")
        let calls = [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 60),
            makeCall(sample: "AnimalA", genotype: "03_Mafa_B_075_01", reads: 40),
            makeCall(sample: "AnimalB", genotype: "02_Mafa_A1_002_01", reads: 81),
            makeCall(sample: "AnimalB", genotype: "04_Mafa_B_082_01", reads: 10),
            makeCall(sample: "AnimalB", genotype: "05_Mafa_B_090_01", reads: 9),
            makeCall(sample: "AnimalC", genotype: "01_Mafa_A1_001_01", reads: 30),
            makeCall(sample: "AnimalC", genotype: "03_Mafa_B_075_01", reads: 30),
        ]
        let result = makeResult(
            bundleURL: bundleURL,
            samples: Fixture.sampleResults(for: calls, order: ["AnimalA", "AnimalB", "AnimalC"]),
            calls: calls
        )
        try ONTGenotypeResultBundle.writeManifest(result.manifest, to: bundleURL)
        var sidecar = Fixture.baseSidecar(preferredSummaryViewMode: nil)
        sidecar.manualHaplotypeAssignments = [
            .init(sample: "AnimalA", locus: "MHC-A", slot: .h1, label: "M1A", colorTokenIndex: 0, diagnosticAlleles: ["01_Mafa_A1_001_01"], notes: "Pedigree confirmed"),
            .init(sample: "AnimalA", locus: "MHC-A", slot: .h2, label: "M2A", colorTokenIndex: 1, diagnosticAlleles: ["02_Mafa_A1_002_01"], notes: ""),
            .init(sample: "AnimalA", locus: "MHC-B", slot: .h1, label: "M1B", colorTokenIndex: 2, diagnosticAlleles: ["03_Mafa_B_075_01"], notes: ""),
            .init(sample: "AnimalB", locus: "MHC-A", slot: .h1, label: "M3A", colorTokenIndex: 3, diagnosticAlleles: [], notes: "Provisional"),
            .init(sample: "AnimalB", locus: "MHC-B", slot: .h2, label: "bad\nlabel", colorTokenIndex: 4, diagnosticAlleles: [], notes: "Rejected by the validator"),
        ]
        sidecar.matrixComments = [
            .init(target: .cell(locus: "MHC-B", genotype: "04_Mafa_B_082_01", sample: "AnimalB"), body: "Low support", author: "Analyst", timestamp: Fixture.annotationTimestamp),
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))

        let controller = makeCharacterizationController()
        controller.configure(result: result)
        pinCharacterizationMatrixPresentation(
            controller,
            standardColumns: ["genotype": true, "stableClusterID": false, "locus": false, "samples": true, "uniqueReads": true]
        )
        var state = controller.testingDisplayState
        state.summaryViewMode = .matrix
        state.cellColorMode = .haplotype
        state.manualHaplotypeBandExpanded = true
        state.matrixMinimumPercent = 10
        state.matrixPercentDenominator = .sampleRetained
        controller.testingApplyDisplayStateImmediately(state)
        controller.testingTypeQuickSearchDebounced("AnimalB")
        return GenotypeCharacterizationScenario(root: root, bundleURL: bundleURL, result: result, controller: controller)
    }

    // MARK: Scenario C, haplotyped MiSeq without a resolvable definition

    /// Three animals and three loci with every call status, no definition
    /// anywhere so the literal analysis survives and the definition is
    /// synthesized, the identity-bound override matrix (including a nil
    /// identity beating a newer stale one on AnimalC MHC-DRB H1, and the later
    /// of two exact overrides winning on AnimalA MHC-B H2 although it is listed
    /// first) and one manual assignment that a haplotyped MiSeq result ignores.
    /// No (sample, locus) is called twice, because the delimited path traps on
    /// duplicates.
    func makeLiteralStatusMiSeqScenario() throws -> GenotypeCharacterizationScenario {
        typealias Fixture = GenotypeCharacterizationFixture
        let (root, bundleURL) = try Fixture.makeBundleFolder(prefix: "GenotypeCharacterizationLiteral", name: "literal")
        let revision = "revision-7"
        let definitionSetID = "characterization.literal-definitions"
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: Fixture.assayID,
            definitionSetID: definitionSetID,
            definitionSetName: "Characterization literal definitions",
            speciesName: "Test macaque",
            generatedAt: Fixture.analysisGeneratedAt,
            analysisRevisionID: revision,
            source: .deterministic,
            samples: [
                .init(sample: "AnimalA", calls: [
                    Fixture.locusCall("MHC-A", "M1A", "-", .called, matched: ["M1A": ["01_Mafa_A1_001_01"]], observed: ["01_Mafa_A1_001_01"]),
                    Fixture.locusCall("MHC-B", "M1B", "M2B", .called,
                        matched: ["M1B": ["03_Mafa_B_075_01"], "M2B": ["04_Mafa_B_082_01"]],
                        observed: ["03_Mafa_B_075_01", "04_Mafa_B_082_01"], notes: "Two diagnostic alleles observed"),
                    Fixture.locusCall("MHC-DRB", "M1DR|M2DR", "M3DR", .ambiguous,
                        matched: ["M1DR": ["06_Mafa_DRB_001_01"], "M2DR": ["06_Mafa_DRB_001_01"], "M3DR": ["07_Mafa_DRB_002_01"]],
                        observed: ["06_Mafa_DRB_001_01", "07_Mafa_DRB_002_01"],
                        notes: "GEN-02: M1DR|M2DR and M3DR cannot be distinguished from the observed diagnostic alleles"),
                ]),
                .init(sample: "AnimalB", calls: [
                    Fixture.locusCall("MHC-A", "M1A|M2A", "M1A|M2A", .ambiguous,
                        matched: ["M1A": ["01_Mafa_A1_001_01"], "M2A": ["01_Mafa_A1_001_01"]], observed: ["01_Mafa_A1_001_01"],
                        notes: "GEN-02: M1A|M2A cannot be distinguished from the observed diagnostic alleles"),
                    Fixture.locusCall("MHC-B", "ERR: NO HAP", "ERR: NO HAP", .noHaplotype, observed: ["05_Mafa_B_090_01"]),
                    Fixture.locusCall("MHC-DRB", "ERR: TMH (M1DR, M2DR, M3DR)", "ERR: TMH (M1DR, M2DR, M3DR)", .tooManyHaplotypes,
                        matched: ["M1DR": ["06_Mafa_DRB_001_01"], "M2DR": ["08_Mafa_DRB_003_01"], "M3DR": ["07_Mafa_DRB_002_01"]],
                        observed: ["06_Mafa_DRB_001_01", "07_Mafa_DRB_002_01", "08_Mafa_DRB_003_01"]),
                ]),
                .init(sample: "AnimalC", calls: [
                    Fixture.locusCall("MHC-A", "M2A", "?", .unresolvedSecondHaplotype,
                        matched: ["M2A": ["02_Mafa_A1_002_01"]], observed: ["02_Mafa_A1_002_01", "09_Mafa_A1_009_01"],
                        notes: "GEN-08: only M2A matched a defined haplotype"),
                    Fixture.locusCall("MHC-B", "Not assayed", "Not assayed", .notAssayed,
                        notes: "MHC-B was not observed anywhere in this run for the active definition set."),
                    Fixture.locusCall("MHC-DRB", "M2DR", "M3DR", .called,
                        matched: ["M2DR": ["08_Mafa_DRB_003_01"], "M3DR": ["07_Mafa_DRB_002_01"]],
                        observed: ["07_Mafa_DRB_002_01", "08_Mafa_DRB_003_01"]),
                ]),
            ]
        )
        let calls = [
            makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_001_01", reads: 60),
            makeCall(sample: "AnimalB", genotype: "02_Mafa_A1_002_01", reads: 70),
            makeCall(sample: "AnimalC", genotype: "03_Mafa_B_075_01", reads: 80),
        ]
        let result = makeResult(
            bundleURL: bundleURL,
            samples: Fixture.sampleResults(for: calls, order: ["AnimalA", "AnimalB", "AnimalC"]),
            calls: calls,
            haplotypeAnalysis: analysis
        )
        try ONTGenotypeResultBundle.writeManifest(result.manifest, to: bundleURL)

        let exact = GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity(
            assayID: Fixture.assayID, analysisRevisionID: revision, definitionSetID: definitionSetID
        )
        let stale = GenotypeAnnotationSidecar.CallOverrideAnalysisIdentity(
            assayID: Fixture.assayID, analysisRevisionID: "revision-6", definitionSetID: definitionSetID
        )
        var sidecar = Fixture.baseSidecar(preferredSummaryViewMode: "matrix")
        sidecar.callOverrides = [
            Fixture.override(sample: "AnimalA", locus: "MHC-A", slot: .h1, original: "M1A", call: "M3A",
                timestamp: "2026-09-02T10:00:00Z", identity: exact, operation: "exact-identity"),
            Fixture.override(sample: "AnimalA", locus: "MHC-B", slot: .h1, original: "M1B", call: "M9B",
                timestamp: "2026-09-02T10:05:00Z", identity: stale, operation: "stale-identity"),
            Fixture.override(sample: "AnimalC", locus: "MHC-DRB", slot: .h2, original: "M3DR", call: "M1DR",
                timestamp: "2026-09-02T10:10:00Z", identity: nil, operation: "nil-identity"),
            Fixture.override(sample: "AnimalB", locus: "MHC-DRB", slot: .h2, original: "ERR: TMH (M1DR, M2DR, M3DR)", call: "-",
                timestamp: "2026-09-02T10:15:00Z", identity: exact, operation: "dash"),
            Fixture.override(sample: "AnimalA", locus: "MHC-DRB", slot: .h2, original: "M3DR", call: "?",
                timestamp: "2026-09-02T10:20:00Z", identity: exact, operation: "question-mark"),
            Fixture.override(sample: "AnimalC", locus: "MHC-A", slot: .h1, original: "M2A", call: "M5A",
                timestamp: "yesterday", identity: exact, operation: "malformed-timestamp"),
            Fixture.override(sample: "AnimalB", locus: "MHC-A", slot: .h1, original: "M1A|M2A", call: "M1A",
                timestamp: "2026-09-02T10:25:00Z", identity: exact, operation: "slot-first"),
            Fixture.override(sample: "AnimalB", locus: "MHC-A", slot: .h1, original: "M1A|M2A", call: "M2A",
                timestamp: "2026-09-02T10:30:00Z", identity: nil, operation: "slot-second"),
            Fixture.override(sample: "AnimalC", locus: "MHC-DRB", slot: .h1, original: "M2DR", call: "M3DR",
                timestamp: "2026-09-02T10:35:00Z", identity: nil, operation: "nil-beats-stale"),
            Fixture.override(sample: "AnimalC", locus: "MHC-DRB", slot: .h1, original: "M2DR", call: "M9DR",
                timestamp: "2026-09-02T10:40:00Z", identity: stale, operation: "stale-newer-than-nil"),
            Fixture.override(sample: "AnimalA", locus: "MHC-B", slot: .h2, original: "M2B", call: "M8B",
                timestamp: "2026-09-02T10:50:00Z", identity: exact, operation: "exact-later-listed-first"),
            Fixture.override(sample: "AnimalA", locus: "MHC-B", slot: .h2, original: "M2B", call: "M7B",
                timestamp: "2026-09-02T10:45:00Z", identity: exact, operation: "exact-earlier-listed-second"),
        ]
        sidecar.manualHaplotypeAssignments = [
            .init(sample: "AnimalA", locus: "MHC-A", slot: .h1, label: "Manual-A", colorTokenIndex: 5, diagnosticAlleles: [], notes: "Ignored for haplotyped MiSeq"),
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))

        let controller = makeCharacterizationController()
        controller.configure(result: result)
        pinCharacterizationMatrixPresentation(
            controller,
            standardColumns: ["genotype": true, "stableClusterID": false, "locus": true, "samples": true, "uniqueReads": true]
        )
        var state = controller.testingDisplayState
        state.summaryViewMode = .matrix
        controller.testingApplyDisplayStateImmediately(state)
        return GenotypeCharacterizationScenario(root: root, bundleURL: bundleURL, result: result, controller: controller)
    }
}
