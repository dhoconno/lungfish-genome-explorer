// FASTQFastpTrimAdapterFASTATests.swift - The combined fastp trim refuses an adapter FASTA instead of trimming no adapters
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A `.fastpTrim` request (fastp Adapter & Quality Trim) in adapter FASTA mode
// names no FASTA, and `lungfish-cli fastq trim` takes none. The in-process
// trim used to turn adapter trimming off for it and trim quality only, so the
// derivative silently kept every adapter (R3). Neither the dialog nor the
// dataset viewport offers the mode, but an import recipe step can carry it.
// The trim now fails with a clear error before fastp runs. The runner in
// these tests has no managed tools, so no fastp can run.

import XCTest
@testable import LungfishApp
import LungfishIO
@testable import LungfishWorkflow

final class FASTQFastpTrimAdapterFASTATests: XCTestCase {
    private var root: URL!
    private let request = FASTQDerivativeRequest.fastpTrim(
        threshold: 20, windowSize: 4, mode: .cutRight, adapterMode: .fastaFile, adapterSequence: nil
    )

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastp-adapter-fasta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A service whose runner finds no managed tool.
    private func serviceWithoutTools() -> FASTQDerivativeService {
        FASTQDerivativeService(runner: NativeToolRunner(
            toolsDirectory: nil,
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            appIdentity: .preview
        ))
    }

    private func writeReads(to url: URL) throws {
        try "@read-1\nACGTACGTAC\n+\nIIIIIIIIII\n@read-2\nTTGGCCAATT\n+\nIIIIIIIIII\n"
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func assertRefusesTheAdapterFASTA(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case FASTQDerivativeError.invalidOperation(let reason) = error else {
            return XCTFail("expected the adapter FASTA refusal, got \(error)", file: file, line: line)
        }
        // The refusal names the operation the way the Tools menu and the dialog do.
        XCTAssertTrue(reason.hasPrefix("fastp Adapter & Quality Trim takes no adapter FASTA file"), reason, file: file, line: line)
        XCTAssertTrue(reason.contains("adapter FASTA"), reason, file: file, line: line)
        XCTAssertTrue(reason.contains("would remove no adapters"), reason, file: file, line: line)
    }

    func testTheTrimOperationRefusesAnAdapterFASTAAndKeepsTheOtherModes() throws {
        XCTAssertThrowsError(try FASTQDerivativeService.fastpTrimOperation(for: request, sourceBundleURL: root)) {
            assertRefusesTheAdapterFASTA($0)
        }
        XCTAssertEqual(
            try FASTQDerivativeService.fastpTrimOperation(
                for: .fastpTrim(threshold: 20, windowSize: 4, mode: .cutRight, adapterMode: .autoDetect, adapterSequence: nil),
                sourceBundleURL: root
            ),
            .combined(threshold: 20, window: 4, mode: .cutRight, adapterTrimming: true, adapterSequence: nil)
        )
        XCTAssertEqual(
            try FASTQDerivativeService.fastpTrimOperation(
                for: .fastpTrim(
                    threshold: 30, windowSize: 5, mode: .cutBoth, adapterMode: .specified, adapterSequence: "AGATCGGAAGAG"
                ),
                sourceBundleURL: root
            ),
            .combined(threshold: 30, window: 5, mode: .cutBoth, adapterTrimming: true, adapterSequence: "AGATCGGAAGAG")
        )
    }

    func testARecipeStepWithAnAdapterFASTAFailsBeforeFastpRuns() async throws {
        let reads = root.appendingPathComponent("reads.fastq")
        try writeReads(to: reads)
        let step = FASTQDerivativeOperation(
            kind: .fastpTrim,
            qualityThreshold: 20,
            windowSize: 4,
            qualityTrimMode: .cutRight,
            adapterMode: .fastaFile,
            adapterFastaFilename: "adapters.fasta"
        )

        do {
            _ = try await serviceWithoutTools().runMaterializedRecipe(
                fastqURL: reads,
                steps: [step],
                isInterleaved: false,
                tempDir: root,
                measureReadCounts: false,
                progress: nil
            )
            XCTFail("the recipe step must not run without its adapters")
        } catch {
            assertRefusesTheAdapterFASTA(error)
        }
    }
}
