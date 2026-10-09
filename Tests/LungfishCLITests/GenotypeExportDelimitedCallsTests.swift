import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
import XCTest
@testable import LungfishCLI

/// Finding SF2 of the Phase 2.3 design review. `genotype export` reports one
/// set of haplotype calls whatever the container format, so the H1 and H2
/// columns of its CSV and TSV matrix must equal the Effective H1 and H2 of
/// the workbook's Haplotype Calls sheet for the same bundle and sidecar.
final class GenotypeExportDelimitedCallsTests: XCTestCase {
    private typealias Fixtures = GenotypeExportCallFixtures

    /// The MiSeq scenario as the delimited matrix lays it out.
    private static let miSeqRows = [
        ["Sample", "MHC-A H1", "MHC-A H2", "MHC-DR H1", "MHC-DR H2"],
        ["S1", "M1A", "M2A", "M5", "M2"],
        ["S2", "M1A", "-", "M3", "M4"],
    ]

    /// The ONT scenario as the delimited matrix lays it out.
    private static let ontRows = [
        ["Sample", "MHC-A H1", "MHC-A H2", "MHC-B H1", "MHC-B H2"],
        ["S1", "M6A", "M3A", "M1B", "M7B"],
        ["S2", "M8A", "M8A", "M3B", "M5B"],
    ]

    // MARK: - Haplotyped MiSeq, identity-bound precedence

    /// An override stamped with the active analysis identity applies, one with
    /// no identity applies, one stamped for another analysis revision is stale
    /// and stays at the pipeline value, an explicit absent second haplotype is
    /// written as "-", and a manual assignment is ignored.
    func testTypedMiSeqDelimitedExportAppliesIdentityBoundOverridesLikeTheWorkbook() async throws {
        try await assertDelimitedExports(
            shape: .typedMiSeqHaplotyped,
            scenario: Fixtures.miSeqScenario(),
            rows: Self.miSeqRows,
            prefix: "genotype-delimited-miseq-typed"
        )
    }

    /// The legacy MiSeq shape, an `ont-barcode-genotype` manifest without
    /// workflow declarations whose analysis assay is the MiSeq exon 2 assay,
    /// takes the same identity-bound precedence as the typed manifest.
    func testLegacyMiSeqShapeDelimitedExportAppliesIdentityBoundOverridesLikeTheWorkbook() async throws {
        try await assertDelimitedExports(
            shape: .legacyBarcode,
            scenario: Fixtures.miSeqScenario(),
            rows: Self.miSeqRows,
            prefix: "genotype-delimited-miseq-legacy"
        )
    }

    // MARK: - ONT, legacy precedence

    /// The first stored override for a slot applies whatever identity it
    /// carries, and a manual assignment fills a slot no override names. A
    /// manual first haplotype on a one-haplotype call is repeated in H2, the
    /// homozygous convention every export follows.
    func testLegacyONTDelimitedExportAppliesOverridesAndManualAssignmentsLikeTheWorkbook() async throws {
        try await assertDelimitedExports(
            shape: .legacyBarcode,
            scenario: Fixtures.ontScenario(),
            rows: Self.ontRows,
            prefix: "genotype-delimited-ont-legacy"
        )
    }

    /// A typed full-length ONT manifest resolves under the same legacy
    /// precedence as the barcode shape.
    func testFullLengthONTDelimitedExportAppliesOverridesAndManualAssignmentsLikeTheWorkbook() async throws {
        try await assertDelimitedExports(
            shape: .typedFullLengthONTHaplotyped,
            scenario: Fixtures.ontScenario(),
            rows: Self.ontRows,
            prefix: "genotype-delimited-ont-full-length"
        )
    }

    // MARK: - Genotype only

