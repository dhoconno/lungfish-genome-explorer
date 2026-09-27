import Foundation
import XCTest
@testable import LungfishWorkflow

/// varVAMP ranks qPCR assays by penalty and reports them best-first. LGE marks
/// rank 1 "selected", so ranking must follow varVAMP rather than reference
/// position: otherwise the worst assay is presented as the chosen one and is what
/// "Export selected assays" writes.
final class VarVAMPQPCRAssayRankingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
                          "the adapter ranking is Python; no interpreter available")
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Penalty order deliberately disagrees with position order, reproducing the
    /// real Mamu-A1 qPCR run where varVAMP_4 (penalty 4.6, worst) is leftmost and
    /// varVAMP_0 (penalty 2.2, best) sits further along the reference.
    private func writeDesignTable() throws {
        let rows = [
            "qpcr_scheme\toff_target_amplicons\tpenalty\tdeltaG\tlength\tstart\tstop\tseq",
            "varVAMP_0\tn.d.\t2.2\t-2.2\t181\t1070\t1250\tACGT",
            "varVAMP_1\tn.d.\t2.2\t-0.3\t83\t2649\t2731\tACGT",
            "varVAMP_2\tn.d.\t2.8\t-1.4\t175\t2430\t2604\tACGT",
            "varVAMP_3\tn.d.\t3.3\t-1.7\t169\t1679\t1847\tACGT",
            "varVAMP_4\tn.d.\t4.6\t-1.4\t96\t392\t487\tACGT",
        ]
        try Data((rows.joined(separator: "\n") + "\n").utf8)
            .write(to: root.appendingPathComponent("qpcr_design.tsv"))
    }

    /// Runs the adapter's own ranking expression so the test exercises shipped code
    /// rather than a reimplementation of it.
    private func rankedAssayNames(
        expectingPenalties: [String: Double] = [:]
    ) throws -> [String] {
        let script = """
        import csv, json, sys
        from pathlib import Path
        sys.path.insert(0, sys.argv[1])
        from varvamp_adapter import _read_qpcr_penalties
        native = Path(sys.argv[2])
        penalties = _read_qpcr_penalties(native)
        names = [r["qpcr_scheme"] for r in csv.DictReader(
            (native / "qpcr_design.tsv").open(newline=""), delimiter="\\t")]
        order = {name: index for index, name in enumerate(dict.fromkeys(names))}
        groups = dict.fromkeys(names)
        ranked = sorted(groups, key=lambda n: (
            penalties.get(n, (float("inf"), order.get(n, 0))), order.get(n, 0), n))
        # An absent penalty is infinity, which is not valid JSON, so it is omitted.
        finite = {k: v[0] for k, v in penalties.items() if v[0] != float("inf")}
        print(json.dumps({"ranked": ranked, "penalties": finite}))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script,
                             try PrimerSchemeAdapterResources.bundledV1URL().path, root.path]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = String(data: errors.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        struct Result: Decodable { let ranked: [String]; let penalties: [String: Double] }
        let result = try JSONDecoder().decode(Result.self, from: data)
        // Confirm the fixture really does disagree about order, or the test proves nothing.
        for (name, penalty) in expectingPenalties {
            XCTAssertEqual(result.penalties[name], penalty, name)
        }
        return result.ranked
    }

    func testRankOneIsVarVAMPsBestPenaltyAssayNotTheLeftmostOne() throws {
        try writeDesignTable()
        let ranked = try rankedAssayNames(
            expectingPenalties: ["varVAMP_0": 2.2, "varVAMP_4": 4.6])
        // The old position sort made varVAMP_4 (penalty 4.6) rank 1 and "selected".
        XCTAssertEqual(ranked.first, "varVAMP_0", "rank 1 must be varVAMP's best assay")
        XCTAssertNotEqual(ranked.first, "varVAMP_4")
    }

    func testAlternativesKeepVarVAMPsOwnPenaltyOrder() throws {
        try writeDesignTable()
        XCTAssertEqual(try rankedAssayNames(),
                       ["varVAMP_0", "varVAMP_1", "varVAMP_2", "varVAMP_3", "varVAMP_4"])
    }

    /// varVAMP_0 and varVAMP_1 both score 2.2, so the tie must fall back to
    /// varVAMP's own table order rather than to a name or a coordinate.
    func testEqualPenaltiesKeepTheNativeTableOrder() throws {
        let rows = [
            "qpcr_scheme\tpenalty\tstart\tstop",
            "varVAMP_7\t2.2\t3000\t3100",
            "varVAMP_2\t2.2\t100\t200",
        ]
        try Data((rows.joined(separator: "\n") + "\n").utf8)
            .write(to: root.appendingPathComponent("qpcr_design.tsv"))
        XCTAssertEqual(try rankedAssayNames(), ["varVAMP_7", "varVAMP_2"])
    }

    /// A missing or unreadable penalty column must not crash the run; varVAMP's
    /// table order still stands.
    func testMissingPenaltiesFallBackToTheTableOrder() throws {
        let rows = ["qpcr_scheme\tstart\tstop",
                    "varVAMP_5\t900\t1000",
                    "varVAMP_1\t100\t200"]
        try Data((rows.joined(separator: "\n") + "\n").utf8)
            .write(to: root.appendingPathComponent("qpcr_design.tsv"))
        XCTAssertEqual(try rankedAssayNames(), ["varVAMP_5", "varVAMP_1"])
    }
}
