// TaxTriagePipelineSourceTests.swift - Where the code of a TaxTriage launch comes from, by the Nextflow home it finds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane B11, milestone M2. A TaxTriage run launches LGE's snapshot of the revision when Nextflow's cached
// checkout of `jhuapl-bio/taxtriage` can give it, else the repository at the revision with `-r`, and its step records
// which as `pipelineSource` (decision T6). Nextflow 26 keeps its assets in another layout, which the cache lookup does
// not read, so a home that only Nextflow 26 filled launches the repository today. Decision T7 pins that and moves the
// fix out of Phase 2.9.

import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriagePipelineSourceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-pipeline-source")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Helpers

    /// Runs git with `arguments` in `directory` and returns what it printed, throwing when it exits non-zero.
    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.email=lane@example.com", "-c", "user.name=Lane"] + arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TaxTriagePipelineSourceTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(text)",
            ])
        }
        return text
    }

    /// A repository at `url` with one commit that holds a workflow file, and that commit.
    private func makeRepository(at url: URL) throws -> String {
        let workflows = url.appendingPathComponent("workflows", isDirectory: true)
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        try "workflow TAXTRIAGE {}\n".write(
            to: workflows.appendingPathComponent("taxtriage.nf"),
            atomically: true,
            encoding: .utf8
        )
        try git(["init", "--initial-branch=main"], in: url)
        try git(["add", "."], in: url)
        try git(["commit", "-m", "Initial"], in: url)
        return try git(["rev-parse", "HEAD"], in: url).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - T6, the source names the branch

    /// T6. A home with no cached checkout launches the repository at the revision with `-r`, which the step records as
    /// `remote`, and a launch of the export folder without `-r` is LGE's snapshot.
    func testTheSourceNamesTheBranchThatLaunches() async throws {
        let home = try XCTUnwrap(root)
        let pipeline = TaxTriagePipeline(homeDirectoryProvider: { home })

        let prepared = try await pipeline.preparePipelineProjectSource(forRevision: TaxTriageConfig.defaultRevision)

        XCTAssertEqual(prepared.launchTarget, TaxTriageConfig.pipelineRepository)
        XCTAssertEqual(prepared.revision, TaxTriageConfig.defaultRevision)
        XCTAssertEqual(prepared.pipelineSource, .remote)
        let snapshot = TaxTriagePipeline.PreparedPipelineProjectSource(
            launchTarget: home.appendingPathComponent("out/workflow-source/taxtriage").path,
            revision: nil,
            cleanupDirectory: nil,
            snapshotDirectory: nil
        )
        XCTAssertEqual(snapshot.pipelineSource, .snapshot)
    }

    // MARK: - T7, a home that only Nextflow 26 filled

    /// T7, today's gap, whose fix moves out of 2.9. Nextflow 26 keeps a pipeline as a bare repository under
    /// `assets/.repos/<org>/<name>/bare` with a checkout per commit under `clones/`, as the Debug Nextflow home of the
    /// phase's Mac holds TaxTriage's (QA inventory). The cache lookup reads only `assets/jhuapl-bio/taxtriage/.git`
    /// (`TaxTriagePipeline.cachedTaxTriageRepositoryURL`), so although that cache holds the revision, the launch takes
    /// the repository with `-r`, writes no snapshot into the result and records `remote`.
    func testAHomeThatOnlyNextflow26FilledLaunchesTheRepositoryToday() async throws {
        let home = try XCTUnwrap(root)
        let source = home.appendingPathComponent("source", isDirectory: true)
        let revision = try makeRepository(at: source)
        let assets = LungfishAppIdentity.current.nextflowHomeURL(homeDirectory: home)
            .appendingPathComponent("assets", isDirectory: true)
        let repos = assets.appendingPathComponent(".repos/jhuapl-bio/taxtriage", isDirectory: true)
        try FileManager.default.createDirectory(at: repos.appendingPathComponent("clones"), withIntermediateDirectories: true)
        try git(["clone", "--bare", source.path, repos.appendingPathComponent("bare").path], in: home)
        try git(["clone", source.path, repos.appendingPathComponent("clones/\(revision)").path], in: home)
        try FileManager.default.removeItem(at: source)
        let output = home.appendingPathComponent("out", isDirectory: true)
        let pipeline = TaxTriagePipeline(homeDirectoryProvider: { home })

        let prepared = try await pipeline.preparePipelineProjectSource(forRevision: revision, durableOutputDirectory: output)

        XCTAssertTrue(FileManager.default.fileExists(atPath: repos.appendingPathComponent("bare/HEAD").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.appendingPathComponent("jhuapl-bio/taxtriage").path))
        XCTAssertEqual(prepared.launchTarget, TaxTriageConfig.pipelineRepository, "the repository, not the cache")
        XCTAssertEqual(prepared.revision, revision)
        XCTAssertNil(prepared.snapshotDirectory)
        XCTAssertNil(prepared.cleanupDirectory)
        XCTAssertEqual(prepared.pipelineSource, .remote)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.appendingPathComponent("workflow-source").path),
            "only the snapshot copy is lost"
        )
    }
}
