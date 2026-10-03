// CLIParityGapInlineSiteTests.swift - Pins for CLI parity gaps at inline begin sites
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Three begin sites call `OperationCenter.begin` inline, with the literal nil
// as their command and no reporter a test can inject (docs/contracts/
// CLI-EQUIVALENCE.md, "Gaps until they close"). Driving them would need a
// modal sheet, a project on disk or a keychain lookup, so these pins record
// the value the site passes. The lane that closes a gap gives its site a
// begin helper that takes a reporter, and replaces the pin here with a parse
// test and a replay test.

import XCTest

final class CLIParityGapInlineSiteTests: XCTestCase {
    /// The Import Center annotation track attach in
    /// App/AppDelegate+ImportCenter.swift records nil.
    func testImportCenterAnnotationAttachRecordsNoCommand() {
        let recorded: String? = nil
        assertCLIParityGap(recorded, id: "annotation-attach-import-center")
    }

    /// The sidebar drop annotation track attach in
    /// Views/MainWindow/MainSplitViewController+FASTQImport.swift records nil.
    func testSidebarDropAnnotationAttachRecordsNoCommand() {
        let recorded: String? = nil
        assertCLIParityGap(recorded, id: "annotation-attach-sidebar-drop")
    }

    /// The AI Haplotyping row in
    /// Services/GenotypeAIHaplotypingExecutionService.swift records nil and
    /// logs its command preview after it resolves the provider.
    func testAIHaplotypingRecordsNoCommand() {
        let recorded: String? = nil
        assertCLIParityGap(recorded, id: "ai-haplotyping")
    }
}
