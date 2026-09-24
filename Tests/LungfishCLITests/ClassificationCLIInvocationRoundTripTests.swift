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

    // MARK: - Read format parity (interleaved bundles, 2026-09-24)

    private func makeSingleFileConfig(interleavedInput: Bool) -> ClassificationConfig {
        ClassificationConfig(
            inputFiles: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq/sample.fastq.gz")],
            isPairedEnd: false,
            interleavedInput: interleavedInput,
            databaseName: "Viral",
            databasePath: URL(fileURLWithPath: "/opt/lungfish/db/Viral"),
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
    }

    func testInterleavedInvocationRoundTripsThroughClassifyCommand() throws {
        let invocation = ClassificationCLIInvocationBuilder.build(for: makeSingleFileConfig(interleavedInput: true))
        let parsed = try ClassifyCommand.parse(Array(invocation.arguments.dropFirst(2)))

        XCTAssertEqual(parsed.readFormat, .interleaved)
        XCTAssertFalse(parsed.pairedEnd)
        let resolved = try parsed.resolveReadFormat(inputURLs: parsed.fastqFiles.map { URL(fileURLWithPath: $0) })
        XCTAssertEqual(resolved.format, .interleaved)
        XCTAssertNil(resolved.layout, "An explicit --read-format must not rescan the input")

        let config = try parsed.makeConfigForTesting(
            inputURLs: parsed.fastqFiles.map { URL(fileURLWithPath: $0) },
            databasePath: URL(fileURLWithPath: "/opt/lungfish/db/Viral"),
            inputFormat: .fastq,
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
        XCTAssertEqual(config.readFormat, .interleaved)
        XCTAssertTrue(config.interleavedInput)
        XCTAssertFalse(config.isPairedEnd)
    }

    func testUnpairedInvocationIsNotReDetectedAsInterleaved() throws {
        let invocation = ClassificationCLIInvocationBuilder.build(for: makeSingleFileConfig(interleavedInput: false))
        let parsed = try ClassifyCommand.parse(Array(invocation.arguments.dropFirst(2)))

        XCTAssertEqual(parsed.readFormat, .unpaired)
        XCTAssertEqual(try parsed.resolveReadFormat(inputURLs: [URL(fileURLWithPath: "/tmp/x.fastq")]).format, .unpaired)
    }

    func testPairedFlagConflictsWithOtherReadFormats() throws {
        let parsed = try ClassifyCommand.parse(["--db", "Viral", "--paired", "--read-format", "interleaved", "/tmp/a.fastq"])
        XCTAssertThrowsError(try parsed.resolveReadFormat(inputURLs: [URL(fileURLWithPath: "/tmp/a.fastq")]))

        let compatible = try ClassifyCommand.parse(["--db", "Viral", "--paired", "/tmp/a.fastq", "/tmp/b.fastq"])
        XCTAssertEqual(try compatible.resolveReadFormat(inputURLs: []).format, .paired)
    }

    func testAutoReadFormatClassifiesASingleInputFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("classify-read-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func fastq(_ name: String, _ headers: [String]) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try headers.map { "@\($0)\nACGT\n+\nIIII\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let interleaved = try fastq("interleaved.fastq", ["a/1", "a/2", "b/1", "b/2"])
        let mixed = try fastq("mixed.fastq", ["a/1", "a/2", "merged", "b/1", "b/2"])
        let singleEnd = try fastq("single.fastq", ["a", "b", "c"])

        let parsed = try ClassifyCommand.parse(["--db", "Viral", interleaved.path])
        XCTAssertEqual(parsed.readFormat, .auto)
        XCTAssertEqual(try parsed.resolveReadFormat(inputURLs: [interleaved]).format, .interleaved)
        let mixedResolution = try parsed.resolveReadFormat(inputURLs: [mixed])
        XCTAssertEqual(mixedResolution.format, .unpaired, "Mixed merged reads and pairs run single-end")
        XCTAssertEqual(mixedResolution.layout?.layout, .mixedInterleaved)
        XCTAssertEqual(try parsed.resolveReadFormat(inputURLs: [singleEnd]).format, .unpaired)
        XCTAssertEqual(
            try parsed.resolveReadFormat(inputURLs: [interleaved, singleEnd]).format,
            .unpaired,
            "Several inputs without --paired stay unpaired"
        )
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
