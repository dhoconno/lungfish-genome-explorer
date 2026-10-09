import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO

/// The catalog-to-matrix identity mapping the matrix UI and the Excel builder
/// share (Phase 2.3 finding S1, decision D4).
final class GenotypeCatalogMatrixIdentityTests: XCTestCase {
    private typealias Identity = GenotypeCatalogMatrixIdentity
    private typealias Target = GenotypeAnnotationSidecar.MatrixTarget

    private func row(
        kind: GenotypeReviewableRowCatalog.RowKind = .reference,
        callID: String,
        displayName: String,
        locus: String = "MHC-A",
        stableID: String? = nil,
        support: [String: Int]
    ) -> GenotypeReviewableRowCatalog.Row {
        .init(kind: kind, callID: callID, displayName: displayName, locus: locus, stableID: stableID,
              section: kind.rawValue, sortKey: callID, supportBySample: support)
    }

    /// GenBank-style reference metadata whose allele field names the allele
    /// of each reference sequence ID, the shape a `.lungfishref` built from
    /// IPD-MHC or GenBank records has.
    private func metadata(_ alleleBySequenceID: [String: String]) -> ONTGenotypeReferenceMetadata {
        .init(
            fields: [GenBankRecordDatabase.FieldDefinition(
                key: "feature.allele", displayTitle: "Allele", valueType: "text", sourceCategory: "feature", preferredOrder: 0)],
            recordsBySequenceName: alleleBySequenceID.mapValues { ["feature.allele": $0] },
            alleleFieldKey: "feature.allele"
        )
    }

    func testARowNamesTheNativeRowByCallIDDisplayNameOrAlleleName() throws {
        let known = Identity.NativeRow(locus: "MHC-A", genotype: "01_Mafa_A1_001_01", stableClusterID: nil)
        let metadata = Identity.NativeRow(locus: "MHC-A", genotype: "MCM_0102|alleles=Mafa-A1*002:01", stableClusterID: nil)
        let candidate = Identity.NativeRow(locus: "MHC-A1", genotype: "Mafa-A1*900:01_nov", stableClusterID: "cluster-9")
        let native = [known, metadata, candidate]

        XCTAssertEqual(try Identity.resolve(
            row(callID: "01_Mafa_A1_001_01", displayName: "Mafa-A1*001:01", support: [:]), among: native).native, known)
        XCTAssertEqual(try Identity.resolve(
            row(callID: "reference:MHC-A:Mafa-A1*002:01", displayName: "Mafa-A1*002:01", support: [:]), among: native).native, metadata)
        let resolved = try Identity.resolve(
            row(kind: .candidate, callID: "candidate:MHC-A:cluster-9", displayName: "Mafa-A1*900:01_nov",
                stableID: "cluster-9", support: [:]), among: native)
        XCTAssertEqual(resolved.native, candidate)
        XCTAssertEqual(resolved.target(sample: "S1"),
            .cell(locus: "MHC-A1", genotype: "Mafa-A1*900:01_nov", sample: "S1", stableClusterID: "cluster-9"),
            "the cell keeps the native locus spelling")
        // The stable ID is part of the identity, so a reference row never names a candidate.
        XCTAssertNil(try Identity.resolve(
            row(callID: "reference:MHC-A:Mafa-A1*900:01_nov", displayName: "Mafa-A1*900:01_nov", support: [:]), among: native).native)
    }

    func testAnUnmatchedRowStandsAloneAndALaterRowCanNameIt() throws {
        let catalog = GenotypeReviewableRowCatalog(samples: ["S1", "S2"], rows: [
            row(callID: "reference:MHC-B:Mafa-B*099:01", displayName: "Mafa-B*099:01", locus: "MHC-B", support: ["S1": 0, "S2": 0]),
            row(callID: "Mafa-B*099:01", displayName: "Mafa-B*099:01", locus: "MHC-B", support: ["S1": 0, "S2": 0]),
        ])
        let mapping = try Identity.map(catalog, nativeRows: [], referenceMetadata: nil, into: [:])
        let standalone = Identity.NativeRow(locus: "MHC-B", genotype: "Mafa-B*099:01", stableClusterID: nil)
        XCTAssertNil(mapping.resolutions[0].native)
        XCTAssertEqual(mapping.resolutions[0].matrixRow, standalone)
        XCTAssertEqual(mapping.resolutions[1].native, standalone, "the second row names the row the first one added")
        XCTAssertEqual(mapping.support, [
            .cell(locus: "MHC-B", genotype: "Mafa-B*099:01", sample: "S1"): 0,
            .cell(locus: "MHC-B", genotype: "Mafa-B*099:01", sample: "S2"): 0,
        ])
    }

