// ClassificationCLIInvocationRoundTripTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

/// P6-B acceptance test: the argv `ClassificationCLIInvocationBuilder` builds
/// for the Operations-panel "Copy CLI command" and for provenance must be the
/// exact argv the real `ClassifyCommand` parser accepts, and its parsed
/// options must round-trip the request's key values (ARC-03: before this
/// builder existed, the GUI's hand-built Kraken2 replay command passed a
/// filesystem path where the CLI expects a registry name, and a user who
/// pasted it got an immediate "Database ... not found in registry" error).
final class ClassificationCLIInvocationRoundTripTests: XCTestCase {
    private func makeConfig(
        goal: ClassificationConfig.Goal = .classify,
        isPairedEnd: Bool = true,
        confidence: Double = 0.35,
        minimumHitGroups: Int = 3,
        brackenProfileRequest: BrackenProfileRequest? = nil
    ) -> ClassificationConfig {
        ClassificationConfig(
            goal: goal,
            inputFiles: [
                URL(fileURLWithPath: "/tmp/reads_R1.fastq.gz"),
                URL(fileURLWithPath: "/tmp/reads_R2.fastq.gz"),
            ],
            isPairedEnd: isPairedEnd,
            databaseName: "Viral",
            databasePath: URL(fileURLWithPath: "/opt/lungfish/db/Viral"),
            brackenProfileRequest: brackenProfileRequest,
            confidence: confidence,
            minimumHitGroups: minimumHitGroups,
            threads: 6,
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
    }

    func testBuiltInvocationParsesThroughClassifyCommand() throws {
        let invocation = ClassificationCLIInvocationBuilder.build(for: makeConfig())
        // The invocation's argv is ["conda", "classify", ...]; ClassifyCommand
        // itself parses only its own subcommand's arguments.
        XCTAssertEqual(Array(invocation.arguments.prefix(2)), ["conda", "classify"])
        let subcommandArguments = Array(invocation.arguments.dropFirst(2))

        let parsed = try ClassifyCommand.parse(subcommandArguments)

        XCTAssertEqual(parsed.databaseName, "Viral")
        XCTAssertEqual(parsed.fastqFiles, ["/tmp/reads_R1.fastq.gz", "/tmp/reads_R2.fastq.gz"])
        XCTAssertTrue(parsed.pairedEnd)
        XCTAssertEqual(parsed.confidence, 0.35)
        XCTAssertEqual(parsed.minHitGroups, 3)
        XCTAssertEqual(parsed.outputDir, "/tmp/out")
        XCTAssertFalse(parsed.profile)
    }

    func testBuiltInvocationForProfileGoalParsesProfileAndBrackenOptions() throws {
        let invocation = ClassificationCLIInvocationBuilder.build(
            for: makeConfig(goal: .profile, brackenProfileRequest: .automaticDefault)
        )
        let subcommandArguments = Array(invocation.arguments.dropFirst(2))

        let parsed = try ClassifyCommand.parse(subcommandArguments)

        XCTAssertTrue(parsed.profile)
        XCTAssertEqual(parsed.brackenReadLength, BrackenProfileRequest.automaticDefault.readLength)
        XCTAssertEqual(parsed.brackenThreshold, BrackenProfileRequest.automaticDefault.threshold)
    }

    /// The whole point of the "Copy CLI command" string is that a user can
    /// paste it into a real shell; verify it parses through the top-level
    /// `lungfish conda classify` path too, not just the subcommand directly.
    func testDisplayStringArgumentsParseThroughTopLevelCLI() throws {
        let invocation = ClassificationCLIInvocationBuilder.build(for: makeConfig())
        let parsed = try LungfishCLI.parseAsRoot(invocation.arguments)
        XCTAssertTrue(parsed is ClassifyCommand)
    }
}
