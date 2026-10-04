// ONTSplitVirtualInputProvenanceTests.swift - The ONT split commands record a virtual input as its bundle, never its preview
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `fastq ont-fluidigm-samples` and `fastq ont-pacbio-barcode-demux` read a
// virtual input's materialized reads (Phase 1.5 lane A6b), but their
// provenance recorded the file the input lists, which for a virtual bundle
// is its preview. The materialized scratch is gone when provenance is
// written, so the run records the bundle the user chose. Materialization
// needs the managed seqkit, so these tests skip without it.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ONTSplitVirtualInputProvenanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-split-virtual-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFluidigmSamplesRecordsTheVirtualBundleNotItsPreview() async throws {
        try await Self.requireSeqkit()
        let read = "ACACTGACGACATGGTTCTACA" + "ACGTACGTACGTACGT"
            + Self.reverseComplement(ONTFluidigmAmpliconMaterializer.defaultReversePrimer) + "CC" + "AAAACCCCGG"
        let input = try makeONTSubset(reads: [("read-1", read), ("read-2", read)])
        let barcodes = root.appendingPathComponent("samples.csv")
        try "sample,barcode\nLF2871,AAAACCCCGG\n".write(to: barcodes, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("fluidigm", isDirectory: true)

        try await FastqONTFluidigmSamplesSubcommand.parse([
            input.path, "--barcodes", barcodes.path, "--output", output.path,
            "--primer-mismatches", "0", "--minimum-insert-length", "8", "--force",
        ]).run()

        try assertRecordsTheBundle(input, in: output)
    }

    func testPacBioBarcodeDemuxRecordsTheVirtualBundleNotItsPreview() async throws {
        try await Self.requireSeqkit()
        let read = String(repeating: "T", count: 60) + "CACATATCAGAGTGCG" + String(repeating: "ACGT", count: 510)
            + Self.reverseComplement("CTATACATAGTGATGT") + String(repeating: "A", count: 60)
        let input = try makeONTSubset(reads: [("read-1", read), ("read-2", read)])
        let barcodes = root.appendingPathComponent("plate.barcodes.csv")
        try "32286-001_DL46,BC1001,BC1021\n".write(to: barcodes, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("pacbio", isDirectory: true)

        try await FastqONTPacBioBarcodeDemuxSubcommand.parse([
            input.path, "--barcodes", barcodes.path, "--output", output.path,
            "--chunk-jobs", "1", "--max-reads-per-slice", "0", "--force",
        ]).run()

        try assertRecordsTheBundle(input, in: output)
    }

    // MARK: - Helpers

    private func assertRecordsTheBundle(_ bundle: URL, in output: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: output), file: file, line: line)
        let names = envelope.steps.flatMap(\.inputs).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertFalse(names.contains("preview.fastq"), "the preview is never the recorded input: \(names)", file: file, line: line)
        XCTAssertTrue(names.contains(bundle.lastPathComponent), "the bundle the user chose is recorded: \(names)", file: file, line: line)
    }

    /// An ONT root holding `reads` that records the Oxford Nanopore platform,
    /// and a virtual length-filter subset listing every read, whose preview
    /// holds the first.
    private func makeONTSubset(reads: [(id: String, sequence: String)]) throws -> URL {
        let fm = FileManager.default
        let imports = root.appendingPathComponent("ONT.lungfish/Imports", isDirectory: true)
        let rootBundle = imports.appendingPathComponent("ont-reads.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        let rootFile = rootBundle.appendingPathComponent("reads.fastq")
        try reads.map { Self.record($0.id, $0.sequence) }.joined().write(to: rootFile, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore), for: rootFile)

        let bundle = imports.appendingPathComponent("ont-reads-subset.lungfishfastq", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try (reads.map(\.id).joined(separator: "\n") + "\n")
            .write(to: bundle.appendingPathComponent("read-ids.txt"), atomically: true, encoding: .utf8)
        try Self.record(reads[0].id, reads[0].sequence)
            .write(to: bundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .lengthFilter)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "ont-reads-subset",
                parentBundleRelativePath: "@/Imports/ont-reads.lungfishfastq",
                rootBundleRelativePath: "@/Imports/ont-reads.lungfishfastq",
                rootFASTQFilename: "reads.fastq",
                payload: .subset(readIDListFilename: "read-ids.txt"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: reads.count, baseCount: 0),
                pairingMode: .singleEnd
            ),
            in: bundle
        )
        return bundle.standardizedFileURL
    }

    private static func record(_ id: String, _ sequence: String) -> String {
        "@\(id)\n\(sequence)\n+\n\(String(repeating: "I", count: sequence.count))\n"
    }

    private static func requireSeqkit() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed")
        }
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
