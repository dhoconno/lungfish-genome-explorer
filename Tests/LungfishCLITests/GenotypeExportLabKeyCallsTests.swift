import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport
import XCTest
@testable import LungfishCLI

/// Finding SF2 of the Phase 2.3 design review, the LabKey half. The
/// `called_haplotype` of every `haplotype_calls.csv` row that `genotype
/// export-labkey` writes must equal the workbook's Effective H1 or H2 for
/// the same bundle and sidecar, which is also what the CSV and TSV matrix
/// reports. `is_override` says whether the analyst chose that value, and
/// the status column keeps the pipeline's status.
final class GenotypeExportLabKeyCallsTests: XCTestCase {
    private typealias Fixtures = GenotypeExportCallFixtures

    private static let haplotypeCallsHeader =
        "animal_id,gs_id,locus,slot,called_haplotype,status,reads_supporting,is_override,notes"

    // MARK: - Haplotyped MiSeq, identity-bound precedence

    func testTypedMiSeqLabKeyExportAppliesIdentityBoundOverridesLikeTheWorkbook() async throws {
        try await assertLabKeyCalls(
            shape: .typedMiSeqHaplotyped,
            scenario: Fixtures.miSeqScenario(),
            prefix: "labkey-calls-miseq-typed"
        )
    }

    func testLegacyMiSeqShapeLabKeyExportAppliesIdentityBoundOverridesLikeTheWorkbook() async throws {
        try await assertLabKeyCalls(
            shape: .legacyBarcode,
            scenario: Fixtures.miSeqScenario(),
            prefix: "labkey-calls-miseq-legacy"
        )
    }

    // MARK: - ONT, legacy precedence

    func testLegacyONTLabKeyExportAppliesOverridesAndManualAssignmentsLikeTheWorkbook() async throws {
        try await assertLabKeyCalls(
            shape: .legacyBarcode,
            scenario: Fixtures.ontScenario(),
            prefix: "labkey-calls-ont-legacy"
        )
    }

    func testFullLengthONTLabKeyExportAppliesOverridesAndManualAssignmentsLikeTheWorkbook() async throws {
        try await assertLabKeyCalls(
            shape: .typedFullLengthONTHaplotyped,
            scenario: Fixtures.ontScenario(),
            prefix: "labkey-calls-ont-full-length"
        )
    }

    // MARK: - Genotype only

    /// The user manual says a genotype-only result writes `haplotype_calls.csv`
    /// with only its header. That stays so even when the sidecar holds a
    /// manual assignment, which the workbook's Haplotype Calls sheet does
    /// list. The difference is reported with finding SF2 and left to the
    /// owner.
    func testGenotypeOnlyLabKeyExportKeepsHeaderOnlyHaplotypeCalls() async throws {
        let root = try TestTempDirectory.make(prefix: "labkey-calls-genotype-only")
        defer { TestTempDirectory.cleanup(root) }
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: Fixtures.analysisTimestamp)
        sidecar.manualHaplotypeAssignments = [
            .init(sample: "S1", locus: "MHC-A", slot: .h1, label: "M1A",
                  colorTokenIndex: 1, diagnosticAlleles: [], notes: ""),
        ]
        let bundle = try Fixtures.makeBundle(
            in: root,
            shape: .typedMiSeqGenotypeOnly,
            analysis: nil,
            sidecar: sidecar
        )
        let outputDir = root.appendingPathComponent("labkey", isDirectory: true)
        try await GenotypeExportLabKeySubcommand.parse([
            "--bundle", bundle.path,
            "--output-dir", outputDir.path,
        ]).run()

        XCTAssertEqual(
            try String(contentsOf: outputDir.appendingPathComponent("haplotype_calls.csv"), encoding: .utf8),
            Self.haplotypeCallsHeader + "\n"
        )
        XCTAssertFalse(
            try Fixtures.workbookCalls(of: bundle).isEmpty,
            "the workbook lists the manual assignment, the LabKey file keeps its documented header-only shape"
        )
    }

    // MARK: - Assertion

    /// Every mismatch of one bundle, thrown from the test method itself so the
    /// verdict reaches XCTest even when an issue recorded inside the export
    /// task does not.
    private struct LabKeyCallMismatch: Error, CustomStringConvertible {
        let details: [String]
        var description: String { details.joined(separator: "\n") }
    }

    /// Runs `export-labkey` on the scenario under the given manifest shape and
    /// compares every `haplotype_calls.csv` row with the workbook's Haplotype
    /// Calls for the same bundle, slot by slot.
    private func assertLabKeyCalls(
        shape: Fixtures.ManifestShape,
        scenario: Fixtures.Scenario,
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
        let outputDir = root.appendingPathComponent("labkey", isDirectory: true)
        try await GenotypeExportLabKeySubcommand.parse([
            "--bundle", bundle.path,
            "--output-dir", outputDir.path,
        ]).run()

        let workbook = try Fixtures.workbookCalls(of: bundle)
        XCTAssertEqual(Fixtures.effectivePairs(workbook), scenario.expectedCalls, file: file, line: line)
        let rows = try haplotypeRows(in: outputDir)
        XCTAssertEqual(rows.count, workbook.count * 2, "two rows per workbook call", file: file, line: line)

        var mismatches: [String] = []
        var pairs: [String: [String: [String]]] = [:]
        for call in workbook {
            for (slot, value) in [("h1", call.h1), ("h2", call.h2)] {
                guard let row = rows.first(where: { $0[0] == call.sampleID && $0[2] == call.locus && $0[3] == slot }) else {
                    mismatches.append("no row for \(call.sampleID) \(call.locus) \(slot)")
                    continue
                }
                let expectedOverride = value.source == "analystOverride" ? "true" : "false"
                XCTAssertEqual(row[1], call.sampleID, "gs_id", file: file, line: line)
                XCTAssertEqual(row[4], value.effective, "\(call.sampleID) \(call.locus) \(slot) called_haplotype", file: file, line: line)
                XCTAssertEqual(row[5], "called", "the status column keeps the pipeline's status", file: file, line: line)
                XCTAssertNotNil(Int(row[6]), "reads_supporting is a count", file: file, line: line)
                XCTAssertEqual(row[7], expectedOverride, "\(call.sampleID) \(call.locus) \(slot) is_override", file: file, line: line)
                XCTAssertEqual(row[8], "", "notes", file: file, line: line)
                if row[4] != value.effective || row[7] != expectedOverride {
                    mismatches.append("\(call.sampleID) \(call.locus) \(slot) is \(row[4]) override \(row[7]), the workbook has \(value.effective) source \(value.source)")
                }
                pairs[call.sampleID, default: [:]][call.locus, default: ["", ""]][slot == "h1" ? 0 : 1] = row[4]
            }
        }
        XCTAssertEqual(pairs, scenario.expectedCalls, file: file, line: line)
        if !mismatches.isEmpty {
            throw LabKeyCallMismatch(details: mismatches)
        }
    }

    /// The data rows of `haplotype_calls.csv` after its header, which must be
    /// the LabKey ingestion header exactly. No fixture value needs quoting.
    private func haplotypeRows(in outputDir: URL) throws -> [[String]] {
        let text = try String(contentsOf: outputDir.appendingPathComponent("haplotype_calls.csv"), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.first, Self.haplotypeCallsHeader)
        return lines.dropFirst().map { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(fields.count, 9, line)
            return fields
        }
    }
}
