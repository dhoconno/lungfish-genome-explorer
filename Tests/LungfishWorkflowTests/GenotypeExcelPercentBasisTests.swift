import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Decision D3 of the Phase 2.3 follow-up. When a bundle declares candidate
/// artifacts that the loader rejected, its locus percents and haplotype calls
/// count known alleles only, and the workbook's Export Metadata "Percent
/// basis" row must say so. A bundle whose candidate artifacts loaded, or that
/// declares none, keeps the exact bytes of today's row.
final class GenotypeExcelPercentBasisTests: XCTestCase {
    private let timestamp = "2026-10-09T00:00:00Z"

    private static let knownAllelesOnlyBasis =
        "known alleles only, because the bundle's candidate artifacts failed validation"

    /// A full-length manifest declaring a candidate JSON and FASTA pair.
    private static func candidateDeclaration() -> ONTMHCCandidateArtifactManifest {
        ONTMHCCandidateArtifactManifest(
            schemaVersion: 2,
            genotypingEvidence: nil,
            reciprocalEvidence: nil,
            candidateJSON: ONTMHCArtifactReference(
                path: "candidate-alleles.json", sha256: String(repeating: "a", count: 64), sizeBytes: 1
            ),
            candidateFASTA: ONTMHCArtifactReference(
                path: "candidate_alleles.fasta", sha256: String(repeating: "b", count: 64), sizeBytes: 1
            ),
            unnameableJSON: nil,
            unnameableFASTA: nil
        )
    }

    private func calls() -> [ONTGenotypeCall] {
        [
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mamu-A1*001:01", reads: 40),
            GenotypeTestFixtures.makeCall(sample: "S1", genotype: "Mamu-A1*002:01", reads: 10),
        ]
    }

    private func capture(_ result: ONTGenotypeResultBundleData) throws -> GenotypeWorkbookPresentation.Snapshot {
        try GenotypeExcelSnapshotBuilder.capture(
            result: result, sidecar: .empty(generatedAt: timestamp),
            allProjection: nil, filteredProjection: nil, generatedAt: timestamp,
            authority: .init(analysis: nil), filter: .unfiltered
        )
    }

    private func metadata(_ snapshot: GenotypeWorkbookPresentation.Snapshot) -> [String: String] {
        Dictionary(
            snapshot.metadata.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func testPercentBasisRowSaysKnownAllelesOnlyWhenCandidateArtifactsFailedValidation() throws {
        // A result whose manifest declares candidate artifacts while no
        // candidate document loaded is what the loader hands back after a
        // rejected candidate artifact.
        let rejected = GenotypeTestFixtures.makeResult(
            calls: calls(),
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            mhcCandidateArtifacts: Self.candidateDeclaration()
        )
        XCTAssertNil(rejected.mhcCandidates)

        let row = try XCTUnwrap(metadata(try capture(rejected))["Percent basis"])
        XCTAssertTrue(row.contains(Self.knownAllelesOnlyBasis), row)
        XCTAssertFalse(row.contains("known alleles plus candidate clusters"), row)
        XCTAssertTrue(row.hasPrefix("Per-sample read fraction for known and candidate rows alike. viewedLocus is per source locus: "), row)
        XCTAssertTrue(row.hasSuffix(". sampleRetained: unique retained reads of the whole sample."), row)
        XCTAssertNotEqual(row, GenotypeExcelSnapshotBuilder.percentBasisDescription)
        XCTAssertEqual(row, GenotypeExcelSnapshotBuilder.percentBasisDescription(for: rejected))
        XCTAssertEqual(GenotypeLocusDenominator.basis(for: rejected), .knownAllelesOnlyAfterRejectedCandidateArtifacts)
    }

    func testPercentBasisRowKeepsItsBytesForBundlesWithoutARejectedCandidateBasis() throws {
        let undeclared = GenotypeTestFixtures.makeResult(
            calls: calls(),
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue
        )
        XCTAssertEqual(metadata(try capture(undeclared))["Percent basis"], GenotypeExcelSnapshotBuilder.percentBasisDescription)

        let miSeq = GenotypeTestFixtures.makeResult(calls: calls())
        XCTAssertEqual(metadata(try capture(miSeq))["Percent basis"], GenotypeExcelSnapshotBuilder.percentBasisDescription)
        XCTAssertTrue(
            GenotypeExcelSnapshotBuilder.percentBasisDescription.contains("known alleles plus candidate clusters at that locus"),
            "the static text the CLI provenance defaults record is unchanged"
        )
    }
}