    func testAmbiguityAndDisagreementRefuseWithTheWorkbookReasons() {
        let one = Identity.NativeRow(locus: "MHC-A", genotype: "01_A", stableClusterID: nil)
        let two = Identity.NativeRow(locus: "MHC-A", genotype: "02_A", stableClusterID: nil)
        let ambiguous = row(callID: "01_A", displayName: "02_A", support: ["S1": 0])
        XCTAssertThrowsError(try Identity.resolve(ambiguous, among: [one, two])) { error in
            XCTAssertEqual(error as? Identity.Refusal, .ambiguousIdentity(callID: "01_A"))
            XCTAssertEqual((error as? Identity.Refusal)?.message, "ambiguous catalog to native row identity")
        }

        let cell = Target.cell(locus: "MHC-A", genotype: "01_A", sample: "S1")
        let observed: [Target: Int] = [cell: 7]
        let disagreeing = row(callID: "reference:MHC-A:01_A", displayName: "01_A", support: ["S1": 5, "S2": 0])
        XCTAssertThrowsError(try Identity.map(.init(samples: ["S1", "S2"], rows: [disagreeing]), nativeRows: [one],
                                              referenceMetadata: nil, into: observed)) { error in
            XCTAssertEqual(error as? Identity.Refusal, .supportDisagreement(target: cell, observed: 7, catalog: 5))
            XCTAssertEqual((error as? Identity.Refusal)?.message, "catalog support disagrees with captured observations")
        }

        // An agreeing observation stays and the rest of the roster is attested.
        var support = observed
        let agreeing = row(callID: "reference:MHC-A:01_A", displayName: "01_A", support: ["S1": 7, "S2": 0])
        XCTAssertNoThrow(try Identity.merge(Identity.Resolution(row: agreeing, native: one), into: &support))
        XCTAssertEqual(support, [cell: 7, .cell(locus: "MHC-A", genotype: "01_A", sample: "S2"): 0])
    }

    // MARK: Accession-named native rows (Phase 2.3 decision D4)

    /// A full-length call carries its reference sequence ID, here the IPD
    /// accession NHP01222, which parses to the pseudo-locus MHC-NHP01222
    /// (finding N9). The catalog names the same allele Mafa-A1*001:01 under
    /// MHC-A, so no lookup by the native locus and a name can meet the row.
    /// The row names the native row through the allele its reference record
    /// carries, keyed by that allele's own locus, and its zero lands on the
    /// accession row where Mark False Negative reads it.
    func testAReferenceRowNamesTheAccessionRowThroughItsRecordAllele() throws {
        let result = GenotypeTestFixtures.makeResult(
            calls: [GenotypeTestFixtures.makeCall(sample: "S1", genotype: "NHP01222", reads: 15)],
            referenceMetadata: metadata(["NHP01222": "Mafa-A1*001:01"]),
            reviewableRowCatalog: .init(samples: ["S1", "S2"], rows: [
                row(callID: "reference:MHC-A:Mafa-A1*001:01", displayName: "Mafa-A1*001:01", support: ["S1": 15, "S2": 0]),
            ])
        )
        let accession = Identity.NativeRow(locus: "MHC-NHP01222", genotype: "NHP01222", stableClusterID: nil)
        XCTAssertEqual(Identity.nativeRows(in: result), [accession], "the native row sits at the accession's pseudo-locus")
        let catalog = try XCTUnwrap(result.reviewableRowCatalog)
        let mapping = try Identity.map(catalog, nativeRows: [accession], referenceMetadata: result.referenceMetadata, into: [:])
        XCTAssertEqual(mapping.resolutions.map(\.native), [accession])
        XCTAssertNil(try Identity.resolve(catalog.rows[0], among: [accession]).native,
                     "without the reference metadata the row stands alone, as before")

        // Both callers pass the bundle's reference metadata, so the matrix
        // reads the same identity the workbook writes.
        let support = GenotypeMatrixReviewEligibility.rawSupport(in: result)
        let zero = Target.cell(locus: "MHC-NHP01222", genotype: "NHP01222", sample: "S2")
        XCTAssertEqual(mapping.resolutions[0].target(sample: "S2"), zero)
        XCTAssertEqual(support, [
            .cell(locus: "MHC-NHP01222", genotype: "NHP01222", sample: "S1"): 15,
            zero: 0,
        ], "the catalog's zero is attested on the accession row and no row stands alone under the allele name")
        XCTAssertTrue(GenotypeMatrixReviewEligibility.permits(.falseNegative, rawSupport: support[zero]))
    }

