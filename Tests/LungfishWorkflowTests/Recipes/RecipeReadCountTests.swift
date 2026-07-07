import XCTest
@testable import LungfishWorkflow

final class RecipeReadCountTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecipeReadCountTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func writeFASTQ(_ name: String, readCount: Int) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        var text = ""
        for i in 0..<readCount {
            text += "@read\(i)\nACGT\n+\nIIII\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testPairedRecipeOutputCountsPrimaryMateAsReadPairCount() async throws {
        let r1 = try writeFASTQ("sample_R1.fastq", readCount: 3)
        let r2 = try writeFASTQ("sample_R2.fastq", readCount: 3)
        let output = StepOutput(r1: r1, r2: r2, format: .pairedR1R2)

        let count = try await RecipeEngine.countReadsForRecipeStep(output)

        XCTAssertEqual(count, 3)
    }

    func testMergedRecipeOutputCountsAllOutputStreams() async throws {
        let merged = try writeFASTQ("merged.fastq", readCount: 2)
        let unmergedR1 = try writeFASTQ("unmerged_R1.fastq", readCount: 3)
        let unmergedR2 = try writeFASTQ("unmerged_R2.fastq", readCount: 3)
        let output = StepOutput(r1: merged, r2: unmergedR1, r3: unmergedR2, format: .merged)

        let count = try await RecipeEngine.countReadsForRecipeStep(output)

        XCTAssertEqual(count, 8)
    }
}
