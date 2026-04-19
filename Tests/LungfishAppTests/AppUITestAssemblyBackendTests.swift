import XCTest
@testable import LungfishApp
import LungfishWorkflow

final class AppUITestAssemblyBackendTests: XCTestCase {
    func testBackendSynthesizesMegahitAnalysisArtifacts() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assembly-ui-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: [
                URL(fileURLWithPath: "/tmp/R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/R2.fastq.gz"),
            ],
            projectName: "demo",
            outputDirectory: tempDir,
            pairedEnd: true,
            threads: 8
        )

        try AppUITestAssemblyBackend.writeResult(for: request)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("assembly-result.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("contigs.fasta").path
            )
        )
        XCTAssertEqual(try AssemblyResult.load(from: tempDir).tool, .megahit)
    }
}
