// BrackenThresholdPreflightLiveConformanceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane B15 (row 255 of the Phase 2.8 plan, owner direction O5). The preflight before
// Bracken takes its count, comparison and rank from the managed Bracken's own check in
// est_abundance.py, so these tests run the managed Bracken on small Kraken2 reports and hold
// what it does to the tool's answer. The stand-in class `BrackenThresholdPreflightTests` runs in
// the unit tier and keeps every case. This class is the live form of the same cases.
//
// A missing tool or database is a skip. With LUNGFISH_REQUIRE_TOOLS=1 both are hard failures.
// Bracken runs on a report of a few lines, so no network, no Docker and no Kraken2 run is needed.

import XCTest
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

final class BrackenThresholdPreflightLiveConformanceTests: XCTestCase {

    /// The threshold the pipeline passes to Bracken unless a caller asks for another.
    static let threshold = BrackenProfileRequest.automaticDefault.threshold

    /// What est_abundance.py prints before it exits 1, when it keeps no taxon at the level.
    static let noReadsLine = "Error: no reads found. Please check your Kraken report"

    /// One Kraken2 report and what the managed Bracken does with it at the default threshold.
    struct Case {
        let name: String
        let report: String
        /// Bracken keeps a taxon at species level, so it exits 0 and writes a row for it.
        let kept: Bool
        /// The reads Bracken assigns to the kept species row.
        let keptReads: Int?
    }

    /// The cases of row 255. The first three are the threshold minus one read, at it and plus one,
    /// each on a species whose reads all sit on its own row. The fourth shows the count is the
    /// clade count, the reads of the taxon and everything below it. The fifth shows the rank is the
    /// resolved one alone, because a genus above the species holds 25 reads and counts for nothing.
    static let cases: [Case] = [
        Case(name: "one read below the threshold", report: report(species: threshold - 1), kept: false, keptReads: nil),
        Case(name: "at the threshold", report: report(species: threshold), kept: true, keptReads: threshold),
        Case(name: "one read above the threshold", report: report(species: threshold + 1), kept: true, keptReads: threshold + 1),
        Case(name: "a species whose reads sit on a strain below it", report: report(species: threshold, direct: 4), kept: true, keptReads: threshold),
        Case(name: "a genus above a species below the threshold", report: report(species: threshold - 1, genus: 25), kept: false, keptReads: nil),
    ]

    func testManagedBrackenKeepsATaxonAtTheThresholdAndDropsOneBelowIt() async throws {
        let live = try await LiveBracken.make()

        for testCase in Self.cases {
            let outcome = try live.run(report: testCase.report, threshold: Self.threshold)
            if testCase.kept {
                XCTAssertEqual(outcome.status, 0, "\(testCase.name): \(outcome.stderr)")
                let row = outcome.rows.first { $0.taxonomyLevel == "S" }
                XCTAssertEqual(outcome.rows.count, 1, testCase.name)
                XCTAssertEqual(row?.krakenAssignedReads, testCase.keptReads, testCase.name)
                XCTAssertEqual(row?.newEstReads, testCase.keptReads, testCase.name)
            } else {
                XCTAssertEqual(outcome.status, 1, "\(testCase.name): \(outcome.stderr)")
                XCTAssertTrue(outcome.stderr.contains(Self.noReadsLine), "\(testCase.name): \(outcome.stderr)")
                XCTAssertTrue(outcome.rows.isEmpty, testCase.name)
            }
        }
    }

    /// The preflight decides as the managed Bracken does, on the same bytes, for every case. Bracken
    /// exits 0 exactly when the preflight passes, and when Bracken finds no reads the preflight
    /// degrades with `belowThreshold`.
    func testThePreflightDecidesAsTheManagedBrackenDoes() async throws {
        let live = try await LiveBracken.make()
        let resolution = BrackenDatabaseCapabilities.resolve(
            catalogID: nil, installationRecipe: nil, request: .automaticDefault
        )
        XCTAssertEqual(resolution.rank, .species)
        XCTAssertEqual(resolution.threshold, Self.threshold)

        for testCase in Self.cases {
            let outcome = try live.run(report: testCase.report, threshold: Self.threshold)
            let tree = try KreportParser.parse(text: testCase.report)
            let failure = BrackenReportCheck.failure(in: tree, resolution: resolution)
            XCTAssertEqual(
                failure == nil, outcome.status == 0,
                "\(testCase.name): the preflight \(failure?.1 ?? "passes") and Bracken exited \(outcome.status)"
            )
            XCTAssertEqual(outcome.status == 0, testCase.kept, testCase.name)
            if outcome.status != 0 {
                XCTAssertEqual(failure?.0, .belowThreshold, testCase.name)
            }
        }
    }

