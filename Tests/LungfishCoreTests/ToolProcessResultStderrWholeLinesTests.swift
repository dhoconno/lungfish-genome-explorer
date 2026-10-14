// ToolProcessResultStderrWholeLinesTests.swift - The stderr of a result as whole lines
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// Phase 2.10 FXS34, SWIFT's ruling R2 on S34. `stderrWholeLines` lives on `ToolProcessResult` in Core, so every
/// adapter that turns a capture into text for a record can call it. The rule itself is
/// `ProvenanceStderr.wholeLines(ofCapture:truncated:)`, pinned in `ProvenanceStderrLineBoundaryTests`.
final class ToolProcessResultStderrWholeLinesTests: XCTestCase {
    private func result(stderr: String, stderrTruncated: Bool) -> ToolProcessResult {
        ToolProcessResult(
            label: "samtools", pid: 1, termination: .exited(code: 0), stop: nil, stdout: Data(),
            stderr: Data(stderr.utf8), stdoutTruncated: false, stderrTruncated: stderrTruncated,
            outputDrainTimedOut: false, outputReadFailed: false, wallTime: .zero
        )
    }

    /// A capture that hit its limit starts with the end of a line, here the folder names of a path without
    /// their root, so its first line goes and the whole lines after it stay.
    func testACaptureThatHitItsLimitDropsItsFirstLine() {
        let capture = "Study.lungfish/Analyses/classify-1/part-1.sorted.bam\n[bam_sort] 2 writing to /p/part-2.bam\n"
        let truncated = result(stderr: capture, stderrTruncated: true)

        XCTAssertEqual(truncated.stderrWholeLines, "[bam_sort] 2 writing to /p/part-2.bam\n")
        XCTAssertEqual(truncated.stderrText, capture, "stderrText still holds everything the capture kept")
    }

    func testACaptureUnderItsLimitComesBackAsItIs() {
        let capture = "[bam_sort] 1 writing to /p/part-1.bam\n[bam_sort] 2 writing to /p/part-2.bam"
        let whole = result(stderr: capture, stderrTruncated: false)

        XCTAssertEqual(whole.stderrWholeLines, capture)
        XCTAssertEqual(whole.stderrWholeLines, whole.stderrText)
    }

    /// A capture with no line break lies inside one line, so nothing of it is whole.
    func testACaptureThatHitItsLimitInsideOneLineKeepsNothing() {
        XCTAssertEqual(result(stderr: String(repeating: "x", count: 4_096), stderrTruncated: true).stderrWholeLines, "")
    }
}
