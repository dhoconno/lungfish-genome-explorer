// FASTQBatchImporterAdapterTrimArgumentsTests.swift - The fastp argv of a legacy recipe's adapter trim on one file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Ruling BIO-PROBES-E, items 2, 3 and 10. Single reads name their adapters, so fastp guesses none, and the step's own
// adapter reaches fastp where it was dropped. An interleaved file keeps the argv it had.

import XCTest
@testable import LungfishWorkflow

final class FASTQBatchImporterAdapterTrimArgumentsTests: XCTestCase {

    private let input = URL(fileURLWithPath: "/work/in.fastq.gz")
    private let output = URL(fileURLWithPath: "/work/step_0.fastq.gz")
    private let r2Output = URL(fileURLWithPath: "/work/step_0_R2.fastq.gz")
    private let head = ["-i", "/work/in.fastq.gz", "-o", "/work/step_0.fastq.gz",
                        "-w", "4", "--json", "/dev/null", "--html", "/dev/null"]

    private func arguments(interleaved: Bool, adapter: String? = nil, adapterR2: String? = nil) throws -> [String] {
        try FASTQBatchImporter.legacyAdapterTrimArguments(
            input: input, output: output, r2Output: r2Output, threads: 4, interleaved: interleaved,
            adapterSequence: adapter, adapterSequenceR2: adapterR2
        )
    }

    func testSingleReadsWithNoAdapterNameTruSeqReadOneAndTheKnownAdapters() throws {
        let args = try arguments(interleaved: false)
        XCTAssertEqual(Array(args.prefix(head.count)), head)
        let named = Array(args.dropFirst(head.count))
        XCTAssertEqual(named.count, 4, "\(args)")
        XCTAssertEqual(Array(named.prefix(3)), ["-a", "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA", "--adapter_fasta"])
        XCTAssertTrue(named[3].hasSuffix("/Tools/fastp-known-adapters.fasta"), named[3])
        XCTAssertTrue(FileManager.default.fileExists(atPath: named[3]), "the bundled FASTA exists: \(named[3])")
    }

    func testSingleReadsPassTheStepsOwnAdapter() throws {
        let args = try arguments(interleaved: false, adapter: "CTGTCTCTTATACACATCT")
        XCTAssertEqual(args, head + ["--adapter_sequence", "CTGTCTCTTATACACATCT"])
        XCTAssertFalse(args.contains("--adapter_fasta"), "a named adapter needs no list")
    }

    func testInterleavedReadsKeepTheirArgvWhenTheStepNamesNoAdapter() throws {
        XCTAssertEqual(
            try arguments(interleaved: true),
            head + ["--interleaved_in", "-O", "/work/step_0_R2.fastq.gz"]
        )
    }

    func testInterleavedReadsPassTheStepsOwnAdapters() throws {
        XCTAssertEqual(
            try arguments(interleaved: true, adapter: "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA",
                          adapterR2: "AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT"),
            head + ["--interleaved_in", "-O", "/work/step_0_R2.fastq.gz",
                    "--adapter_sequence", "AGATCGGAAGAGCACACGTCTGAACTCCAGTCA",
                    "--adapter_sequence_r2", "AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT"]
        )
    }
}
