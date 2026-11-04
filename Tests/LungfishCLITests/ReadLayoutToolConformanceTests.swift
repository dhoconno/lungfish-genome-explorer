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
}
