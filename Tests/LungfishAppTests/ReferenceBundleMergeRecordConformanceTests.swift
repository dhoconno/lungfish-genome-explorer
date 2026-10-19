// ReferenceBundleMergeRecordConformanceTests.swift - The merged bundle's record names the command that ran
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.14 (A49-REC, BIO 4). The record of a merged bundle used to name `lungfish-app` and the
// pseudo-command `lungfish reference merge`, which nothing can run. `bundle merge` records the words its
// process was started with, unmapped (R-B2). A merge that has no command line of its own, one run in
// process, records the `bundle merge` command that is equivalent to it. The first test runs the built leaf
// through `RouteParityHarness.runCLI` and the second runs the service in process.
//
// The record writer spells a path inside the project `@/...` and a path outside it `<external>/<name>`, as it
// does for every record, so the tests compare the words after reading those two spellings back, and compare
// the executable by its name.
//
// Both tests run the managed bgzip and samtools faidx, so the name ends in Conformance, which keeps them out
// of the unit tier, and they skip without the tools unless `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ReferenceBundleMergeRecordConformanceTests: XCTestCase {
    private var root: URL!
    private var cli: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "reference-merge-record")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so the leaf cannot run"
        )
    }

    override func tearDownWithError() throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    /// The built `bundle merge` records the argv its process was started with, in the root record and in the
    /// merge step, and names neither the app nor the pseudo-command.
    func testTheBuiltLeafRecordsTheArgvItsProcessWasStartedWith() async throws {
        try await requireTools()
        let (project, sources) = try makeSources()
        let arguments = ["bundle", "merge"] + sources.map(\.path)
            + ["--name", "Merged", "--output-dir", project.path, "--format", "json"]
        let run = await RouteParityHarness.runCLI(cli, arguments: arguments, timeout: .seconds(120))
        XCTAssertEqual(run.status, 0, run.detail)

        let merged = project.appendingPathComponent("Merged.lungfishref", isDirectory: true)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: merged))
        let started = normalized([cli.path] + arguments, in: project)
        XCTAssertEqual(normalized(record.argv, in: project), started, "the root record's argv")
        XCTAssertEqual(
            normalized(record.durableReplayArgv ?? [], in: project), started, "the root record's durable replay argv"
        )
        XCTAssertEqual(
            normalized(try AdvancedCommandLineOptions.parse(record.reproducibleCommand), in: project), started,
            "the root record's command text reads back to the same words"
        )
        XCTAssertEqual(record.toolName, "lungfish bundle merge")
        XCTAssertEqual(record.tool.name, "lungfish bundle merge")
        XCTAssertEqual(record.tool.kind, "cli")
        XCTAssertEqual(record.workflowName, "lungfish bundle merge")

        let mergeStep = try XCTUnwrap(record.steps.last, "the merge step closes the record")
        XCTAssertEqual(mergeStep.toolName, "lungfish bundle merge")
        XCTAssertEqual(normalized(mergeStep.argv, in: project), started, "the merge step's argv")
        XCTAssertEqual(normalized(mergeStep.durableReplayArgv ?? [], in: project), started)
        XCTAssertTrue(
            record.steps.contains { $0.toolName == "NativeBundleBuilder.build" },
            "the builder step stays in the record"
        )
        assertNamesNeitherTheAppNorThePseudoCommand(record)
    }

    /// A merge run in process has no argv to observe, so the record states the command that is equivalent to it
    /// and still names neither the app nor the pseudo-command.
    func testAMergeRunInProcessRecordsTheEquivalentBundleMergeCommand() async throws {
        try await requireTools()
        let (project, sources) = try makeSources()
        let merged = try await ReferenceBundleMergeService.merge(
            sourceBundleURLs: sources, outputDirectory: project, bundleName: "Merged"
        )

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: merged))
        let equivalent = normalized(
            [CLICommandIdentity.executableName, "bundle", "merge"] + sources.map(\.path)
                + ["--name=Merged", "--output-dir", project.path],
            in: project
        )
        XCTAssertEqual(normalized(record.argv, in: project), equivalent, "the root record's argv")
        XCTAssertEqual(
            normalized(try XCTUnwrap(record.steps.last).argv, in: project), equivalent, "the merge step's argv"
        )
        XCTAssertEqual(record.argv.first, CLICommandIdentity.executableName)
        XCTAssertEqual(record.toolName, "lungfish bundle merge")
        XCTAssertEqual(record.tool.name, "lungfish bundle merge")
        XCTAssertEqual(record.tool.kind, "cli")
        assertNamesNeitherTheAppNorThePseudoCommand(record)
    }

    // MARK: - Fixture and words

    /// A project with the two source bundles of lane A49, each with a sequence and a gene track.
    private func makeSources() throws -> (project: URL, sources: [URL]) {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let inputs = root.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let first = try ReferenceMergeFixture.writeSource(
            named: "Alpha", sequence: "chrA", bases: "ACGTACGTACGTACGTACGT", gene: "geneA", in: project, inputs: inputs
        )
        let second = try ReferenceMergeFixture.writeSource(
            named: "Beta", sequence: "chrB", bases: "TTGGCCAATTGGCCAATTGG", gene: "geneB", in: project, inputs: inputs
        )
        return (project, [first, second])
    }

    /// `words` with the executable reduced to its name, since the writer spells a path outside the project
    /// `<external>/<name>`, and with the project-relative spelling `@/...` turned back into a path under
    /// `project`, so the words compare with the ones the test passed.
    private func normalized(_ words: [String], in project: URL) -> [String] {
        guard let executable = words.first else { return [] }
        return [URL(fileURLWithPath: executable).lastPathComponent] + words.dropFirst().map { word in
            if word == "@" || word == "@/" { return project.path }
            if word.hasPrefix("@/") { return project.path + "/" + word.dropFirst(2) }
            return word
        }
    }

    private func assertNamesNeitherTheAppNorThePseudoCommand(
        _ record: ProvenanceEnvelope, file: StaticString = #filePath, line: UInt = #line
    ) {
        for word in record.argv + record.steps.flatMap(\.argv) {
            XCTAssertNotEqual(word, "lungfish-app", "no word of the record names the app", file: file, line: line)
            XCTAssertNotEqual(
                word, "lungfish reference merge", "no word of the record names the pseudo-command", file: file, line: line
            )
        }
    }

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
    }
}
