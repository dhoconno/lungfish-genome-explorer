// AssemblyInterleavedPairingTests.swift - The app passes a resolved read layout to lungfish-cli assemble
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The wizard cannot be click-tested here; these cover the pieces it is
// built from: the CLI invocation the app runs and the read-layout caption.

import Foundation
import LungfishIO
import LungfishWorkflow
import XCTest
@testable import LungfishApp

final class AssemblyInterleavedPairingTests: XCTestCase {
    private func request(inputLayout: FASTQInputLayout?, pairedEnd: Bool = false, inputURLs: [URL]? = nil) -> AssemblyRunRequest {
        AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: inputURLs ?? [URL(fileURLWithPath: "/tmp/hg002.lungfishfastq/hg002.fastq")],
            projectName: "hg002",
            outputDirectory: URL(fileURLWithPath: "/tmp/assembly-out"),
            pairedEnd: pairedEnd,
            threads: 4,
            inputLayout: inputLayout
        )
    }

    func testInvocationPassesAResolvedLayoutAndLeavesAutoOtherwise() throws {
        XCTAssertEqual(FASTQOperationCLIInvocationBuilder.assembleReadLayoutArgument(for: request(inputLayout: .strictlyInterleaved)), "interleaved")
        XCTAssertEqual(FASTQOperationCLIInvocationBuilder.assembleReadLayoutArgument(for: request(inputLayout: .mixedMergedAndPairs)), "mixed")
        XCTAssertEqual(FASTQOperationCLIInvocationBuilder.assembleReadLayoutArgument(for: request(inputLayout: .singleEnd)), "single-end")
        XCTAssertNil(FASTQOperationCLIInvocationBuilder.assembleReadLayoutArgument(for: request(inputLayout: nil)))
        XCTAssertNil(FASTQOperationCLIInvocationBuilder.assembleReadLayoutArgument(for: request(
            inputLayout: .strictlyInterleaved,
            pairedEnd: true,
            inputURLs: [URL(fileURLWithPath: "/tmp/R1.fastq"), URL(fileURLWithPath: "/tmp/R2.fastq")]
        )))

        let invocation = try FASTQOperationExecutionService().buildInvocation(
            for: .assemble(request: request(inputLayout: .strictlyInterleaved), outputMode: .groupedResult)
        )
        XCTAssertEqual(invocation.subcommand, "assemble")
        XCTAssertEqual(Array(invocation.arguments.prefix(3)), [
            "/tmp/hg002.lungfishfastq/hg002.fastq", "--read-layout", "interleaved",
        ])
        XCTAssertFalse(invocation.arguments.contains("--paired"))

        let auto = try FASTQOperationExecutionService().buildInvocation(
            for: .assemble(request: request(inputLayout: nil), outputMode: .groupedResult)
        )
        XCTAssertFalse(auto.arguments.contains("--read-layout"))
    }

    func testReadLayoutCaptionNamesAnInterleavedBundle() {
        let empty: (forward: [URL], reverse: [URL], unpaired: [URL]) = ([], [], [URL(fileURLWithPath: "/tmp/a.lungfishfastq")])
        XCTAssertEqual(
            AssemblyWizardSheet.readLayoutSummary(readType: .illuminaShortReads, pairedEndInfo: empty, recordedPairingModes: [.interleaved]),
            "Interleaved paired-end Illumina reads (pairs verified against the records at run time)"
        )
        XCTAssertEqual(
            AssemblyWizardSheet.readLayoutSummary(readType: .illuminaShortReads, pairedEndInfo: empty, recordedPairingModes: [.singleEnd]),
            "Single-end or pre-grouped Illumina reads"
        )
        XCTAssertEqual(
            AssemblyWizardSheet.readLayoutSummary(readType: .illuminaShortReads, pairedEndInfo: empty, recordedPairingModes: [.interleaved, .interleaved]),
            "Single-end or pre-grouped Illumina reads"
        )
        XCTAssertEqual(
            AssemblyWizardSheet.readLayoutSummary(readType: .ontReads, pairedEndInfo: empty, recordedPairingModes: [.interleaved]),
            "Single-input long-read assembly"
        )
        let pair: (forward: [URL], reverse: [URL], unpaired: [URL]) = (
            [URL(fileURLWithPath: "/tmp/a_R1.fastq")], [URL(fileURLWithPath: "/tmp/a_R2.fastq")], []
        )
        XCTAssertEqual(
            AssemblyWizardSheet.readLayoutSummary(readType: .illuminaShortReads, pairedEndInfo: pair, recordedPairingModes: [nil, nil]),
            "Paired-end Illumina reads"
        )
    }
}
