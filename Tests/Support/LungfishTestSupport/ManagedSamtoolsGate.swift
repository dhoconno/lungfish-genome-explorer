// ManagedSamtoolsGate.swift - The skip of a test that imports NAO-MGS on a host with no managed samtools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO

/// A NAO-MGS import writes the BAM of each sample with the managed samtools and stops with words when there is none
/// (NAO-IMPORT-BAM-FAILED-SILENT), so a test that runs the whole import needs that samtools on its host. A host
/// without it shows a skip that says so, never a pass. The words of the stop are tested with a stand-in samtools in
/// `NaoMgsImportBamWordsTests`, which needs no managed tool.
public enum ManagedSamtoolsGate {
    /// True when `SamtoolsLocator` finds the managed samtools, the one the NAO-MGS import writes its BAM with.
    public static var isAvailable: Bool { SamtoolsLocator.locate() != nil }

    /// What a skipped test shows.
    public static let skipReason = "No managed samtools on this host, so a NAO-MGS import stops with its samtools words "
        + "and cannot finish. Install the app's tools to run this test."

    /// The Swift Testing trait of a test that imports NAO-MGS, as in `@Test(ManagedSamtoolsGate.enabled)`.
    public static var enabled: ConditionTrait {
        .enabled(if: isAvailable, Comment(rawValue: skipReason))
    }

    /// The XCTest gate of a test that imports NAO-MGS. It skips with ``skipReason`` (a failure under
    /// `LUNGFISH_REQUIRE_TOOLS=1`, as `ToolAvailability` has it).
    public static func requireForXCTest(file: StaticString = #filePath, line: UInt = #line) throws {
        guard isAvailable else {
            try ToolAvailability.skipOrFail(skipReason, file: file, line: line)
        }
    }
}
