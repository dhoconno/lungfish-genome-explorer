import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// GEN-05/GEN-06 (decisions D13/D14) in the Excel capture: the Filtered
/// matrix applies Min percent as a per-sample read fraction over the shared
/// source-locus denominator, and the Filters (Export Metadata) sheet states
/// the percent basis and the separate "Seen in" prevalence control.
final class GenotypeExcelThresholdSemanticsTests: XCTestCase {
    private let timestamp = "2026-09-24T00:00:00Z"

    private func cohortResult() -> ONTGenotypeResultBundleData {
        let animals = (1...30).map { String(format: "A%02d", $0) }
        let calls = animals.map { animal -> ONTGenotypeCall in
            let reads = animal == "A01" ? 40 : (animal == "A02" || animal == "A03" ? 998 : 1_000)
            return GenotypeTestFixtures.makeCall(sample: animal, genotype: "Mafa-A1*001:01", reads: reads)
        }
        func candidate(_ id: String, _ name: String, _ samples: [String]) -> ONTMHCCandidateRecord {
            ONTMHCCandidateRecord(stableClusterID: id, provisionalName: name, locus: "MHC-A1", classification: .novel,
                supportClass: samples.count > 1 ? .shared : .singleton, closestReferenceName: "Mafa-A1*001:01",
                closestReferenceClass: .genomicDNA, snpCount: 1, insertedBases: 0, deletedBases: 0, longGapBases: 0,
                comparableBases: 2_000, shorterCoverage: 1, identity: 0.99, mappingQuality: 60, alignmentScore: 2_000,
                independentSampleCount: samples.count, occurrenceCount: samples.count, totalClusterReads: 64,
                supportingSampleIDs: samples, fastaRecordID: id, sequenceSHA256: String(repeating: "b", count: 64),
                selectedEvidence: .init(bamPath: "evidence.bam", queryName: id, referenceName: "Mafa-A1*001:01",
                    readGroupID: nil, referenceStart: 1, cigar: "2000M"))
        }
        func observation(_ id: String, _ sample: String, _ reads: Int) -> ONTMHCCandidateObservation {
            .init(stableClusterID: id, sampleID: sample, readGroupID: sample, sourceClusterIDs: [id + sample],
                sourceClusterReadCounts: [id + sample: reads], aggregatedSampleReadCount: reads, evidence: [])
        }
        let document = ONTMHCCandidateAllelesDocument(schemaVersion: 1, createdAt: timestamp, thresholds: .defaults,
            inputs: [], evidence: [],
            sequenceFASTA: .init(path: "candidate.fasta", sha256: String(repeating: "a", count: 64), sizeBytes: 1),
            candidates: [
                candidate("private", "Mafa-A1*900:01_nov", ["A01"]),
                candidate("shared", "Mafa-A1*901:01_nov", ["A02", "A03"]),
            ],
            observations: [observation("private", "A01", 60), observation("shared", "A02", 2), observation("shared", "A03", 2)])
        let original = GenotypeTestFixtures.makeResult(calls: calls)
        return ONTGenotypeResultBundleData(bundleURL: original.bundleURL, manifest: original.manifest, artifacts: original.artifacts,
            stats: original.stats, calls: calls, samples: [], haplotypeAnalysis: nil,
            mhcCandidates: document, mhcUnnameableClusters: nil, mhcCandidateSequencesByStableClusterID: [:],
            integrityWarnings: [], referenceMetadata: nil)
    }

    private func capture(_ filter: GenotypeMatrixBaseProjection.Filter) throws -> GenotypeWorkbookPresentation.Snapshot {
        try GenotypeExcelSnapshotBuilder.capture(result: cohortResult(), sidecar: .empty(generatedAt: timestamp),
            allProjection: nil, filteredProjection: nil, generatedAt: timestamp, authority: .init(analysis: nil),
            filter: filter)
    }

    private func metadata(_ snapshot: GenotypeWorkbookPresentation.Snapshot) -> [String: String] {
        Dictionary(snapshot.metadata.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }, uniquingKeysWith: { first, _ in first })
    }

    func testFilteredSheetKeepsPrivateNovelAlleleAndHidesLowFractionSharedCandidate() throws {
        let snapshot = try capture(.init(matrixMinimumPercent: 5))
        let stableIDs = Set(snapshot.filteredMatrix.rows.compactMap(\.target.stableClusterID))
        XCTAssertEqual(stableIDs, ["private"])
        let row = try XCTUnwrap(snapshot.filteredMatrix.rows.first { $0.target.stableClusterID == "private" })
        XCTAssertEqual(row.cells.first { $0.sampleID == "A01" }?.displayValue, 60)
        XCTAssertEqual(snapshot.allMatrix.rows.filter { $0.target.stableClusterID != nil }.count, 2, "All is never redacted")

        let lines = metadata(snapshot)
        XCTAssertEqual(lines["Minimum percent"], "5.0")
        XCTAssertEqual(lines["Percent basis"], GenotypeExcelSnapshotBuilder.percentBasisDescription)
        XCTAssertTrue(lines["Percent basis"]?.contains("per source locus") == true)
        XCTAssertEqual(lines["Seen in at least N% of animals"], "0.0")
        XCTAssertNotNil(lines["Prevalence basis"])
        XCTAssertNil(lines["Candidate percent basis"], "candidates no longer have their own percent meaning")
    }

    func testSeenInAnimalsIsItsOwnFiltersSheetLineAndHidesThePrivateAllele() throws {
        let snapshot = try capture(.init(matrixMinimumPercent: 5, minimumPrevalencePercent: 5))
        XCTAssertTrue(snapshot.filteredMatrix.rows.allSatisfy { $0.target.stableClusterID == nil })
        XCTAssertEqual(snapshot.filteredMatrix.rows.map(\.target.genotype), ["Mafa-A1*001:01"])
        XCTAssertEqual(metadata(snapshot)["Seen in at least N% of animals"], "5.0")
        XCTAssertEqual(metadata(snapshot)["Minimum percent"], "5.0")
    }
}
