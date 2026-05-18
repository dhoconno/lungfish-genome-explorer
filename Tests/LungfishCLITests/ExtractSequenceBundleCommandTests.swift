import Foundation
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI
import XCTest

final class ExtractSequenceBundleCommandTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-sequence-bundle-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExtractSequenceCanWriteReferenceBundleWithFinalPayloadProvenance() async throws {
        let inputURL = tempDir.appendingPathComponent("input.fasta")
        let outputURL = tempDir.appendingPathComponent("Extracted Sequence.lungfishref", isDirectory: true)
        let sequence = try Sequence(name: "chr1", alphabet: .dna, bases: "AACCGGTTAACCGGTT")
        try FASTAWriter(url: inputURL).write([sequence])

        let command = try ExtractSequenceSubcommand.parse([
            inputURL.path,
            "chr1:3-10",
            "--output", outputURL.path,
            "--line-width", "8",
            "--quiet",
        ])

        try await command.run()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.appendingPathComponent("genome/sequence.fa.gz").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.appendingPathComponent("genome/sequence.fa.gz.fai").path))

        let provenanceURL = outputURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let bundleRollupURL = outputURL.appendingPathComponent("provenance/bundle.lungfish-provenance.json")
        let genomeSidecarURL = outputURL.appendingPathComponent("provenance/genome/sequence.fa.gz.lungfish-provenance.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleRollupURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: genomeSidecarURL.path))

        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(envelope.workflowName, "lungfish extract sequence")
        XCTAssertEqual(envelope.toolName, "lungfish extract sequence")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertTrue(envelope.argv.contains(inputURL.path))
        XCTAssertTrue(envelope.argv.contains(outputURL.path))
        XCTAssertEqual(envelope.options.resolvedDefaults["coordinate_system"]?.stringValue, "0-based half-open")

        let finalGenomePath = outputURL.appendingPathComponent("genome/sequence.fa.gz").path
        let finalGenomeRecord = envelope.files.first { $0.path == finalGenomePath }
        XCTAssertEqual(finalGenomeRecord?.role, .output)
        XCTAssertNotNil(finalGenomeRecord?.checksumSHA256)
        XCTAssertNotNil(finalGenomeRecord?.fileSize)
        XCTAssertFalse(envelope.files.contains { $0.path.contains("/sequence.fa") && !$0.path.hasPrefix(outputURL.path) })
    }
}