    /// A genotype-only result has no haplotype calls to resolve. Its table
    /// keeps allele names in H1 with H2 empty, as the user manual documents.
    func testGenotypeOnlyDelimitedExportKeepsAlleleNames() async throws {
        let root = try TestTempDirectory.make(prefix: "genotype-delimited-alleles")
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Fixtures.makeBundle(
            in: root,
            shape: .typedMiSeqGenotypeOnly,
            analysis: nil,
            sidecar: .empty(generatedAt: Fixtures.analysisTimestamp),
            genotypes: ["Mafa-G_02:31:01:01|OR823640", "Mafa-DPA1_02:04|OR823641"]
        )
        let csv = root.appendingPathComponent("alleles.csv")
        _ = try await GenotypeExportSubcommand.parse([
            "--bundle", bundle.path,
            "--export-format", "csv",
            "--output", csv.path,
        ]).runReturningResolvedColumns(managedPythonResolver: {
            XCTFail("CSV must not resolve the XLSX runtime")
            throw CocoaError(.fileNoSuchFile)
        })
        XCTAssertEqual(
            try String(contentsOf: csv, encoding: .utf8),
            """
            Sample,MHC-DPA1 H1,MHC-DPA1 H2,MHC-G H1,MHC-G H2
            S1,Mafa-DPA1_02:04|OR823641,,Mafa-G_02:31:01:01|OR823640,
            S2,Mafa-DPA1_02:04|OR823641,,Mafa-G_02:31:01:01|OR823640,

            """
        )
    }

    // MARK: - Assertions

    /// Every mismatch of one bundle, thrown from the test method itself so the
    /// verdict reaches XCTest even when an issue recorded inside the export
    /// task does not.
    private struct DelimitedExportMismatch: Error, CustomStringConvertible {
        let details: [String]
        var description: String { details.joined(separator: "\n\n") }
    }

    /// Exports the scenario's bundle as CSV and as TSV, compares each file
    /// with the expected rows, and compares the cells with the workbook's
    /// Haplotype Calls for the same bundle and sidecar.
    private func assertDelimitedExports(
        shape: Fixtures.ManifestShape,
        scenario: Fixtures.Scenario,
        rows expected: [[String]],
        prefix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = try TestTempDirectory.make(prefix: prefix)
        defer { TestTempDirectory.cleanup(root) }
        let bundle = try Fixtures.makeBundle(
            in: root,
            shape: shape,
            analysis: scenario.analysis,
            sidecar: scenario.sidecar
        )
        let workbook = Fixtures.effectivePairs(try Fixtures.workbookCalls(of: bundle))
        XCTAssertEqual(workbook, scenario.expectedCalls, file: file, line: line)
        var mismatches: [String] = []
        for (format, separator) in [("csv", ","), ("tsv", "\t")] {
            let output = root.appendingPathComponent("matrix.\(format)")
            _ = try await GenotypeExportSubcommand.parse([
                "--bundle", bundle.path,
                "--export-format", format,
                "--output", output.path,
            ]).runReturningResolvedColumns(managedPythonResolver: {
                XCTFail("\(format) must not resolve the XLSX runtime")
                throw CocoaError(.fileNoSuchFile)
            })
            let text = try String(contentsOf: output, encoding: .utf8)
            let expectedText = expected.map { $0.joined(separator: separator) }.joined(separator: "\n") + "\n"
            XCTAssertEqual(text, expectedText, "\(format) matrix", file: file, line: line)
            if text != expectedText {
                mismatches.append("\(format) matrix\n\(text)is not\n\(expectedText)")
            }
            let cells = try delimitedCalls(in: text, separator: Character(separator))
            XCTAssertEqual(
                cells,
                workbook,
                "\(format) calls differ from the workbook's Haplotype Calls",
                file: file,
                line: line
            )
            if cells != workbook {
                mismatches.append("\(format) calls \(cells) differ from the workbook's Haplotype Calls \(workbook)")
            }
        }
        if !mismatches.isEmpty {
            throw DelimitedExportMismatch(details: mismatches)
        }
    }

    /// The matrix cells keyed by sample then locus, as the H1 and H2 pair.
    private func delimitedCalls(in text: String, separator: Character) throws -> [String: [String: [String]]] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let header = try XCTUnwrap(lines.first)
            .split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(header.first, "Sample")
        let loci = stride(from: 1, to: header.count, by: 2).map { index in
            String(header[index].dropLast(" H1".count))
        }
        var calls: [String: [String: [String]]] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(fields.count, header.count, String(line))
            var byLocus: [String: [String]] = [:]
            for (index, locus) in loci.enumerated() {
                byLocus[locus] = [fields[1 + 2 * index], fields[2 + 2 * index]]
            }
            calls[fields[0]] = byLocus
        }
        return calls
    }
}
