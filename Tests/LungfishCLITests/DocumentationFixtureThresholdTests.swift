import XCTest

final class DocumentationFixtureThresholdTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testReadsToVariantsFixtureMatchesGUIIVarMinimumAFDefault() throws {
        let fixtureDirectory = repositoryRoot
            .appendingPathComponent("Tests/Fixtures/sarscov2-srr36291587")
        let regenerateScript = try String(
            contentsOf: fixtureDirectory.appendingPathComponent("regenerate.sh"),
            encoding: .utf8
        )
        let ivarCommandLine = try XCTUnwrap(
            regenerateScript
                .split(separator: "\n")
                .map(String.init)
                .first { $0.contains("--caller ivar") }
        )
        XCTAssertTrue(ivarCommandLine.contains("--min-af 0.05"))

        let vcf = try String(
            contentsOf: fixtureDirectory.appendingPathComponent("ivar.expected.vcf"),
            encoding: .utf8
        )
        let lowAFRows = vcf.split(separator: "\n").compactMap { line -> String? in
            guard !line.hasPrefix("#") else { return nil }
            let columns = line.split(separator: "\t")
            guard columns.count >= 10 else { return nil }
            let keys = columns[8].split(separator: ":").map(String.init)
            let values = columns[9].split(separator: ":").map(String.init)
            guard let index = keys.firstIndex(of: "ALT_FREQ"),
                  index < values.count,
                  let altFrequency = Double(values[index]),
                  altFrequency < 0.05 else {
                return nil
            }
            return "\(columns[1]) ALT_FREQ=\(values[index])"
        }
        XCTAssertTrue(lowAFRows.isEmpty, "Rows below GUI default minimum AF remain: \(lowAFRows)")
        XCTAssertFalse(vcf.contains("GFF unavailable"))
        XCTAssertTrue(vcf.contains("\t28881\t.\tGG\tAA\t"))
        XCTAssertTrue(vcf.contains("ALT_FREQ:MERGED_AF:MERGED_DP"))
        XCTAssertFalse(vcf.contains("\t28882\t.\tG\tA\t"))
        XCTAssertTrue(vcf.contains("\t28883\t.\tG\tC\t"))

        // "Rewrite Calling Variants for the 2026-09 fidelity campaign" (cb5505d11)
        // replaced this chapter's SARS-CoV-2/iVar worked example with an HG002
        // bcftools+LoFreq one; the amplicon-specific wording and coordinates this
        // test previously pinned no longer exist anywhere in the manual. The facts
        // that used to be asserted via that wording are still true, just phrased
        // differently, so assert those instead of the retired strings (TST-01 group 3).
        let chapter = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("docs/user-manual/chapters/05-variants/01-calling-variants-from-amplicons.md"),
            encoding: .utf8
        )
        XCTAssertFalse(chapter.contains("default 0.03"))
        XCTAssertFalse(chapter.contains("default of 3%"))
        XCTAssertTrue(chapter.contains("The default is 0.05, and it becomes iVar's own `-t` value"))
        XCTAssertTrue(chapter.contains("--min-af 0.05"))
        XCTAssertTrue(chapter.contains("Minimum Allele Frequency"))
    }
}
