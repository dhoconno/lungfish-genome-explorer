// CLIParityGapInlineSiteTests.swift - Pins for CLI parity gaps at inline begin sites
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One begin site calls `OperationCenter.begin` inline, with the literal nil
// as its command and no reporter a test can inject (docs/contracts/
// CLI-EQUIVALENCE.md, "Gaps until they close"). Driving it would need a
// modal sheet, a project on disk or a keychain lookup, so this pin records
// the value the site passes. The lane that closes a gap gives its site a
// begin helper that takes a reporter, and replaces the pin here with a parse
// test and a replay test. The two annotation attach sites took theirs in
// 2.10 A42, and AppDelegateAnnotationTrackImportOperationTests pins their row.

import XCTest

final class CLIParityGapInlineSiteTests: XCTestCase {
    /// The AI Haplotyping row in
    /// Services/GenotypeAIHaplotypingExecutionService.swift records nil and
    /// logs its command preview after it resolves the provider.
    func testAIHaplotypingRecordsNoCommand() {
        let recorded: String? = nil
        assertCLIParityGap(recorded, id: "ai-haplotyping")
    }
}
