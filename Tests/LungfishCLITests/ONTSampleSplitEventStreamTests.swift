// ONTSampleSplitEventStreamTests.swift - The progress lines and the outputs of the two ONT sample split commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// Plan decisions S8 and S9. `fastq ont-fluidigm-samples` and `fastq ont-pacbio-barcode-demux`
/// print progress on standard error, and the FASTQ operation family reads it from there. Each
/// test runs a command in process on a small fixture with both standard streams redirected to
/// files for the length of the run, so the channel is part of what is pinned.
///
/// The progress lines are one pin and the outputs are another. The outputs digest names each
/// file under the output folder, with a payload gunzipped, the scratch folder rewritten to
/// `/work` and the values that change from run to run removed. A record sidecar holds times and
/// ids, so only its name counts. The digest stays the same through the move to `CLIEvent`
/// lines, which is how the lane shows that the demultiplexed reads and the manifests are the
/// same bytes. The two commands print one result document on standard output as well.
final class ONTSampleSplitEventStreamTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-sample-split-events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// The default Fluidigm CS1 primer, a short insert, the reverse complement of the default
    /// CS2 primer and a barcode that the sample sheet names, twice.
    private func fluidigmRun() async throws -> (streams: Streams, output: URL) {
        let read = ONTFluidigmAmpliconMaterializer.defaultForwardPrimer + "ACGTACGTACGTACGT"
            + Self.reverseComplement(ONTFluidigmAmpliconMaterializer.defaultReversePrimer) + "CC" + "AAAACCCCGG"
        let input = try writeFASTQ("fluidigm-reads.fastq", reads: [read, read])
        let barcodes = root.appendingPathComponent("samples.csv")
        try "sample,barcode\nLF2871,AAAACCCCGG\n".write(to: barcodes, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("fluidigm", isDirectory: true)
        let command = try FastqONTFluidigmSamplesSubcommand.parse([
            input.path, "--barcodes", barcodes.path, "--output", output.path,
            "--primer-mismatches", "0", "--minimum-insert-length", "8", "--force",
        ])
        let streams = try await capturingStandardStreams { try await command.run() }
        return (streams, output)
    }

    /// A read that carries one PacBio barcode pair around a long insert, twice.
    private func pacBioRun() async throws -> (streams: Streams, output: URL) {
        let read = String(repeating: "T", count: 60) + "CACATATCAGAGTGCG" + String(repeating: "ACGT", count: 510)
            + Self.reverseComplement("CTATACATAGTGATGT") + String(repeating: "A", count: 60)
        let input = try writeFASTQ("pacbio-reads.fastq", reads: [read, read])
        let barcodes = root.appendingPathComponent("plate.barcodes.csv")
        try "32286-001_DL46,BC1001,BC1021\n".write(to: barcodes, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("pacbio", isDirectory: true)
        let command = try FastqONTPacBioBarcodeDemuxSubcommand.parse([
            input.path, "--barcodes", barcodes.path, "--output", output.path,
            "--chunk-jobs", "1", "--max-reads-per-slice", "0", "--force",
        ])
        let streams = try await capturingStandardStreams { try await command.run() }
        return (streams, output)
    }

    // MARK: The progress lines

    func testFluidigmSamplesPrintsItsProgressOnStandardError() async throws {
        let run = try await fluidigmRun()

        let lines = try Self.progressLines(run.streams.standardError)
        XCTAssertEqual(lines.map(\.message), [
            "Preparing ONT Fluidigm sample split.",
            "Found 1 ONT FASTQ chunk.",
            "Scanning chunk 1/1: fluidigm-reads.fastq",
            "Scanned chunk 1/1: 2 reads.",
            "Writing 1 sample bundle.",
            "Writing ONT Fluidigm sample manifest.",
            "ONT Fluidigm sample split complete.",
        ])
        assertProgress(lines.map(\.progress), [0.02, 0.08, 0.1, 0.8, 0.84, 0.92, 1.0])
        XCTAssertEqual(Set(lines.flatMap(\.keys)), ["event", "message", "operation", "progress"])
        XCTAssertEqual(Set(lines.map(\.operation)), ["ontFluidigmSamples"])
        XCTAssertFalse(run.streams.standardOutput.contains(#""event""#), "Standard output holds the result document, never a progress line")
    }

    func testPacBioBarcodeDemuxPrintsItsProgressOnStandardError() async throws {
        let run = try await pacBioRun()

        let lines = try Self.progressLines(run.streams.standardError)
        XCTAssertEqual(lines.map(\.message), [
            "Running exact PacBio barcode demultiplexing on 1 ONT FASTQ chunk(s)",
            "Starting exact barcode demultiplexing...",
            "Building results...",
            "Demultiplexing complete.",
            "Materializing exact PacBio sample FASTQ bundles...",
            "Finalizing exact PacBio sample FASTQ bundles...",
            "PacBio barcode demultiplexing complete",
        ])
        assertProgress(lines.map(\.progress), [0.02, 0.02, 0.666, 0.7, 0.72, 0.92, 1.0])
        XCTAssertEqual(Set(lines.flatMap(\.keys)), ["event", "message", "operation", "progress"])
        XCTAssertEqual(Set(lines.map(\.operation)), ["ontPacBioBarcodeDemux"])
        XCTAssertFalse(run.streams.standardOutput.contains(#""event""#), "Standard output holds the result document, never a progress line")
    }

    /// The FASTQ operation family decodes standard error with `CLIEventLineDecoder`. The
    /// private shape reads as `progress` events by accident, and this fixes what the dialog
    /// is shown, whatever the shape of the lines.
    func testTheFASTQFamilyReadsTheSameProgressFromTheLines() async throws {
        let fluidigm = try await fluidigmRun()
        let decoder = CLIEventLineDecoder()
        let shown: [CLIEvent] = try Self.lines(fluidigm.streams.standardError).compactMap { line in
            let event = try decoder.decode(line: line)
            if case .progress? = event { return event }
            return nil
        }
        XCTAssertEqual(shown.count, 7)
        XCTAssertEqual(shown.first, .progress(fraction: 0.02, message: "Preparing ONT Fluidigm sample split."))
        XCTAssertEqual(shown.last, .progress(fraction: 1.0, message: "ONT Fluidigm sample split complete."))
    }

    // MARK: The outputs

    func testFluidigmSamplesOutputsKeepTheirBytes() async throws {
        let run = try await fluidigmRun()

        let outputs = try normalizedOutputs(of: run.output)
        XCTAssertEqual(outputs.keys.sorted(), [
            ".lungfish-provenance.json",
            "LF2871.lungfishfastq/.lungfish-provenance.json",
            "LF2871.lungfishfastq/deduplicated-sample-reads.fastq.gz",
            "LF2871.lungfishfastq/deduplicated-sample-reads.fastq.gz.lungfish-provenance.json",
            "LF2871.lungfishfastq/derived.manifest.json",
            "LF2871.lungfishfastq/provenance/bundle.lungfish-provenance.json",
            "ont-fluidigm-counted-samples-manifest.json",
            "ont-fluidigm-counted-samples-manifest.json.lungfish-provenance.json",
        ])
        XCTAssertEqual(
            outputs["LF2871.lungfishfastq/deduplicated-sample-reads.fastq.gz"],
            "@u000001;size=2\nACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIII\n"
        )
        try assertDigest(outputs, equals: Self.fluidigmOutputsDigest)
        try assertResultDocument(run.streams.standardOutput, keys: [
            "assignedReadCount", "extractedReadCount", "inputReadCount", "manifest", "outputBundles",
            "outputDirectory", "unassignedReadCount", "unextractedReadCount", "uniqueSequenceCount",
        ])
    }

    func testPacBioBarcodeDemuxOutputsKeepTheirBytes() async throws {
        let run = try await pacBioRun()

        let outputs = try normalizedOutputs(of: run.output)
        XCTAssertEqual(outputs.keys.sorted(), [
            ".lungfish-provenance.json",
            "32286-001_DL46.lungfishfastq/.lungfish-provenance.json",
            "32286-001_DL46.lungfishfastq/32286-001_DL46.fastq.gz",
            "32286-001_DL46.lungfishfastq/32286-001_DL46.fastq.gz.lungfish-provenance.json",
            "32286-001_DL46.lungfishfastq/derived.manifest.json",
            "32286-001_DL46.lungfishfastq/provenance/bundle.lungfish-provenance.json",
            "ont-pacbio-barcode-demux-manifest.json",
            "ont-pacbio-barcode-demux-manifest.json.lungfish-provenance.json",
        ])
        let payload = try XCTUnwrap(outputs["32286-001_DL46.lungfishfastq/32286-001_DL46.fastq.gz"])
        XCTAssertEqual(payload.split(separator: "\n").count, 8, "two reads of four lines each")
        try assertDigest(outputs, equals: Self.pacBioOutputsDigest)
        try assertResultDocument(run.streams.standardOutput, keys: [
            "assignedReadCount", "chunkJobs", "executedCutadaptChunkCount", "inputChunkCount",
            "inputReadCount", "manifest", "outputBundles", "outputDirectory", "unassignedReadCount",
        ])
    }

    /// The SHA-256 of the sorted-key JSON of `normalizedOutputs`, taken at the commit before the
    /// move to `CLIEvent` lines. A change to what either command writes changes it.
    private static let fluidigmOutputsDigest = "5425eeeb0838ec6cd7f63b60f590ef00b84e25854f6c1f52317a48961a47de9c"
    private static let pacBioOutputsDigest = "1a40f6d943f137cf2392bcaea7f12652fc7612cfff8da43df3d48112701eb3b3"

    private func assertDigest(
        _ outputs: [String: String],
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: outputs, options: [.sortedKeys])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            digest, expected,
            "The outputs differ from the base. Normalized outputs:\n\(String(decoding: data, as: UTF8.self))",
            file: file, line: line
        )
    }

    /// The materializers compute some fractions by arithmetic, so 0.8 can arrive as 0.7999999999999999.
    private func assertProgress(
        _ actual: [Double],
        _ expected: [Double],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(actual)", file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(pair.0, pair.1, accuracy: 1e-9, "progress line \(index + 1)", file: file, line: line)
        }
    }

    private func assertResultDocument(
        _ standardOutput: String,
        keys: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(standardOutput.utf8)) as? [String: Any],
            file: file, line: line
        )
        XCTAssertEqual(document.keys.sorted(), keys, file: file, line: line)
    }

    // MARK: Normalizing outputs

    /// Every file under `output` by relative path. A `.gz` file is its gunzipped text, a `.json`
    /// file is its parsed content with the scratch folder rewritten and the values that change
    /// from run to run removed (an id, a checksum of a compressed payload, a time that ends in
    /// `At`, a duration that ends in `Seconds`), and a provenance record is a marker.
    private func normalizedOutputs(of output: URL) throws -> [String: String] {
        let spellings = [root.path, root.path.replacingOccurrences(of: "/private", with: "")]
            .sorted { $0.count > $1.count }
        func rewritten(_ value: Any, key: String? = nil, parent: String? = nil) -> Any {
            if let key, key.hasSuffix("Seconds"), value is NSNumber { return "<seconds>" }
            if let text = value as? String {
                if key == "checksum" || parent == "checksums" { return "<checksum>" }
                if let key, key.hasSuffix("At") { return "<time>" }
                var result = text
                for spelling in spellings { result = result.replacingOccurrences(of: spelling, with: "/work") }
                return result
            }
            if let dictionary = value as? [String: Any] {
                var result: [String: Any] = [:]
                for (name, item) in dictionary where !(name == "id" && parent == nil) {
                    result[name] = rewritten(item, key: name, parent: key)
                }
                return result
            }
            if let array = value as? [Any] {
                return array.map { rewritten($0, key: key, parent: parent) }
            }
            return value
        }

        var found: [String: String] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: output.path))
        for case let relative as String in enumerator {
            let url = output.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            if url.lastPathComponent.hasSuffix(".lungfish-provenance.json") {
                found[relative] = "<provenance record>"
            } else if url.pathExtension == "gz" {
                found[relative] = try GzipInputStream(url: url).readAllSync()
            } else if url.pathExtension == "json" {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                let data = try JSONSerialization.data(withJSONObject: rewritten(object), options: [.sortedKeys])
                found[relative] = String(decoding: data, as: UTF8.self)
            } else {
                found[relative] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return found
    }

    // MARK: Reading the streams

    private struct ProgressLine {
        let keys: [String]
        let operation: String
        let message: String
        let progress: Double
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The lines of standard error as the private progress shape, each a JSON object.
    private static func progressLines(_ standardError: String) throws -> [ProgressLine] {
        try lines(standardError).map { line in
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "Not a JSON object: \(line)"
            )
            XCTAssertEqual(object["event"] as? String, "progress", line)
            return ProgressLine(
                keys: object.keys.sorted(),
                operation: object["operation"] as? String ?? "",
                message: object["message"] as? String ?? "",
                progress: object["progress"] as? Double ?? -1
            )
        }
    }

    private struct Streams {
        let standardOutput: String
        let standardError: String
    }

    /// Runs `body` with standard output and standard error redirected to files, and gives back
    /// what each stream held.
    private func capturingStandardStreams(_ body: () async throws -> Void) async throws -> Streams {
        let outputFile = root.appendingPathComponent("standard-output.capture")
        let errorFile = root.appendingPathComponent("standard-error.capture")
        fflush(stdout)
        fflush(stderr)
        let savedOutput = dup(STDOUT_FILENO)
        let savedError = dup(STDERR_FILENO)
        let outputDescriptor = open(outputFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        let errorDescriptor = open(errorFile.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard savedOutput >= 0, savedError >= 0, outputDescriptor >= 0, errorDescriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        dup2(outputDescriptor, STDOUT_FILENO)
        dup2(errorDescriptor, STDERR_FILENO)
        close(outputDescriptor)
        close(errorDescriptor)
        var failure: Error?
        do {
            try await body()
        } catch {
            failure = error
        }
        fflush(stdout)
        fflush(stderr)
        dup2(savedOutput, STDOUT_FILENO)
        dup2(savedError, STDERR_FILENO)
        close(savedOutput)
        close(savedError)
        if let failure { throw failure }
        return Streams(
            standardOutput: try String(contentsOf: outputFile, encoding: .utf8),
            standardError: try String(contentsOf: errorFile, encoding: .utf8)
        )
    }

    // MARK: Small helpers

    private func writeFASTQ(_ name: String, reads: [String]) throws -> URL {
        let url = root.appendingPathComponent(name)
        let text = reads.enumerated().map { index, read in
            "@read-\(index + 1)\n\(read)\n+\n\(String(repeating: "I", count: read.count))\n"
        }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base -> Character in
            switch base {
            case "A": return "T"
            case "C": return "G"
            case "G": return "C"
            case "T": return "A"
            default: return "N"
            }
        })
    }
}
