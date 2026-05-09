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
            .appendingPathComponent("docs/user-manual/fixtures/sarscov2-srr36291587")
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

        let chapter = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("docs/user-manual/chapters/04-variants/01-reads-to-variants.md"),
            encoding: .utf8
        )
        XCTAssertFalse(chapter.contains("default 0.03"))
        XCTAssertFalse(chapter.contains("default of 3%"))
        XCTAssertFalse(chapter.contains("position 23700"))
        XCTAssertFalse(chapter.contains("position 26060"))
        XCTAssertFalse(chapter.contains("FILTER `sb`"))
        XCTAssertTrue(chapter.contains("Include GFF3 Annotations"))
        XCTAssertTrue(chapter.contains("28881 GG>AA"))
    }
}
