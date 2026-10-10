import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
import XCTest
@testable import LungfishCLI

/// A full-length result without a haplotype analysis exports every unique
/// call (N9 review finding 1).
///
/// Before N9 every full-length accession was its own locus, so the H1 and H2
/// table held every call. Once calls take the gene locus of their reference
/// record, an animal has several alleles at MHC-A, and a table with one H1
/// cell per locus would drop all but one of them. The genotype-only
/// full-length table therefore writes numbered allele columns per locus.
final class GenotypeExportFullLengthAlleleColumnsTests: XCTestCase {
    private static let records: [String: (allele: String, gene: String)] = [
        "NHP01270": ("Mafa-A2*05:25:01:01", "A2"),
        "NHP01718": ("Mafa-A1*018:01:01:01", "A1"),
        "NHP01800": ("Mafa-A1*019:01", "A1"),
        "NHP02000": ("Mafa-A3*13:03", "A3"),
        "NHP05007": ("Mafa-B*046:12:01:01", "B"),
    ]

    private static func metadata() -> ONTGenotypeReferenceMetadata {
        ONTGenotypeReferenceMetadata(
            fields: [
                GenBankRecordDatabase.FieldDefinition(
                    key: "feature.allele", displayTitle: "Allele", valueType: "text",
                    sourceCategory: "feature", preferredOrder: 0),
                GenBankRecordDatabase.FieldDefinition(
                    key: "feature.gene", displayTitle: "Gene", valueType: "text",
                    sourceCategory: "feature", preferredOrder: 1),
            ],
            recordsBySequenceName: records.mapValues {
                ["feature.allele": $0.allele, "feature.gene": $0.gene]
            },
            alleleFieldKey: "feature.allele"
        )
    }

    private static func result(_ calls: [ONTGenotypeCall], kind: String) -> ONTGenotypeResultBundleData {
        let samples = Dictionary(grouping: calls, by: \.sample).sorted { $0.key < $1.key }.map { sample, calls in
            ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: calls.reduce(0) { $0 + $1.passedAlignments },
                passedUniqueReads: calls.reduce(0) { $0 + $1.passedUniqueReads },
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: calls
            )
        }
        return GenotypeTestFixtures.makeResult(
            samples: samples, calls: calls, kind: kind, referenceMetadata: metadata())
    }

    private static func call(_ sample: String, _ genotype: String, _ reads: Int) -> ONTGenotypeCall {
        GenotypeTestFixtures.makeCall(sample: sample, genotype: genotype, reads: reads)
    }

    /// Four A alleles and one B allele for one animal, two A alleles for the
    /// other, one duplicate row and one read-count tie.
    private static let fullLengthCalls = [
        call("CR1178", "NHP01270", 674),
        call("CR1178", "NHP01718", 712),
        call("CR1178", "NHP02000", 90),
        call("CR1178", "NHP01800", 90),
        call("CR1178", "NHP05007", 300),
        call("CR1178", "NHP01270", 12),
        call("CR2001", "NHP01800", 40),
        call("CR2001", "NHP01270", 55),
    ]

    func testFullLengthGenotypeOnlyTableWritesEveryUniqueCallInNumberedAlleleColumns() throws {
        let result = Self.result(Self.fullLengthCalls, kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue)
        XCTAssertEqual(Set(result.calls.map(\.locusGroup)), ["MHC-A", "MHC-B"], "the fixture must be stamped")

        let matrix = try GenotypeXlsxWorkbookWriter.MatrixBuilder.build(
            from: result,
            sidecar: .empty(generatedAt: "2026-10-09T00:00:00Z")
        )
        let csv = GenotypeXlsxWorkbookWriter.renderDelimited(matrix, separator: ",")

        XCTAssertEqual(
            csv,
            """
            Sample,MHC-A allele 1,MHC-A allele 2,MHC-A allele 3,MHC-A allele 4,MHC-B allele 1
            CR1178,NHP01718,NHP01270,NHP01800,NHP02000,NHP05007
            CR2001,NHP01270,NHP01800,,,

            """
        )

        let uniqueCalls = Set(result.calls.map { "\($0.sample)|\($0.genotype)" })
        let cells = matrix.rows.flatMap { row in
            row.cells.map(\.label).filter { !$0.isEmpty }.map { "\(row.sample)|\($0)" }
        }
        XCTAssertEqual(cells.count, uniqueCalls.count, "one non-empty cell per unique call")
        XCTAssertEqual(Set(cells), uniqueCalls, "no call is dropped")
    }

    /// An amplicon genotype-only table keeps its H1 and H2 layout.
    func testAmpliconGenotypeOnlyTableKeepsTheH1AndH2Layout() throws {
        let result = Self.result(
            [
                Self.call("S1", "Mafa-G_02:31:01:01|OR823640", 10),
                Self.call("S1", "Mafa-DPA1_02:04|OR823641", 20),
            ],
            kind: GenotypeResultWorkflowKind.miSeqAmpliconMHCGenotype.rawValue
        )
        let matrix = try GenotypeXlsxWorkbookWriter.MatrixBuilder.build(
            from: result,
            sidecar: .empty(generatedAt: "2026-10-09T00:00:00Z")
        )
        XCTAssertEqual(
            GenotypeXlsxWorkbookWriter.renderDelimited(matrix, separator: ","),
            """
            Sample,MHC-DPA1 H1,MHC-DPA1 H2,MHC-G H1,MHC-G H2
            S1,Mafa-DPA1_02:04|OR823641,,Mafa-G_02:31:01:01|OR823640,

            """
        )
    }
}
