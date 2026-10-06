// ReadIDMatchingArgvTests.swift - Only the Kraken2 path asks seqkit to match fragment names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// D7c, Phase 1.5 lane A3. Kraken2 extraction matches a mate named `X/1`
// to the fragment name `X` with seqkit's --id-regexp. Every other caller of
// ReadExtractionService.extractByReadIDs keeps the argv it ran before.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class ReadIDMatchingArgvTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "read-id-matching")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testTheDefaultKeepsTheArgvEveryCallerRanBefore() async throws {
        let (service, source, output, log) = try fakeSeqkitService()
        let config = ReadIDExtractionConfig(sourceFASTQs: [source], readIDs: ["r1"], outputDirectory: output, outputBaseName: "picked")

        _ = try await service.extractByReadIDs(config: config)

        let argv = try XCTUnwrap(try grepCalls(in: log).first)
        XCTAssertEqual(argv.count, 8, "\(argv)")
        XCTAssertEqual(argv[0], "grep")
        XCTAssertEqual(argv[1], "-f")
        XCTAssertTrue(argv[2].hasSuffix("/read_ids.txt"), argv[2])
        XCTAssertEqual(Array(argv[3...]), [
            source.path, "-o", output.appendingPathComponent("picked.fastq.gz").path, "--threads", "4",
        ])
    }

    func testFragmentNameMatchingAddsOnlyTheIDRegexp() async throws {
        let (service, source, output, log) = try fakeSeqkitService()
        let config = ReadIDExtractionConfig(sourceFASTQs: [source], readIDs: ["r1"], outputDirectory: output, outputBaseName: "picked")

        _ = try await service.extractByReadIDs(config: config, matching: .fragmentName)

        let argv = try XCTUnwrap(try grepCalls(in: log).first)
        XCTAssertEqual(Array(argv[0...2]), ["grep", "--id-regexp", #"^(\S+?)(?:/[12])?(?:\s|$)"#])
        XCTAssertEqual(argv[3], "-f")
        XCTAssertEqual(Array(argv[5...]), [
            source.path, "-o", output.appendingPathComponent("picked.fastq.gz").path, "--threads", "4",
        ])
    }

    /// The in-step pair extraction reads IDs in Swift (Phase 2.1 lane L6).
    /// It must read the ID seqkit captures with the same pattern, the name
    /// the pinned kraken2 writes for a pair (KrakenReadSetConformanceTests).
    func testTheSwiftReadIDIsTheIDTheSeqkitPatternCaptures() throws {
        let pattern = try NSRegularExpression(pattern: #"^(\S+?)(?:/[12])?(?:\s|$)"#)
        let headers = [
            "@M.5", "@M.15", "@S_2", "@x.1", "@.5", "@A/1", "@B/2", "@C/3", "@/1", "@H/1/1",
            "@x/2 1:N:0:ACGT", "@SRR1.7 7 length=150", "@p1\tcomment", "@read/1/2/1", "@ab",
        ]
        for header in headers {
            let name = String(header.dropFirst())
            let range = NSRange(name.startIndex..., in: name)
            let match = try XCTUnwrap(pattern.firstMatch(in: name, range: range), header)
            let captured = String(name[try XCTUnwrap(Range(match.range(at: 1), in: name))])
            XCTAssertEqual(ReadIDMatching.fragmentName.readID(ofHeaderLine: header), captured, header)
        }
        XCTAssertEqual(ReadIDMatching.fragmentName.readID(ofHeaderLine: "@H/1/1"), "H/1")
        XCTAssertEqual(ReadIDMatching.firstWord.readID(ofHeaderLine: "@x/2 1:N:0:ACGT"), "x/2")
    }

    // MARK: - Fake seqkit

    /// A service whose seqkit, under a home of its own, logs every argv,
    /// writes one record for `grep` and reports one record for `stats`.
    private func fakeSeqkitService() throws -> (ReadExtractionService, URL, URL, URL) {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = home.appendingPathComponent(".lungfish/conda/envs/seqkit/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("argv.log")
        let script = """
        #!/bin/bash
        { for argument in "$@"; do printf '%s\\n' "$argument"; done; printf -- '--end--\\n'; } >> "\(log.path)"
        if [ "$1" = "grep" ]; then
          output=""; previous=""
          for argument in "$@"; do if [ "$previous" = "-o" ]; then output="$argument"; fi; previous="$argument"; done
          printf '@r1/1\\nACGT\\n+\\nIIII\\n' | /usr/bin/gzip -c > "$output"
          exit 0
        fi
        printf 'file\\tformat\\ttype\\tnum_seqs\\n%s\\tFASTQ\\tDNA\\t1\\n' "$3"

        """
        let tool = bin.appendingPathComponent("seqkit")
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let source = root.appendingPathComponent("reads.fastq")
        try "@r1/1\nACGT\n+\nIIII\n".write(to: source, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("out", isDirectory: true)
        let runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: home, appIdentity: .preview)
        return (ReadExtractionService(toolRunner: runner), source, output, log)
    }

    /// The argv of every `seqkit grep` the fake ran, in order.
    private func grepCalls(in log: URL) throws -> [[String]] {
        let lines = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "\n")
        var calls: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line == "--end--" {
                if current.first == "grep" { calls.append(current) }
                current = []
            } else if !line.isEmpty {
                current.append(line)
            }
        }
        return calls
    }
}
