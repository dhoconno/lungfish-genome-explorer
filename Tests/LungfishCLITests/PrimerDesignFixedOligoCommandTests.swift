import XCTest
import ArgumentParser
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

/// CLI cover for the fixed-oligo flags, the probe Tm offset, and the explain
/// summary, plus the CLI half of GUI/CLI parity.
final class PrimerDesignFixedOligoCommandTests: XCTestCase {
    private let base = ["--fasta-record", "/tmp/mhc.fasta@0",
                        "--output", "/tmp/result.lungfishprimeranalysis"]

    private func options(_ extra: [String]) throws -> Primer3DesignOptions {
        try PrimerDesignCommand.Primer3Subcommand.parse(base + extra).makeOptions()
    }

    // MARK: - Fixed oligos

    func testNoFixedOligoFlagsSendNoFixedOligos() throws {
        XCTAssertTrue(try options(["--assay", "qpcr-probe"]).fixedOligos.isEmpty)
    }

    func testEachFixedOligoFlagIsCarriedThrough() throws {
        let fixed = try options([
            "--assay", "qpcr-probe",
            "--left-primer", "acgtacgtacgt",
            "--right-primer", "TTGGCCAATTGG",
            "--probe", "ACGTTTGGCCAA",
            "--force-left-end", "120",
            "--force-right-end", "260",
        ]).fixedOligos

        XCTAssertEqual(fixed.leftPrimer, "ACGTACGTACGT")
        XCTAssertEqual(fixed.rightPrimer, "TTGGCCAATTGG")
        XCTAssertEqual(fixed.probe, "ACGTTTGGCCAA")
        XCTAssertEqual(fixed.forceLeftEnd, 120)
        XCTAssertEqual(fixed.forceRightEnd, 260)
    }

    func testAnEmptyFlagValueIsTreatedAsAbsent() throws {
        XCTAssertNil(try options(["--left-primer", ""]).fixedOligos.leftPrimer)
    }

    func testFixedOligosApplyToPlainPCRToo() throws {
        // Anchoring a 3' end is useful without a probe, so the flags are not
        // restricted to the probe assay.
        let fixed = try options(["--assay", "pcr", "--force-left-end", "42"]).fixedOligos
        XCTAssertEqual(fixed.forceLeftEnd, 42)
    }

    // MARK: - Probe Tm offset

    func testTheDefaultOffsetRaisesTheProbeMinimumAboveThePrimers() throws {
        let resolved = try options(["--assay", "qpcr-probe"])
        XCTAssertEqual(
            resolved.probeMinTmOffsetOverPrimers,
            Primer3DesignOptions.defaultProbeMinTmOffsetOverPrimers)
        XCTAssertEqual(resolved.effectiveProbe?.probeMinTm, 67)
        XCTAssertGreaterThanOrEqual(
            (resolved.effectiveProbe?.probeMinTm ?? 0) - resolved.primerMaxTm, 5)
    }

    func testAnExplicitZeroOffsetKeepsTheConfiguredWindow() throws {
        let resolved = try options([
            "--assay", "qpcr-probe", "--probe-min-tm-offset-over-primers", "0",
        ])
        XCTAssertNil(resolved.probeMinTmOffsetOverPrimers)
        XCTAssertEqual(resolved.effectiveProbe?.probeMinTm, 64)
    }

    func testAnExplicitOffsetIsHonoured() throws {
        let resolved = try options([
            "--assay", "qpcr-probe", "--probe-min-tm-offset-over-primers", "8",
        ])
        XCTAssertEqual(resolved.effectiveProbe?.probeMinTm, 70)
    }

    func testTheOffsetLeavesPCRAndDyeWithoutAProbe() throws {
        for assay in ["pcr", "qpcr-dye"] {
            let resolved = try options(["--assay", assay])
            XCTAssertNil(resolved.probe, assay)
            XCTAssertNil(resolved.effectiveProbe, assay)
        }
    }

    func testProbePresetCapsRunsAtThreeBases() throws {
        XCTAssertEqual(try options(["--assay", "qpcr-probe"]).probe?.probeMaxPolyX, 3)
    }

    // MARK: - GUI and CLI parity

    /// The GUI half of this equality is asserted in the app test target. Both
    /// sides compare against the same shared preset, so together they pin the
    /// two surfaces to identical Primer3 input.
    func testCLIOptionsEqualTheSharedPresetForTheSameChoices() throws {
        let resolved = try options([
            "--assay", "qpcr-probe",
            "--left-primer", "ACGTACGTACGT",
            "--force-right-end", "300",
            "--probe-min-tm-offset-over-primers", "6",
        ])
        XCTAssertEqual(resolved, Primer3DesignOptions.preset(
            .qpcrProbe,
            fixedOligos: .init(leftPrimer: "ACGTACGTACGT", forceRightEnd: 300),
            probeMinTmOffsetOverPrimers: 6))
    }

    // MARK: - Explain summary

    func testSummaryReportsPairCountsAndEveryExplainLine() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("primer3-summary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("results"), withIntermediateDirectories: true)

        let results = Primer3NormalizedResults(
            analysisID: UUID(), runID: UUID(),
            results: [Primer3TemplateResult(
                resultID: UUID(), inputID: UUID(), title: "lineage", sourceKind: "msa",
                sourceIndex: 0, sourceRecordID: "lineage", templateSequence: "ACGT",
                alignmentToTemplate: nil, excludedRegions: [], pairs: [],
                error: nil, explanation: "considered 0, ok 0",
                explanations: .init(
                    left: "considered 10, high tm 7, ok 3",
                    right: "considered 10, ok 10",
                    internalOligo: "considered 1, low tm 1, ok 0",
                    pair: "considered 0, ok 0"))])
        try JSONEncoder().encode(results).write(
            to: directory.appendingPathComponent("results/primer3-normalized-v1.json"))

        let lines = PrimerDesignCommand.Primer3Subcommand.summaryLines(forAnalysisAt: directory)
        XCTAssertEqual(lines.first, "lineage: 0 candidate pair(s)")
        // The probe line is the one that explains this zero-pair run; the pair
        // line alone would say only "considered 0".
        XCTAssertTrue(lines.contains("  Probe: considered 1, low tm 1, ok 0"))
        XCTAssertTrue(lines.contains("  Left primer: considered 10, high tm 7, ok 3"))
        XCTAssertTrue(lines.contains("  Pair: considered 0, ok 0"))
    }

    func testSummaryFallsBackToThePairLineForOlderAnalyses() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("primer3-summary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("results"), withIntermediateDirectories: true)
        let json = """
        {"schemaVersion":1,"analysisID":"\(UUID().uuidString)","runID":"\(UUID().uuidString)",
         "results":[{"resultID":"\(UUID().uuidString)","inputID":"\(UUID().uuidString)",
         "title":"old","sourceKind":"fasta","sourceIndex":0,"sourceRecordID":"old",
         "templateSequence":"ACGT","excludedRegions":[],"pairs":[],
         "explanation":"considered 4, ok 0"}]}
        """
        try Data(json.utf8).write(
            to: directory.appendingPathComponent("results/primer3-normalized-v1.json"))

        let lines = PrimerDesignCommand.Primer3Subcommand.summaryLines(forAnalysisAt: directory)
        XCTAssertTrue(lines.contains("  Pair: considered 4, ok 0"))
    }

    func testSummaryIsEmptyWhenNoNormalizedResultsExist() {
        XCTAssertTrue(PrimerDesignCommand.Primer3Subcommand.summaryLines(
            forAnalysisAt: URL(fileURLWithPath: "/nonexistent-analysis")).isEmpty)
    }
}
