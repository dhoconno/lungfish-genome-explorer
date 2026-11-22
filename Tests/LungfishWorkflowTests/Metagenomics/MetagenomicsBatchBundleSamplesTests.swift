// MetagenomicsBatchBundleSamplesTests.swift - kraken2 classify --batch and esviritu detect --batch plan one sample per bundle and pair loose mates within one folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

/// BIO ruling BIO-TT-PAIR, question 3 and action item 6. `kraken2 classify --batch` and
/// `esviritu detect --batch` group their inputs through `MetagenomicsSampleGrouper`, which read the
/// bundles `S_1` and `S_2` as the R1 and R2 of one sample named `S`. Each bundle is one sample now.
final class MetagenomicsBatchBundleSamplesTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "batch-bundle-samples").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// A single-end `.lungfishfastq` bundle named `stem` that holds three reads.
    private func bundle(_ stem: String) throws -> URL {
        let url = root.appendingPathComponent("\(stem).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try ReadSetFixtures.fastq(["\(stem)-a", "\(stem)-b", "\(stem)-c"])
            .write(to: url.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        return url
    }

    func testKraken2BatchPlansTwoSamplesForBundlesNamedLikeMates() throws {
        let first = try bundle("S_1")
        let second = try bundle("S_2")
        let request = Kraken2RunRequest(inputArguments: [first.path, second.path], databaseName: "Viral", threads: 1)

        let samples = try Kraken2AnalysisRunTool.samples(of: [first, second], request: request, batch: true)

        XCTAssertEqual(samples.map(\.label), ["S_1", "S_2"])
        XCTAssertEqual(samples.map { $0.inputURLs.map(\.path) }, [[first.path], [second.path]])
        XCTAssertEqual(samples.map(\.request.pairedEnd), [false, false])
    }

    func testEsVirituBatchPlansTwoSamplesForBundlesNamedLikeMates() async throws {
        let first = try bundle("S_1")
        let second = try bundle("S_2")
        let database = root.appendingPathComponent("esviritu-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let tool = EsVirituAnalysisRunTool(
            options: EsVirituAnalysisRunOptions(sampleName: nil, databasePath: database, threads: 1),
            groupsSamples: true,
            materializer: FASTQCLIMaterializer(runner: .shared),
            installedDatabase: { nil }
        )

        let plan = try await tool.plan(
            AnalysisRunRequest(
                inputs: [first, second],
                destination: .directory(root.appendingPathComponent("out", isDirectory: true)),
                groupsSamples: true,
                commandLine: ["lungfish-cli", "esviritu", "detect", "--batch"]
            ),
            context: AnalysisRunPlanningContext(projectURL: nil)
        )

        XCTAssertEqual(plan.units.map(\.label), ["S_1", "S_2"])
        XCTAssertEqual(plan.units.map { $0.value.inputs.map(\.path) }, [[first.path], [second.path]])
    }

    /// A loose FASTQ file `folder/name` that holds three reads. The reads are named by folder only, so the R1 and
    /// R2 files of one folder are mates by name (LOOSE-PAIR-OUT-OF-STEP).
    private func looseFile(_ folder: String, _ name: String) throws -> URL {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try ReadSetFixtures.fastq(["\(folder)-a", "\(folder)-b", "\(folder)-c"])
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// GROUPER-CROSS-FOLDER-PAIR: `--batch a/S_R1 b/S_R1 b/S_R2 a/S_R2` names the folders in one order for
    /// the R1 files and in another for the R2 files. Each sample takes both mates from one folder.
    private func mixedFolderList() throws -> [URL] {
        [
            try looseFile("a", "S_R1.fastq"), try looseFile("b", "S_R1.fastq"),
            try looseFile("b", "S_R2.fastq"), try looseFile("a", "S_R2.fastq"),
        ]
    }

    private func folderPairPaths() -> [[String]] {
        ["a", "b"].map { folder in
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            return [directory.appendingPathComponent("S_R1.fastq").path, directory.appendingPathComponent("S_R2.fastq").path]
        }
    }

    func testKraken2BatchPairsLooseMatesWithinEachFolder() throws {
        let files = try mixedFolderList()
        let request = Kraken2RunRequest(inputArguments: files.map(\.path), databaseName: "Viral", threads: 1)

        let samples = try Kraken2AnalysisRunTool.samples(of: files, request: request, batch: true)

        XCTAssertEqual(samples.map(\.label), ["S_1", "S_2"])
        XCTAssertEqual(samples.map { $0.inputURLs.map(\.path) }, folderPairPaths())
        XCTAssertEqual(samples.map(\.request.inputArguments), folderPairPaths())
        XCTAssertEqual(samples.map(\.request.pairedEnd), [true, true])
    }

    func testEsVirituBatchPairsLooseMatesWithinEachFolder() async throws {
        let files = try mixedFolderList()
        let database = root.appendingPathComponent("esviritu-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let tool = EsVirituAnalysisRunTool(
            options: EsVirituAnalysisRunOptions(sampleName: nil, databasePath: database, threads: 1),
            groupsSamples: true,
            materializer: FASTQCLIMaterializer(runner: .shared),
            installedDatabase: { nil }
        )

        let plan = try await tool.plan(
            AnalysisRunRequest(
                inputs: files,
                destination: .directory(root.appendingPathComponent("out", isDirectory: true)),
                groupsSamples: true,
                commandLine: ["lungfish-cli", "esviritu", "detect", "--batch"]
            ),
            context: AnalysisRunPlanningContext(projectURL: nil)
        )

        XCTAssertEqual(plan.units.map(\.label), ["S_1", "S_2"])
        XCTAssertEqual(plan.units.map { $0.value.inputs.map(\.path) }, folderPairPaths())
    }
}
