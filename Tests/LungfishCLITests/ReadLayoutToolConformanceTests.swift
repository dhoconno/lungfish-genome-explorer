// ReadLayoutToolConformanceTests.swift - The real reformat.sh and clumpify.sh on the read layouts of row READ-LAYOUT-PARTIAL-SCAN
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishPortable
import LungfishTestSupport
import LungfishWorkflow

/// A real-tool suite. Its name keeps it out of the unit tier, and it skips when a managed tool is missing, or fails
/// under LUNGFISH_REQUIRE_TOOLS=1. Nothing here contacts a live service.
final class ReadLayoutToolConformanceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "read-layout-tools")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func requireNativeTool(_ tool: NativeTool, file: StaticString = #filePath, line: UInt = #line) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(tool) else {
            try ToolAvailability.skipOrFail("\(tool.executableName) is not available in this test environment", file: file, line: line)
        }
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func environment() async -> [String: String] {
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser, existingPath: existingPath)
    }

    /// `testFastqDeinterleaveStrictKeepsBytes` of ruling section 6, on the forms a whole-file scan calls strict. A run
    /// with `vint=t` writes the bytes a run of `reformat.sh` without it writes. Red at the lane's head only through
    /// the argv assertion, since until `vint=t` is there the two runs are one argv.
    func testFastqDeinterleaveStrictKeepsBytes() async throws {
        try await requireNativeTool(.reformat)
        let input = root.appendingPathComponent("strict.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(70_000)], to: input)
        let out1 = root.appendingPathComponent("r1.fastq"), out2 = root.appendingPathComponent("r2.fastq")

        try await FastqDeinterleaveSubcommand.parse([input.path, "--out1", out1.path, "--out2", out2.path]).run()

        let plain1 = root.appendingPathComponent("plain1.fastq"), plain2 = root.appendingPathComponent("plain2.fastq")
        let argv = BBToolsPairArguments.deinterleave(input: input.path, out1: plain1.path, out2: plain2.path)
        XCTAssertTrue(argv.contains("vint=t"), "\(argv)")
        let withoutCheck = argv.filter { $0 != "vint=t" }
        let run = try await NativeToolRunner.shared.run(
            .reformat, arguments: withoutCheck, environment: await environment(), timeout: AnalysisTimeLimit.launchTimeout)
        XCTAssertTrue(run.isSuccess, run.stderr)
        XCTAssertEqual(try digest(out1), try digest(plain1))
        XCTAssertEqual(try digest(out2), try digest(plain2))
    }

    private func split(_ input: URL, _ out1: URL, _ out2: URL) async throws -> (outcome: NativeToolResult, arguments: [String]) {
        let env = await environment()
        return try await BBToolsPairArguments.runDeinterleave(
            input: input.path, out1: out1.path, out2: out2.path,
            run: { try await NativeToolRunner.shared.run(.reformat, arguments: $0, environment: env, timeout: AnalysisTimeLimit.launchTimeout) },
            failureWords: { $0.isSuccess ? nil : $0.stderr }
        )
    }

    /// Item 1. The real tool on small true pairs in each name form. `vint=t` agrees on the forms it reads, and on the
    /// others LGE's check decides and the split runs without it. The output is the true pairs in every form.
    func testEveryTrueNameFormSplitsThroughTheSharedRoute() async throws {
        try await requireNativeTool(.reformat)
        let forms: [(name: String, pairs: [(String, String)], toolAgrees: Bool)] = [
            ("SRR123.1.1 and SRR123.1.2", (1...3).map { ("SRR123.\($0).1", "SRR123.\($0).2") }, false),
            ("the same, as stored", (1...3).map { ("SRR123.\($0).1 \($0) length=8", "SRR123.\($0).2 \($0) length=8") }, false),
            ("SRR123.1/1 and SRR123.1/2", (1...3).map { ("SRR123.\($0)/1", "SRR123.\($0)/2") }, true),
            ("Casava comments", (1...3).map { ("M00:1:FC:1:1:1:\($0) 1:N:0:ACGT", "M00:1:FC:1:1:1:\($0) 2:N:0:ACGT") }, true),
            ("name/1 and name/2", (1...3).map { ("read\($0)/1", "read\($0)/2") }, true),
            ("identical names", (1...3).map { ("read\($0)", "read\($0)") }, true),
            ("identical names, SRA comment", (1...3).map { ("SRR123.\($0) \($0) length=8", "SRR123.\($0) \($0) length=8") }, true),
            ("read_1 and read_2", (1...3).map { ("read\($0)_1", "read\($0)_2") }, false),
        ]
        for form in forms {
            let input = root.appendingPathComponent("\(UUID().uuidString).fastq")
            let text = form.pairs.map { "@\($0.0)\nACGTACGT\n+\nIIIIIIII\n@\($0.1)\nTTGGCCAA\n+\nIIIIIIII\n" }.joined()
            try text.write(to: input, atomically: true, encoding: .utf8)
            let out1 = root.appendingPathComponent("\(UUID().uuidString).r1.fastq")
            let out2 = root.appendingPathComponent("\(UUID().uuidString).r2.fastq")

            let result = try await split(input, out1, out2)

            XCTAssertTrue(result.outcome.isSuccess, "\(form.name): \(result.outcome.stderr)")
            XCTAssertEqual(result.arguments.contains("vint=t"), form.toolAgrees, form.name)
            let header1 = try String(contentsOf: out1, encoding: .utf8).split(separator: "\n").enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
            let header2 = try String(contentsOf: out2, encoding: .utf8).split(separator: "\n").enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
            XCTAssertEqual(header1.map(String.init), form.pairs.map { "@\($0.0)" }, form.name)
            XCTAssertEqual(header2.map(String.init), form.pairs.map { "@\($0.1)" }, form.name)
        }
    }

    /// Ruling section 6. Cannot be red first, since the route it runs is new in the fix. `reformat.sh` left 14.5 MB of
    /// partial files and a Java stack on this file before the fix, as the ruling measured.
    func testReformatRefusalRemovesOutputsAndShowsNoStack() async throws {
        try await requireNativeTool(.reformat)
        let input = root.appendingPathComponent("mix.fastq")
        try FASTQLayoutRecordFixtures.write([.pairs(60_000), .singles(20_000)], to: input)
        let out1 = root.appendingPathComponent("r1.fastq"), out2 = root.appendingPathComponent("r2.fastq")
        do {
            _ = try await split(input, out1, out2)
            XCTFail("a false pair must stop the split")
        } catch FASTQPairInterleaver.InterleaveError.mateNameMismatch(let recordNumber, _, let name1, _, let name2) {
            XCTAssertEqual(recordNumber, 60_001)
            XCTAssertEqual(name1, "m0")
            XCTAssertEqual(name2, "m1")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out1.path), "no partial R1 stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out2.path), "no partial R2 stays")
        let words = FASTQPairInterleaver.InterleaveError.mateNameMismatch(
            recordNumber: 60_001, r1File: "mix.fastq", r1Name: "m0", r2File: "mix.fastq", r2Name: "m1"
        ).localizedDescription
        XCTAssertFalse(words.contains("at jgi."), words)
        XCTAssertFalse(words.contains("Exception"), words)
    }

    /// Ruling section 6. Clumping moves the pairs first, so a bounded scan of the stored file would read pairs alone.
    /// Red at ebe9373cf, where `fastq deinterleave` then wrote 10,000 false pairs. The label is right since items 5
    /// and 6, so its recorded counts are the red part at the lane's head.
    func testDefaultClumpingOfMergedFirstFileStaysMixed() async throws {
        try await requireNativeTool(.clumpify)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("merged-first.fastq")
        try FASTQLayoutRecordFixtures.write([.singles(20_000), .pairs(60_000)], to: input)

        try await ImportCommand.FastqSubcommand.parse([
            input.path, "--project", project.path, "--platform", "illumina", "--quality-binning", "none",
            "--no-color", "--pairing", "auto",
        ]).run()

        let bundle = project.appendingPathComponent("Imports/merged-first.lungfishfastq", isDirectory: true)
        let resolution = FASTQInputLayoutResolver.resolve(inputURLs: [bundle])
        XCTAssertEqual(resolution.layout, .mixedMergedAndPairs, resolution.reason)
        XCTAssertEqual(resolution.classification?.matePairs, 60_000)
        XCTAssertEqual(resolution.classification?.unpairedRecords, 20_000)
        XCTAssertEqual(resolution.classification?.scannedWholeFile, true)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        XCTAssertEqual(FASTQMetadataStore.load(for: fastq)?.recordedReadCount?.pairedR1, 60_000)
    }
}
