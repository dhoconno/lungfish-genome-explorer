// ReadExtractionPairedBundleTests.swift - An extraction bundle of two mates records the reads of both (Phase 3.3 lane PAIREDROOT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

/// `extract reads --by-id --source R1 --source R2 --bundle` counted the first output file only, so the summary said
/// "Reads extracted: 4" for four pairs (eight reads) beside "Paired-end: yes", and the bundle's record held the same 4
/// (BIO-PAIRED-ROOT-PRIMARY item 5, S1). The count now covers every output file. The tool is a stand-in script, since the
/// count and the record are the point and not seqkit.
final class ReadExtractionPairedBundleTests: XCTestCase {

    private var root: URL!
    private var runner: NativeToolRunner!

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("read-extract-paired-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = home.appendingPathComponent(".lungfish/conda/envs/seqkit/bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let seqkit = bin.appendingPathComponent("seqkit")
        try Self.seqkitScript.write(to: seqkit, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: seqkit.path)
        // The fake home sits under `.lungfish`, the Preview namespace, so the runner's identity is pinned to it.
        runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: home, appIdentity: .preview)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func reads(_ prefix: String) -> String {
        (1...4).map { "@\(prefix)\($0)\nACGT\n+\nIIII\n" }.joined()
    }

    func testExtractByIDBundleOfTwoSourcesRecordsBothMates() async throws {
        let inputs = root.appendingPathComponent("in", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let r1 = inputs.appendingPathComponent("s_R1.fastq")
        let r2 = inputs.appendingPathComponent("s_R2.fastq")
        try reads("p").write(to: r1, atomically: true, encoding: .utf8)
        try reads("p").write(to: r2, atomically: true, encoding: .utf8)
        let outputs = root.appendingPathComponent("out", isDirectory: true)
        let service = ReadExtractionService(toolRunner: runner)

        let result = try await service.extractByReadIDs(config: ReadIDExtractionConfig(
            sourceFASTQs: [r1, r2],
            readIDs: ["p1", "p2", "p3", "p4"],
            outputDirectory: outputs,
            outputBaseName: "pair"
        ))

        XCTAssertEqual(result.fastqURLs.map(\.lastPathComponent), ["pair_R1.fastq.gz", "pair_R2.fastq.gz"])
        XCTAssertTrue(result.pairedEnd)
        XCTAssertEqual(result.readCount, 8, "four pairs are eight reads, and the first file alone holds four")

        let bundleURL = try await service.createBundle(
            from: result,
            sourceName: "pair",
            selectionDescription: "extract",
            metadata: ExtractionMetadata(
                sourceDescription: "fixture",
                toolName: "test",
                extractionDate: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            in: outputs
        )

        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: bundleURL))
        XCTAssertEqual(provenance.options.resolvedDefaults["readCount"], .integer(8), "the record holds the reads of both mates")
        let names = try FileManager.default.contentsOfDirectory(atPath: bundleURL.path)
        XCTAssertTrue(names.contains("pair_R1.fastq.gz") && names.contains("pair_R2.fastq.gz"), "both mates are in the bundle")
    }

    /// Stands in for seqkit. `grep` copies the source to the output named after `-o`, and `stats -T` prints the number of
    /// records of the file. The files hold plain text, which is all the count needs.
    private static let seqkitScript = """
    #!/bin/sh
    if [ "$1" = "version" ]; then
      echo "seqkit v2.13.0"
      exit 0
    fi
    if [ "$1" = "grep" ]; then
      last=""; src=""; out=""; take=0
      for arg in "$@"; do
        if [ "$take" = 1 ]; then out="$arg"; take=0; fi
        if [ "$arg" = "-o" ]; then src="$last"; take=1; fi
        last="$arg"
      done
      cp "$src" "$out"
      exit 0
    fi
    if [ "$1" = "stats" ]; then
      file="$3"
      n=$(( $(wc -l < "$file") / 4 ))
      printf 'file\\tformat\\ttype\\tnum_seqs\\tsum_len\\tmin_len\\tavg_len\\tmax_len\\n'
      printf '%s\\tFASTQ\\tDNA\\t%s\\t0\\t0\\t0\\t0\\n' "$file" "$n"
      exit 0
    fi
    exit 1
    """
}
