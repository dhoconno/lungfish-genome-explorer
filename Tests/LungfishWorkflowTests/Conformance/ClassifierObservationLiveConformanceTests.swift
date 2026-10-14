// ClassifierObservationLiveConformanceTests.swift - The observations of real kraken2, Bracken and EsViritu runs, twice
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane S36 M1, item 3, under owner direction O5 of Phase 2.9. `ClassifierStepObservationTests` checks the
// binding on stand-in tools in the unit tier and stays the default. This class runs each classifier launch twice
// with the managed tools, the Kraken2 Viral database, the installed EsViritu database and the shared SARS-CoV-2
// reads, and compares the `observation` key each record writes, leaf by leaf. Every leaf that differs between the
// two runs is printed as `S36-OBSERVATION-DIFF`, and every leaf of the first run as `S36-OBSERVATION`, for the
// golden normalizer ruling. A leaf that differs fails the test unless a ruled mask names it. The S36 M2 ruling masks none.
//
// Both cases read the configured managed storage. LUNGFISH_STORAGE_ROOT=/Users/Shared/lungfish-golden/storage runs
// the EsViritu case on the golden lock's environment and database, and that root holds no bracken environment, so
// the Kraken2 case runs on the default root. A missing tool or database is a skip. With LUNGFISH_REQUIRE_TOOLS=1
// both are hard failures.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class ClassifierObservationLiveConformanceTests: XCTestCase {

    /// The observation leaves a golden normalizer rule masks. Empty, because the S36 M2 ruling found no leaf that varies.
    private static let ruledMasks: Set<String> = []

    func testTheKraken2AndBrackenObservationsAgreeAcrossTwoRuns() async throws {
        _ = try await ToolAvailability.require("kraken2", environment: "kraken2")
        _ = try await ToolAvailability.require("bracken", environment: "bracken")
        let database = try await ToolAvailability.requireDatabase({ try await ConformanceFixtures.viralKrakenDB() }, name: "Kraken2 Viral")
        let scratch = try ConformanceFixtures.tempDir("classifier-observation-kraken2")
        defer { try? FileManager.default.removeItem(at: scratch) }

        var runs: [[String: [String: String]]] = []
        for run in 1...2 {
            let config = ClassificationConfig(
                goal: .profile,
                inputFiles: [ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz")],
                isPairedEnd: false,
                databaseName: "Viral",
                databasePath: database,
                brackenProfileRequest: .automaticDefault,
                outputDirectory: scratch.appendingPathComponent("run-\(run)", isDirectory: true)
            )
            _ = try await ClassificationPipeline().profile(config: config)
            runs.append(try Self.observations(of: ["kraken2", "bracken"], in: config.outputDirectory))
        }

        try assertAgree(runs, tools: ["kraken2", "bracken"])
    }

    func testTheEsVirituObservationsAgreeAcrossTwoRuns() async throws {
        _ = try await ToolAvailability.require("EsViritu", environment: "esviritu")
        let database = try await ToolAvailability.requireDatabase(
            { await EsVirituDatabaseManager.shared.installedDatabaseInfo()?.path }, name: "EsViritu"
        )
        let scratch = try ConformanceFixtures.tempDir("classifier-observation-esviritu")
        defer { try? FileManager.default.removeItem(at: scratch) }

        var runs: [[String: [String: String]]] = []
        for run in 1...2 {
            let config = EsVirituConfig(
                inputFiles: [ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz")],
                isPairedEnd: false,
                sampleName: "sarscov2",
                outputDirectory: scratch.appendingPathComponent("run-\(run)", isDirectory: true),
                databasePath: database,
                threads: 4,
                readFormat: .unpaired
            )
            _ = try await EsVirituPipeline().detect(config: config)
            runs.append(try Self.observations(of: ["EsViritu"], in: config.outputDirectory))
        }

        try assertAgree(runs, tools: ["EsViritu"])
    }

    // MARK: - Comparing the runs

    private func assertAgree(_ runs: [[String: [String: String]]], tools: [String]) throws {
        XCTAssertEqual(runs.count, 2)
        for tool in tools {
            let first = try XCTUnwrap(runs.first?[tool], "\(tool) records an observation in run 1")
            let second = try XCTUnwrap(runs.last?[tool], "\(tool) records an observation in run 2")
            for path in first.keys.sorted() {
                print("S36-OBSERVATION \(tool) \(path) \(first[path] ?? "")")
            }
            XCTAssertEqual(first["/termination/kind"], "\"exited\"", tool)
            XCTAssertEqual(first["/stage/index"], "0", tool)
            XCTAssertEqual(first["/stage/count"], "1", tool)
            let differing = Set(first.keys).union(second.keys).filter { first[$0] != second[$0] }.sorted()
            for path in differing {
                print("S36-OBSERVATION-DIFF \(tool) \(path) run1=\(first[path] ?? "absent") run2=\(second[path] ?? "absent")")
            }
            XCTAssertEqual(differing.filter { !Self.ruledMasks.contains($0) }, [], "\(tool) observation leaves that differ")
        }
    }

    /// Each named tool's step `observation`, read from the record's bytes and flattened to JSON pointer paths, every
    /// leaf as its JSON text.
    private static func observations(of tools: [String], in directory: URL) throws -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for step in try ClassifierRecordCapture.steps(in: directory) {
            guard let tool = step["toolName"] as? String, tools.contains(tool) else { continue }
            guard let observation = step["observation"] else { continue }
            var leaves: [String: String] = [:]
            flatten(observation, at: "", into: &leaves)
            result[tool] = leaves
        }
        return result
    }

    private static func flatten(_ value: Any, at path: String, into leaves: inout [String: String]) {
        switch value {
        case let object as [String: Any]:
            for (key, member) in object { flatten(member, at: "\(path)/\(key)", into: &leaves) }
        case let array as [Any]:
            for (index, member) in array.enumerated() { flatten(member, at: "\(path)/\(index)", into: &leaves) }
        case let text as String:
            leaves[path] = "\"\(text)\""
        case let number as NSNumber:
            leaves[path] = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        default:
            leaves[path] = "null"
        }
    }
}
