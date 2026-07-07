import XCTest
@testable import LungfishCLI

final class CLIClassificationFolderResolverTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIClassificationFolderResolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testDirectoryExpansionUsesTopLevelEligibleSequencesOnlyByDefault() throws {
        let first = try writeFASTQ("A.fastq")
        let second = try writeFASTA("B.fasta")
        _ = try writeText("notes.txt", "ignore me")
        let nestedDir = tempDir.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        _ = try writeFASTQ("Nested/C.fastq")

        let resolved = try CLIClassificationFolderResolver.expandInputArguments(
            [tempDir.path],
            recursive: false
        )

        XCTAssertEqual(resolved, [first.standardizedFileURL, second.standardizedFileURL])
    }

    func testDirectoryExpansionIncludesSubfoldersWhenRecursive() throws {
        let first = try writeFASTQ("A.fastq")
        let nested = try writeFASTQ("Nested/C.fastq")

        let resolved = try CLIClassificationFolderResolver.expandInputArguments(
            [tempDir.path],
            recursive: true
        )

        XCTAssertEqual(resolved, [first.standardizedFileURL, nested.standardizedFileURL])
    }

    func testClassifierCommandsExposeRecursiveDirectoryFlag() throws {
        let kraken = try ClassifyCommand.parse([
            tempDir.path,
            "--db", "FixtureDB",
            "--recursive",
        ])
        XCTAssertTrue(kraken.recursive)

        let esviritu = try EsVirituCommand.DetectSubcommand.parse([
            "detect",
            "--input", tempDir.path,
            "--sample", "S1",
            "--db", tempDir.path,
            "--recursive",
        ])
        XCTAssertTrue(esviritu.recursive)

        let taxtriage = try TaxTriageCommand.RunSubcommand.parse([
            "run",
            "--input", tempDir.path,
            "--output", tempDir.appendingPathComponent("out").path,
            "--recursive",
        ])
        XCTAssertTrue(taxtriage.recursive)
    }

    private func writeFASTQ(_ relativePath: String) throws -> URL {
        try writeText(relativePath, "@r\nACGT\n+\nIIII\n")
    }

    private func writeFASTA(_ relativePath: String) throws -> URL {
        try writeText(relativePath, ">r\nACGT\n")
    }

    @discardableResult
    private func writeText(_ relativePath: String, _ contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
