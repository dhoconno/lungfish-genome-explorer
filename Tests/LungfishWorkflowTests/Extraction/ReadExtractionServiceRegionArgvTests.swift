// ReadExtractionServiceRegionArgvTests.swift - The samtools view argv of a region extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `ReadExtractionService.extractByBAMRegion` serves `lungfish-cli extract reads
// --by-region` and the app's Extract Overlapping Reads action (R3). A region in
// samtools notation (`chr1:11-25`) must reach samtools as given, so samtools
// selects the reads that overlap it. With more than one such region the
// service adds `-M`, the union of the regions, because samtools otherwise
// writes a read that overlaps two regions once per region. A list of whole
// reference names must keep the exact argv it had. Stand-in samtools and
// seqkit in a scratch home record every argv.

import Foundation
import XCTest
@testable import LungfishWorkflow

final class ReadExtractionServiceRegionArgvTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var bamURL: URL!
    private var indexURL: URL!
    private var argvLog: URL!

    override func setUpWithError() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("region-argv-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        argvLog = root.appendingPathComponent("samtools-argv.log")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        bamURL = root.appendingPathComponent("Mapping Run/sample.sorted.bam")
        indexURL = root.appendingPathComponent("Mapping Run/sample.sorted.bam.bai")
        try fileManager.createDirectory(at: bamURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 128).write(to: bamURL)
        try Data(repeating: 0x49, count: 32).write(to: indexURL)
        try writeManagedTool(environment: "samtools", executable: "samtools", script: """
        #!/bin/sh
        for argument in "$@"; do printf '%s\\n' "$argument" >> '\(argvLog.path)'; done
        printf '%s\\n' '<end of call>' >> '\(argvLog.path)'
        if [ "$1" = "--version" ]; then echo "samtools 1.24"; exit 0; fi
        if [ "$1" = "view" ] && [ "$2" = "-H" ]; then
          printf '@HD\\tVN:1.6\\tSO:coordinate\\n@SQ\\tSN:MT192765.1\\tLN:29829\\n'
          exit 0
        fi
        if [ "$1" = "view" ] && [ "$2" = "-b" ]; then
          out=""
          previous=""
          for argument in "$@"; do
            if [ "$previous" = "-o" ]; then out="$argument"; fi
            previous="$argument"
          done
          head -c 256 /dev/zero > "$out"
          exit 0
        fi
        if [ "$1" = "fastq" ]; then
          other=""
          previous=""
          for argument in "$@"; do
            if [ "$previous" = "-0" ]; then other="$argument"; fi
            previous="$argument"
          done
          printf '@read1\\nACGT\\n+\\nIIII\\n' > "$other"
          exit 0
        fi
        echo "unexpected samtools call: $*" >&2
        exit 2
        """)
        try writeManagedTool(environment: "seqkit", executable: "seqkit", script: """
        #!/bin/sh
        if [ "$1" = "version" ]; then echo "seqkit v2.8.2"; exit 0; fi
        if [ "$1" = "stats" ]; then
          printf 'file\\tformat\\ttype\\tnum_seqs\\tsum_len\\tmin_len\\tavg_len\\tmax_len\\n%s\\tFASTQ\\tDNA\\t1\\t4\\t4\\t4.0\\t4\\n' "$3"
          exit 0
        fi
        echo "unexpected seqkit call: $*" >&2
        exit 2
        """)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func writeManagedTool(environment: String, executable: String, script: String) throws {
        let binDirectory = home
            .appendingPathComponent(".lungfish/conda/envs", isDirectory: true)
            .appendingPathComponent(environment, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let toolURL = binDirectory.appendingPathComponent(executable)
        try script.write(to: toolURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
    }

    /// Runs the extraction and returns the arguments of its `samtools view -b`
    /// call, with the scratch output path replaced by `<staged.bam>`.
    private func viewArguments(regions: [String]) async throws -> [String] {
        let service = ReadExtractionService(
            toolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: home, appIdentity: .preview)
        )
        let config = BAMRegionExtractionConfig(
            bamURL: bamURL,
            indexURL: indexURL,
            regions: regions,
            fallbackToAll: false,
            outputDirectory: root.appendingPathComponent("Mapping Run/annotation-extractions", isDirectory: true),
            outputBaseName: "gene"
        )
        let result = try await service.extractByBAMRegion(config: config)
        XCTAssertEqual(result.readCount, 1)
        // The stand-in logs one argument per line and ends each call with a
        // marker line.
        let lines = try String(contentsOf: argvLog, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var calls: [[String]] = [[]]
        for line in lines {
            if line == "<end of call>" { calls.append([]) } else if !line.isEmpty { calls[calls.count - 1].append(line) }
        }
        var arguments = try XCTUnwrap(calls.first { $0.starts(with: ["view", "-b"]) }, "samtools calls: \(calls)")
        if let output = arguments.firstIndex(of: "-o") {
            arguments[output + 1] = "<staged.bam>"
        }
        try? FileManager.default.removeItem(at: argvLog)
        return arguments.map { $0 == bamURL.path ? "<bam>" : $0 == indexURL.path ? "<bai>" : $0 }
    }

    func testWholeReferenceNamesKeepTheirExactArgv() async throws {
        let arguments = try await viewArguments(regions: ["MT192765.1"])
        XCTAssertEqual(
            arguments,
            ["view", "-b", "-F", "1024", "-o", "<staged.bam>", "-X", "<bam>", "<bai>", "MT192765.1"]
        )
    }

    func testCoordinateRegionsReachSamtoolsAsGivenWithTheirUnion() async throws {
        let arguments = try await viewArguments(regions: ["MT192765.1:101-130", "MT192765.1:201-220"])
        XCTAssertEqual(
            arguments,
            ["view", "-b", "-M", "-F", "1024", "-o", "<staged.bam>", "-X", "<bam>", "<bai>",
             "MT192765.1:101-130", "MT192765.1:201-220"]
        )
    }
}
