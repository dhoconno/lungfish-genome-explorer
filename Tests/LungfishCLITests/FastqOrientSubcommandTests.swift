import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

final class FastqOrientSubcommandTests: XCTestCase {
    func testOrientationChoosesOutputFormatFromInputIncludingCompressedExtensions() throws {
        for (name, flag, format) in [("reads.fasta", "--fastaout", SequenceFormat.fasta),
                                     ("reads.fa.gz", "--fastaout", .fasta),
                                     ("reads.fastq", "--fastqout", .fastq),
                                     ("reads.fq.gz", "--fastqout", .fastq)] {
            let inputURL = URL(fileURLWithPath: "/tmp/\(name)")
            let referenceURL = URL(fileURLWithPath: "/tmp/reference.fasta")
            // A caller-selected filename cannot create qualities for FASTA input.
            let command = try FastqOrientSubcommand.parse([
                inputURL.path, "--reference", referenceURL.path, "--output", "/tmp/oriented.data",
                "--word-length", "10", "--db-mask", "none", "--extra-args", "--notrunclabels"
            ])
            let plan = try command.resolveOrientationCommand(inputURL: inputURL, referenceURL: referenceURL,
                tabbedOutputURL: URL(fileURLWithPath: "/tmp/orientation.tsv"))
            XCTAssertEqual(plan.sequenceFormat, format)
            XCTAssertEqual(plan.arguments, [
                "--orient", inputURL.path, "--db", referenceURL.path, flag, "/tmp/oriented.data",
                "--tabbedout", "/tmp/orientation.tsv", "--wordlength", "10", "--dbmask", "none",
                "--qmask", "none", "--threads", "0", "--notrunclabels"
            ])
        }
    }

    func testUnknownSequenceFormatIsRejectedBeforeToolLaunch() throws {
        let inputURL = URL(fileURLWithPath: "/tmp/reads.txt")
        let referenceURL = URL(fileURLWithPath: "/tmp/reference.fasta")
        let command = try FastqOrientSubcommand.parse([
            inputURL.path, "--reference", referenceURL.path, "--output", "/tmp/oriented.fasta"
        ])
        XCTAssertThrowsError(try command.resolveOrientationCommand(inputURL: inputURL, referenceURL: referenceURL,
            tabbedOutputURL: URL(fileURLWithPath: "/tmp/orientation.tsv")))
    }

    func testNativeOrientationPreservesPayloadFormatAndProvenance() async throws {
        do { _ = try await NativeToolRunner.shared.findTool(.vsearch) }
        catch { throw XCTSkip("Native vsearch is unavailable: \(error)") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orient-formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sequence = "ACGTTGCAAGTCGATGCTAGCTACGATCGTACCTGATCGTAGCTTACGGTCACTGATAGCGTAC"
        let referenceURL = directory.appendingPathComponent("reference.fasta")
        try ">reference\n\(sequence)\n".write(to: referenceURL, atomically: true, encoding: .utf8)
        for format in [SequenceFormat.fasta, .fastq] {
            let inputURL = directory.appendingPathComponent("input.\(format.fileExtension)")
            let outputURL = directory.appendingPathComponent("oriented.\(format.fileExtension)")
            let input = format == .fasta ? ">read\n\(sequence)\n"
                : "@read\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
            try input.write(to: inputURL, atomically: true, encoding: .utf8)
            let command = try FastqOrientSubcommand.parse([
                inputURL.path, "--reference", referenceURL.path, "--output", outputURL.path, "--db-mask", "none"
            ])
            try await command.run()
            let payload = try String(contentsOf: outputURL, encoding: .utf8)
            XCTAssertTrue(payload.hasPrefix(format == .fasta ? ">read" : "@read"))
            XCTAssertTrue(payload.contains(sequence))
            let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(
                fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
            let expectedFormat: FileFormat = format == .fasta ? .fasta : .fastq
            XCTAssertTrue(envelope.files.contains { $0.path == inputURL.path && $0.format == expectedFormat && $0.checksumSHA256 != nil })
            XCTAssertTrue(envelope.outputs.contains { $0.path == outputURL.path && $0.format == expectedFormat && $0.checksumSHA256 != nil })
            XCTAssertEqual(envelope.options.resolvedDefaults["inputFormat"], .string(format.rawValue))
            XCTAssertEqual(envelope.options.resolvedDefaults["outputFormat"], .string(format.rawValue))
        }
    }
}
