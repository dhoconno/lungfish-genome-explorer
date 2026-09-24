// BrackenScratchStagingTests.swift - Bracken runs from a whitespace-free scratch directory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// The conda `bracken` launcher expands `${INPUT}`, `${OUTPUT}` and
/// `$DATABASE` unquoted (`if [ -f ${INPUT} ]`), so a project path with a
/// space made every Bracken profile fail with "Input file ... does not
/// exist". The pipeline now stages the run in a whitespace-free scratch
/// directory and moves the outputs back.
final class BrackenScratchStagingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrackenScratchStagingTests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeConfig(outputDirectory: URL, databasePath: URL) -> ClassificationConfig {
        ClassificationConfig(
            goal: .profile,
            inputFiles: [outputDirectory.deletingLastPathComponent().appendingPathComponent("reads.fastq.gz")],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: databasePath,
            brackenProfileRequest: .automaticDefault,
            outputDirectory: outputDirectory
        )
    }

    private func hasWhitespace(_ argv: [String]) -> [String] {
        argv.filter { BrackenScratchStaging.hasWhitespace($0) }
    }

    // MARK: - Argv

    func testBrackenArgvCarriesNoWhitespacePathsWhenProjectAndDatabasePathsHaveSpaces() {
        let outputDirectory = URL(fileURLWithPath: "/Users/me/My Genome Project.lungfish/classification-abc", isDirectory: true)
        let databasePath = URL(fileURLWithPath: "/Volumes/Big Disk/kraken dbs/Viral", isDirectory: true)
        let distribution = databasePath.appendingPathComponent("database150mers.kmer_distrib")
        let config = makeConfig(outputDirectory: outputDirectory, databasePath: databasePath)
        let scratchRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)

        let staging = BrackenScratchStaging.plan(config: config, distributionURL: distribution, scratchRoot: scratchRoot)

        XCTAssertTrue(staging.scratchDirectory.path.hasPrefix("/private/tmp/lungfish-bracken-"))
        XCTAssertEqual(hasWhitespace(staging.stagedPaths.map(\.path)), [], "Every staged path must be whitespace-free")
        XCTAssertEqual(staging.stagedDatabasePath, staging.scratchDirectory.appendingPathComponent("db", isDirectory: true))
        XCTAssertEqual(
            staging.stagedDistributionURL,
            staging.stagedDatabasePath.appendingPathComponent("database150mers.kmer_distrib"),
            "A distribution inside the database is reached through the database symlink"
        )
        XCTAssertEqual(staging.finalOutputURL, config.brackenURL)
        XCTAssertEqual(staging.finalReportOutputURL, config.brackenReportURL)

        for dialect in [BrackenCLIDialect.database, .kmerDistribution] {
            let argv = BrackenInvocation.arguments(
                dialect: dialect,
                databasePath: staging.stagedDatabasePath,
                distributionURL: staging.stagedDistributionURL,
                reportURL: staging.stagedReportURL,
                outputURL: staging.stagedOutputURL,
                reportOutputURL: staging.stagedReportOutputURL,
                readLength: 150,
                levelCode: "S",
                threshold: 10
            )
            XCTAssertEqual(hasWhitespace(argv), [], "\(dialect): \(argv)")
        }
    }

    func testCleanPathsAreNotSymlinked() {
        let config = makeConfig(
            outputDirectory: URL(fileURLWithPath: "/data/project.lungfish/classification", isDirectory: true),
            databasePath: URL(fileURLWithPath: "/opt/lungfish/db/Viral", isDirectory: true)
        )
        let distribution = URL(fileURLWithPath: "/opt/lungfish/db/Viral/database100mers.kmer_distrib")

        let staging = BrackenScratchStaging.plan(config: config, distributionURL: distribution, scratchRoot: URL(fileURLWithPath: "/tmp"))

        XCTAssertEqual(staging.stagedDatabasePath, config.databasePath)
        XCTAssertEqual(staging.stagedDistributionURL, distribution)
        // The report and outputs are always staged so the launcher sees one layout.
        XCTAssertEqual(staging.stagedReportURL.deletingLastPathComponent(), staging.scratchDirectory)
        XCTAssertEqual(staging.stagedOutputURL.lastPathComponent, "classification.bracken")
        XCTAssertEqual(staging.stagedReportOutputURL.lastPathComponent, "classification.bracken.kreport")
    }

    func testDefaultScratchRootHasNoWhitespace() {
        XCTAssertFalse(BrackenScratchStaging.hasWhitespace(BrackenScratchStaging.defaultScratchRoot().path))
    }

    // MARK: - Filesystem round trip

    func testPrepareCollectAndCleanUpRoundTripThroughSpacedPaths() throws {
        let fm = FileManager.default
        let project = root.appendingPathComponent("My Genome Project.lungfish", isDirectory: true)
        let outputDirectory = project.appendingPathComponent("classification-abc", isDirectory: true)
        let databasePath = root.appendingPathComponent("kraken dbs", isDirectory: true).appendingPathComponent("Viral", isDirectory: true)
        let distribution = databasePath.appendingPathComponent("database150mers.kmer_distrib")
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: databasePath, withIntermediateDirectories: true)
        try "distrib".write(to: distribution, atomically: true, encoding: .utf8)
        let config = makeConfig(outputDirectory: outputDirectory, databasePath: databasePath)
        try "kreport".write(to: config.reportURL, atomically: true, encoding: .utf8)
        try "stale".write(to: config.brackenURL, atomically: true, encoding: .utf8)
        let scratchRoot = root.appendingPathComponent("scratch", isDirectory: true)
        try fm.createDirectory(at: scratchRoot, withIntermediateDirectories: true)

        let staging = BrackenScratchStaging.plan(config: config, distributionURL: distribution, scratchRoot: scratchRoot)
        try staging.prepare()

        XCTAssertEqual(try String(contentsOf: staging.stagedReportURL, encoding: .utf8), "kreport")
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: staging.stagedDatabasePath.path),
            databasePath.path,
            "Database with whitespace is reached through a symlink"
        )
        XCTAssertEqual(
            try String(contentsOf: staging.stagedDistributionURL, encoding: .utf8),
            "distrib",
            "The distribution resolves through the database symlink"
        )

        // Simulate Bracken writing into the scratch directory.
        try "abundance".write(to: staging.stagedOutputURL, atomically: true, encoding: .utf8)
        try "report".write(to: staging.stagedReportOutputURL, atomically: true, encoding: .utf8)
        try staging.collectOutputs()

        XCTAssertEqual(try String(contentsOf: config.brackenURL, encoding: .utf8), "abundance", "Stale output is replaced")
        XCTAssertEqual(try String(contentsOf: config.brackenReportURL, encoding: .utf8), "report")
        XCTAssertFalse(fm.fileExists(atPath: staging.stagedOutputURL.path), "Outputs are moved, not copied")

        staging.cleanUp()
        XCTAssertFalse(fm.fileExists(atPath: staging.scratchDirectory.path))
        XCTAssertTrue(fm.fileExists(atPath: distribution.path), "Removing the symlink must not touch the database")
        XCTAssertTrue(fm.fileExists(atPath: config.reportURL.path))
    }

    func testCollectOutputsLeavesMissingOutputsForValidation() throws {
        let fm = FileManager.default
        let outputDirectory = root.appendingPathComponent("out dir", isDirectory: true)
        let databasePath = root.appendingPathComponent("db", isDirectory: true)
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: databasePath, withIntermediateDirectories: true)
        let config = makeConfig(outputDirectory: outputDirectory, databasePath: databasePath)
        try "kreport".write(to: config.reportURL, atomically: true, encoding: .utf8)
        let staging = BrackenScratchStaging.plan(
            config: config,
            distributionURL: databasePath.appendingPathComponent("database150mers.kmer_distrib"),
            scratchRoot: root
        )
        defer { staging.cleanUp() }
        try staging.prepare()

        XCTAssertNoThrow(try staging.collectOutputs())
        XCTAssertFalse(fm.fileExists(atPath: config.brackenURL.path))
    }
}