    /// Two sequence IDs that carry one allele name, for example a genomic and
    /// a cDNA record, sum into one catalog row that equals neither native row.
    /// The row stands alone as before and nothing refuses, so the matrix keeps
    /// its catalog zeros and the Excel export keeps working.
    func testTwoSequenceIDsSharingAnAlleleNameLeaveTheRowStandingAlone() {
        let result = GenotypeTestFixtures.makeResult(
            calls: [
                GenotypeTestFixtures.makeCall(sample: "S1", genotype: "NHP01222", reads: 15),
                GenotypeTestFixtures.makeCall(sample: "S2", genotype: "NHP01223", reads: 9),
            ],
            referenceMetadata: metadata(["NHP01222": "Mafa-A1*001:01", "NHP01223": "Mafa-A1*001:01"]),
            reviewableRowCatalog: .init(samples: ["S1", "S2"], rows: [
                row(callID: "reference:MHC-A:Mafa-A1*001:01", displayName: "Mafa-A1*001:01", support: ["S1": 15, "S2": 9]),
            ])
        )
        XCTAssertNoThrow(try Identity.map(
            result.reviewableRowCatalog!, nativeRows: Identity.nativeRows(in: result),
            referenceMetadata: result.referenceMetadata, into: [:]))
        XCTAssertEqual(GenotypeMatrixReviewEligibility.rawSupport(in: result), [
            .cell(locus: "MHC-NHP01222", genotype: "NHP01222", sample: "S1"): 15,
            .cell(locus: "MHC-NHP01223", genotype: "NHP01223", sample: "S2"): 9,
            .cell(locus: "MHC-A", genotype: "Mafa-A1*001:01", sample: "S1"): 15,
            .cell(locus: "MHC-A", genotype: "Mafa-A1*001:01", sample: "S2"): 9,
        ])
    }

    /// A row that names a native row by its display name keeps that match.
    /// The record-allele fallback runs only when nothing else matched, so an
    /// accession row whose record carries the same allele does not make the
    /// row ambiguous.
    func testARowThatMatchesByNameKeepsItsMatchBesideAnAccessionAlias() {
        let result = GenotypeTestFixtures.makeResult(
            calls: [
                GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mafa-A1*001:01", reads: 12),
                GenotypeTestFixtures.makeCall(sample: "S2", genotype: "NHP01222", reads: 15),
            ],
            referenceMetadata: metadata(["NHP01222": "Mafa-A1*001:01"]),
            reviewableRowCatalog: .init(samples: ["S1", "S2"], rows: [
                row(callID: "reference:MHC-A:Mafa-A1*001:01", displayName: "Mafa-A1*001:01", support: ["S1": 12, "S2": 0]),
            ])
        )
        XCTAssertEqual(GenotypeMatrixReviewEligibility.rawSupport(in: result), [
            .cell(locus: "MHC-A", genotype: "Mafa-A1*001:01", sample: "S1"): 12,
            .cell(locus: "MHC-A", genotype: "Mafa-A1*001:01", sample: "S2"): 0,
            .cell(locus: "MHC-NHP01222", genotype: "NHP01222", sample: "S2"): 15,
        ])
    }

