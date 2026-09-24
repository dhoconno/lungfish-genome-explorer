// ClassificationCLIInvocationBuilderTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class ClassificationCLIInvocationBuilderTests: XCTestCase {
    private func makeConfig(
        goal: ClassificationConfig.Goal = .classify,
        isPairedEnd: Bool = false,
        confidence: Double = 0.2,
        minimumHitGroups: Int = 2,
        brackenProfileRequest: BrackenProfileRequest? = nil
    ) -> ClassificationConfig {
        ClassificationConfig(
            goal: goal,
            inputFiles: [URL(fileURLWithPath: "/tmp/reads.fastq.gz")],
            isPairedEnd: isPairedEnd,
            databaseName: "Viral",
            databasePath: URL(fileURLWithPath: "/opt/lungfish/db/Viral"),
            brackenProfileRequest: brackenProfileRequest,
            confidence: confidence,
            minimumHitGroups: minimumHitGroups,
            threads: 4,
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
    }

    /// ARC-03: the GUI's old hand-built display command passed `--db
    /// <databasePath.path>`, but the CLI's `--db` is resolved as a registry
    /// *name*. The builder must use the name, not the path.
    func testBuildUsesRegistryNameNotFilesystemPathForDB() {
        let invocation = ClassificationCLIInvocationBuilder.build(for: makeConfig())
        XCTAssertTrue(invocation.arguments.contains("Viral"))
        XCTAssertFalse(invocation.arguments.contains("/opt/lungfish/db/Viral"))
    }

    func testBuildIncludesConfidenceMinHitGroupsAndOutputDir() {
        let invocation = ClassificationCLIInvocationBuilder.build(
            for: makeConfig(confidence: 0.5, minimumHitGroups: 3)
        )
        XCTAssertTrue(invocation.arguments.containsSequence(["--confidence", "0.5"]))
        XCTAssertTrue(invocation.arguments.containsSequence(["--min-hit-groups", "3"]))
        XCTAssertTrue(invocation.arguments.containsSequence(["--output-dir", "/tmp/out"]))
    }

    func testBuildIncludesPairedFlagWhenPairedEnd() {
        let invocation = ClassificationCLIInvocationBuilder.build(for: makeConfig(isPairedEnd: true))
        XCTAssertTrue(invocation.arguments.contains("--paired"))
    }

    func testBuildIncludesProfileFlagAndBrackenOptionsForProfileGoal() {
        let invocation = ClassificationCLIInvocationBuilder.build(
            for: makeConfig(goal: .profile, brackenProfileRequest: .automaticDefault)
        )
        XCTAssertTrue(invocation.arguments.contains("--profile"))
        XCTAssertTrue(invocation.arguments.contains("--bracken-read-length"))
        XCTAssertTrue(invocation.arguments.contains("--bracken-threshold"))
    }

    func testDisplayStringIsShellQuotedAndPrefixedWithLungfish() {
        let invocation = ClassificationCLIInvocationBuilder.build(for: makeConfig())
        XCTAssertTrue(invocation.displayString.hasPrefix("lungfish conda classify"))
    }

    /// P6-B: the same argv is what would be executed and what is recorded to
    /// provenance -- no separate encoding.
    func testExecutedArgumentsEqualsProvenanceArguments() {
        let invocation = ClassificationCLIInvocationBuilder.build(for: makeConfig())
        XCTAssertEqual(invocation.executedArguments, invocation.provenanceArguments)
    }
}

private extension Array where Element == String {
    func containsSequence(_ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= count else { return false }
        return indices.contains { index in
            let end = self.index(index, offsetBy: sequence.count, limitedBy: endIndex)
            guard let end else { return false }
            return Array(self[index..<end]) == sequence
        }
    }
}