    // MARK: - Reports

    /// A Kraken2 report of one viral species at rank S. `species` is its clade count and `direct`
    /// the reads placed on its own row. The rest sit on a strain row (rank S1) below it. A genus
    /// row above it holds `genus` reads when given. An unclassified line comes first, as
    /// Kraken2 writes it, so the installed est_abundance.py never meets a report without one.
    static func report(species: Int, direct: Int? = nil, genus: Int? = nil) -> String {
        let unclassified = 5
        let direct = direct ?? species
        let classified = max(species, genus ?? 0)
        let total = classified + unclassified
        func line(_ clade: Int, _ own: Int, _ rank: String, _ taxID: Int, _ depth: Int, _ name: String) -> String {
            let percent = String(format: "%6.2f", Double(clade) / Double(total) * 100)
            return "\(percent)\t\(clade)\t\(own)\t\(rank)\t\(taxID)\t\(String(repeating: " ", count: depth * 2))\(name)"
        }
        var lines = [
            line(unclassified, unclassified, "U", 0, 0, "unclassified"),
            line(classified, 0, "R", 1, 0, "root"),
            line(classified, 0, "D", 10239, 1, "Viruses"),
        ]
        var depth = 2
        if let genus {
            lines.append(line(genus, genus - species, "G", 694002, depth, "Betacoronavirus"))
            depth += 1
        }
        lines.append(line(species, direct, "S", 3418604, depth, "Betacoronavirus pandemicum"))
        if species > direct {
            lines.append(line(species - direct, species - direct, "S1", 2697049, depth + 1, "Severe acute respiratory syndrome coronavirus 2"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - The managed tool

    /// The managed Bracken, the installed Viral database that holds its kmer distribution, and the
    /// command line the pipeline builds for them.
    struct LiveBracken {
        let bracken: URL
        let database: URL
        let dialect: BrackenCLIDialect
        let distribution: URL

        struct Outcome {
            let status: Int32
            let stderr: String
            let rows: [BrackenRow]
        }

        static func make() async throws -> LiveBracken {
            let bracken = try await ToolAvailability.require("bracken", environment: "bracken")
            let database = try await ToolAvailability.requireDatabase(
                { try await ConformanceFixtures.viralKrakenDB() }, name: "Kraken2 Viral"
            )
            let dialect = await ClassificationPipeline.shared.detectBrackenDialect(environment: "bracken")
            let distribution = try BrackenInvocation.resolveKmerDistribution(
                databasePath: database,
                readLength: 150,
                availableFilenames: BrackenInvocation.availableDistributionFilenames(inDatabase: database)
            )
            return LiveBracken(bracken: bracken, database: database, dialect: dialect, distribution: distribution.url)
        }

        /// Runs the managed Bracken at species level on `report`, as the pipeline would.
        func run(report: String, threshold: Int) throws -> Outcome {
            let folder = try ConformanceFixtures.tempDir("bracken-threshold")
            defer { try? FileManager.default.removeItem(at: folder) }
            let reportURL = folder.appendingPathComponent("reads.kreport")
            try report.write(to: reportURL, atomically: true, encoding: .utf8)
            let outputURL = folder.appendingPathComponent("reads.bracken")
            let arguments = BrackenInvocation.arguments(
                dialect: dialect,
                databasePath: database,
                distributionURL: distribution,
                reportURL: reportURL,
                outputURL: outputURL,
                reportOutputURL: folder.appendingPathComponent("reads.bracken.kreport"),
                readLength: 150,
                levelCode: "S",
                threshold: threshold
            )
            let result = try ProcessRunner.run(bracken, arguments, timeout: 300)
            let rows = result.status == 0 && FileManager.default.fileExists(atPath: outputURL.path)
                ? try BrackenParser.parse(url: outputURL)
                : []
            return Outcome(status: result.status, stderr: result.stderr, rows: rows)
        }
    }
}