    /// The identity set the matrix maps against equals the rows of the
    /// unfiltered projection the Excel builder maps against.
    func testNativeRowsAreTheRowsOfTheUnfilteredMatrixProjection() throws {
        let calls = [
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: "01_Mafa_A1_001_01", reads: 9),
            GenotypeTestFixtures.makeCall(sample: "S2", genotype: "01_Mafa_A1_001_01", reads: 0),
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: "01_Mafa_A1_001_01", reads: 3),
            GenotypeTestFixtures.makeCall(sample: "S2", genotype: "03_Mafa_B_075_01", reads: 12),
        ]
        let candidates = GenotypeLocusDenominatorFixtures.candidateDocument(
            candidates: [("shared-1", "Mafa-A1*900:01_nov", "MHC-A1"), ("silent-2", "Mafa-B*900:01_nov", "MHC-B")],
            observations: [("shared-1", "S1", 6), ("shared-1", "S2", 4)]
        )
        let unnameable = ONTMHCUnnameableClustersDocument(
            schemaVersion: 1,
            createdAt: "2026-07-20T00:00:00Z",
            thresholds: .defaults,
            sequenceFASTA: .init(path: "unnameable.fasta", sha256: String(repeating: "a", count: 64), sizeBytes: 1),
            clusters: [
                try unnameableRecord(id: "span-3", reason: .incompleteReferenceSpan, interpreting: candidates.candidates[0]),
                try unnameableRecord(id: "coverage-4", reason: .insufficientCoverage, interpreting: candidates.candidates[1]),
                try unnameableRecord(id: "plain-5", reason: .noAlignment, interpreting: nil),
            ],
            observations: [
                ONTMHCCandidateObservation(
                    stableClusterID: "span-3", sampleID: "S1", readGroupID: "S1", sourceClusterIDs: ["source-span-3"],
                    sourceClusterReadCounts: ["source-span-3": 5], aggregatedSampleReadCount: 5, evidence: []
                ),
            ]
        )
        let base = GenotypeTestFixtures.makeResult(calls: calls)
        let result = ONTGenotypeResultBundleData(
            bundleURL: base.bundleURL, manifest: base.manifest, artifacts: base.artifacts, stats: base.stats,
            calls: calls, samples: base.samples, haplotypeAnalysis: nil,
            mhcCandidates: candidates, mhcUnnameableClusters: unnameable,
            mhcCandidateSequencesByStableClusterID: [:], mhcCandidateGenBankArtifactURLs: .empty,
            mhcAlignmentArtifactURLs: .empty, mhcReferenceVisualizations: nil, integrityWarnings: [],
            referenceMetadata: nil, provisionalExon2SequencesByGenotype: [:], provisionalExon2ArtifactURLs: .empty
        )
        let projection = GenotypeMatrixBaseProjection(
            calls: calls, samples: result.samples, candidateDocument: candidates, unnameableDocument: unnameable,
            logicalSampleNames: ["S1", "S2"], candidateSettings: .default
        )
        let projected = projection.derive(.unfiltered).rows.map {
            Identity.NativeRow(locus: $0.locus, genotype: $0.genotype, stableClusterID: $0.stableClusterID)
        }
        let native = Identity.nativeRows(in: result)
        XCTAssertEqual(Set(native), Set(projected))
        XCTAssertEqual(native.count, projected.count)
        XCTAssertEqual(native.count, 5, "two known rows, two candidates and the interpreted incomplete-span cluster")
    }

    /// The mapping runs twice on every bundle open and four times per Excel
    /// export, so it has to stay cheap on a real catalog. This builds a bundle
    /// of realistic size, 50 animals, 300 observed alleles and a 1,500-row
    /// production-shape reference catalog of which 1,200 rows stand alone, and
    /// prints the median wall time of `rawSupport(in:)`. It asserts the shape
    /// of the result and never the time, so load cannot make it flake.
    func testRawSupportTimingOnARealisticProductionCatalog() {
        let samples = (1...50).map { String(format: "Animal%03d", $0) }
        let observed = (1...300).map { String(format: "%04d_Mafa_A1_%04d", $0, $0) }
        let unobserved = (301...1500).map { String(format: "%04d_Mafa_A1_%04d", $0, $0) }
        var calls: [ONTGenotypeCall] = []
        for (index, genotype) in observed.enumerated() {
            for offset in 0..<10 {
                calls.append(GenotypeTestFixtures.makeCall(
                    sample: samples[(index + offset * 5) % samples.count], genotype: genotype, reads: 20 + offset))
            }
        }
        XCTAssertTrue(calls.allSatisfy { $0.locusGroup == "MHC-A" })
        var observedReads: [String: [String: Int]] = [:]
        for call in calls {
            observedReads[call.genotype, default: [:]][call.sample] = call.passedUniqueReads
        }
        let rows = (observed + unobserved).map { allele in
            GenotypeReviewableRowCatalog.Row(
                kind: .reference, callID: "reference:MHC-A:\(allele)", displayName: allele, locus: "MHC-A",
                stableID: nil, section: "reference", sortKey: allele,
                supportBySample: Dictionary(uniqueKeysWithValues: samples.map { ($0, observedReads[allele]?[$0] ?? 0) })
            )
        }
        let result = GenotypeTestFixtures.makeResult(
            calls: calls, reviewableRowCatalog: GenotypeReviewableRowCatalog(samples: samples, rows: rows))

        /// The median of seven timed runs after one warm-up run.
        func medianMilliseconds(_ body: () -> Void) -> Double {
            var milliseconds: [Double] = []
            for _ in 0..<8 {
                let started = DispatchTime.now().uptimeNanoseconds
                body()
                milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            }
            return milliseconds.dropFirst().sorted()[3]
        }
        var support: [Target: Int] = [:]
        let total = medianMilliseconds { support = GenotypeMatrixReviewEligibility.rawSupport(in: result) }
        // Where the time goes. The floor is writing the 75,000 attested cells
        // into a dictionary, which rawSupport paid before S1 as well.
        let catalog = result.reviewableRowCatalog!
        let nativeRows = GenotypeCatalogMatrixIdentity.nativeRows(in: result)
        let nativeOnly = GenotypeMatrixReviewEligibility.rawSupport(in: GenotypeTestFixtures.makeResult(calls: calls))
        let nativeRowsOnly = medianMilliseconds { _ = GenotypeCatalogMatrixIdentity.nativeRows(in: result) }
        let mapOnly = medianMilliseconds {
            _ = try? GenotypeCatalogMatrixIdentity.map(catalog, nativeRows: nativeRows, referenceMetadata: nil, into: nativeOnly)
        }
        let floor = medianMilliseconds {
            var cells = nativeOnly
            for row in catalog.rows {
                for sample in samples {
                    cells[.cell(locus: "MHC-A", genotype: row.displayName, sample: sample)] = row.supportBySample[sample] ?? 0
                }
            }
        }
        print(String(format: "rawSupport(in:) over 1,500 catalog rows, 300 native rows and 50 samples, median of 7 runs after a warm-up: %.1f ms (nativeRows %.1f ms, map %.1f ms, dictionary floor for 75,000 cells %.1f ms)",
                     total, nativeRowsOnly, mapOnly, floor))
        XCTAssertEqual(support.count, 1_500 * 50, "every catalog cell is attested under a display identity")
        XCTAssertEqual(support[.cell(locus: "MHC-A", genotype: observed[0], sample: samples[0])], 20)
        XCTAssertEqual(support[.cell(locus: "MHC-A", genotype: unobserved[0], sample: samples[0])], 0)
        XCTAssertFalse(support.keys.contains { key in
            if case let .cell(_, genotype, _, _) = key { return genotype.hasPrefix("reference:") }
            return false
        })
    }

    private func unnameableRecord(
        id: String,
        reason: ONTMHCUnnameableReason,
        interpreting candidate: ONTMHCCandidateRecord?
    ) throws -> ONTMHCUnnameableRecord {
        ONTMHCUnnameableRecord(
            stableClusterID: id,
            reason: reason,
            failedMetrics: ["reference_span": 0.5],
            supportClass: .shared,
            independentSampleCount: 1,
            occurrenceCount: 1,
            totalClusterReads: 5,
            supportingSampleIDs: ["S1"],
            fastaRecordID: id,
            sequenceSHA256: String(repeating: "b", count: 64),
            reciprocalHitSummary: try ONTMHCReciprocalQueryHitSummary(
                bamPath: "unmatched.bam",
                queryName: id,
                alignmentCount: 1,
                targetAlignmentCounts: ["reference": 1],
                exactMatchTargetNames: [],
                closestMatchTargetNames: ["reference"]
            ),
            selectedEvidence: nil,
            selectedAlignmentIsReverse: nil,
            candidateInterpretation: candidate.map(ONTMHCIncompleteCandidateInterpretation.init(candidate:))
        )
    }
}
