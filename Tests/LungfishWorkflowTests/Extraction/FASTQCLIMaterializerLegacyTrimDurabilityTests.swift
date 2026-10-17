// FASTQCLIMaterializerLegacyTrimDurabilityTests.swift - The legacy trim reports a flush the disk refused
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane S62, M2 (inventory row D3). The materializer's legacy relative trim closed its writer with
// `defer { try? writer.close() }`, so the flush of the last buffered records could fail and the trimmed FASTQ
// stayed short with no error. The writer buffers up to 256 KB, so a small input reaches the disk only in
// `close()`. The file size limit of the process makes that flush fail with EFBIG, as a full disk would.
// The class name holds `Durability`, so `exfat-tests.sh --simulate` runs it.

import Darwin
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

final class FASTQCLIMaterializerLegacyTrimDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "materializer-legacy-trim-durability")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Runs `body` with the process's file size limit at `limit` bytes and SIGXFSZ ignored, so a write that takes
    /// a regular file past the limit fails with EFBIG. The limit and the signal are restored afterwards.
    private func withFileSizeLimit<Result>(_ limit: rlim_t, _ body: () async throws -> Result) async rethrows -> Result {
        var original = rlimit()
        getrlimit(RLIMIT_FSIZE, &original)
        let originalHandler = signal(SIGXFSZ, SIG_IGN)
        var lowered = original
        lowered.rlim_cur = limit
        setrlimit(RLIMIT_FSIZE, &lowered)
        defer {
            setrlimit(RLIMIT_FSIZE, &original)
            signal(SIGXFSZ, originalHandler)
        }
        return try await body()
    }

    private func makeInputs() throws -> (source: URL, trims: URL, output: URL) {
        let source = root.appendingPathComponent("source.fastq")
        try Data("@read1\nAACCGGTT\n+\nIIIIIIII\n@read2\nTTGGCCAA\n+\nIIIIIIII\n".utf8).write(to: source)
        let trims = root.appendingPathComponent("trim-positions.tsv")
        try Data("#format lungfish-demux-trim-v1\nread_id\tmate\ttrim_5p\ttrim_3p\nread1\t0\t1\t1\n".utf8).write(to: trims)
        return (source, trims, root.appendingPathComponent("trimmed.fastq"))
    }

    /// The control. The limit makes the flush of a `FASTQWriter` fail, so the tests below fail for that reason.
    func testTheFileSizeLimitMakesTheFlushOfAFASTQWriterFail() async throws {
        let output = root.appendingPathComponent("control.fastq")
        let writer = FASTQWriter(url: output)
        try writer.open()
        try writer.write(FASTQRecord(identifier: "read1", sequence: "ACGT", qualityString: "IIII"))

        try await withFileSizeLimit(0) {
            XCTAssertThrowsError(try writer.close())
        }
    }

    func testAFlushTheDiskRefusedIsAThrownErrorOfTheLegacyTrim() async throws {
        let inputs = try makeInputs()
        let materializer = FASTQCLIMaterializer(runner: .shared)

        var thrown: (any Error)?
        await withFileSizeLimit(0) {
            do {
                try await materializer.applyLegacyRelativeTrim(
                    from: inputs.source, trimPositionsURL: inputs.trims, outputFASTQ: inputs.output
                )
            } catch {
                thrown = error
            }
        }

        XCTAssertNotNil(thrown, "a flush the disk refused is a thrown error, never a short FASTQ")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputs.output.path), "the writer opened, so the failure came at the flush")
    }

    func testTheLegacyTrimStillWritesTheTrimmedFASTQWhenTheDiskTakesIt() async throws {
        let inputs = try makeInputs()

        try await FASTQCLIMaterializer(runner: .shared).applyLegacyRelativeTrim(
            from: inputs.source, trimPositionsURL: inputs.trims, outputFASTQ: inputs.output
        )

        XCTAssertEqual(
            try String(contentsOf: inputs.output, encoding: .utf8),
            "@read1\nACCGGT\n+\nIIIIII\n@read2\nTTGGCCAA\n+\nIIIIIIII\n"
        )
    }
}
