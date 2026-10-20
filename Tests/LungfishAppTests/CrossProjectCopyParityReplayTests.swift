// CrossProjectCopyParityReplayTests.swift - The cross-project copy against its recorded command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18 M3, decision C4 of 2.10, R-A1 and U-R1 of 2.12, on lane Q30's harness, reduced to C
// against C' in Phase 2.13 (DEL-REST). A project item dropped from S.lungfish onto the sidebar of T.lungfish is
// copied into T. Each case runs on two sides whose roots start as copies of one fixture, an empty T.lungfish.
//
// - Side C is the route the sidebar calls, on `CLIBundleBuildRunner`, which launches the built
//   `lungfish-cli project copy-item`. Its row records the command.
// - Side C' is the harness's replay of that command.
//
// Both sides read one S.lungfish beside the case folder, which neither writes, and the class checks that its
// bytes do not change. A source inside each side's root would be recorded as each root's own temporary path, a
// difference of the fixture and not of the route. The harness reads `project-copy.json` as a payload, which no
// wall-clock mask covers, so both sides get one clock for its `copiedAt` (BIO ruling on `caller`, answer 2).
// They get it in `LUNGFISH_TEST_COPIED_AT`, which only a debug build of the command reads, so the clock seam of
// `ProjectCopyItemSubcommand` stays as long as this check does.
//
// C against C' declares nothing. The class also checks that the stage under T's `.tmp` is gone. Side A, the
// in-app copy behind the hidden key `CrossProjectCopyRoute`, and the differences it declared left with the key
// in Phase 2.13.
//
// The third case, a reference bundle that has its own `.lungfish-provenance.json` (review N3 of lane 12.18), is
// the common real case of the native path. The service rehydrates that record and appends one step.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class CrossProjectCopyParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case readBundle
        case referenceBundle
        /// A native-path item that has its own `.lungfish-provenance.json`, which the native copy rehydrates
        /// with one appended step (review N3 of lane 12.18).
        case recordedReferenceBundle

        /// The item's path inside S.lungfish, which the copy keeps inside T.lungfish.
        var relativePath: String {
            switch self {
            case .readBundle: return "Imports/R.lungfishfastq"
            case .referenceBundle: return "Reference Sequences/NC_045512.lungfishref"
            case .recordedReferenceBundle: return "Reference Sequences/NC_045513.lungfishref"
            }
        }
    }

    /// The one clock every side's `project-copy.json` names.
    static let clockText = "2026-10-18T12:00:00Z"
    static var clock: Date { ISO8601DateFormatter().date(from: clockText)! }
    static var clockEnvironment: [String: String] { [ProjectCopyItemSubcommand.copiedAtVariable: clockText] }

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "cross-project-copy-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(
            cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120), environment: { _ in Self.clockEnvironment }
        )
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testTheCopyOfAReadBundleRepeatsThroughItsRecordedCommand() async throws {
        try await assertCase(.readBundle)
    }

    func testTheCopyOfAReferenceBundleRepeatsThroughItsRecordedCommand() async throws {
        try await assertCase(.referenceBundle)
    }

    func testTheCopyOfARecordedReferenceBundleRepeatsThroughItsRecordedCommand() async throws {
        try await assertCase(.recordedReferenceBundle)
    }

    /// Runs sides C and C' (`ReadsRouteParity.runCAndCPrime`, since no side A is left) and fails on each
    /// difference between them.
    private func assertCase(_ parityCase: Case, file: StaticString = #filePath, line: UInt = #line) async throws {
        let source = scratch.appendingPathComponent("source-\(parityCase.rawValue)/S.lungfish", isDirectory: true)
        try Self.writeSource(source)
        let sourceBefore = try Self.digests(under: source)
        let item = source.appendingPathComponent(parityCase.relativePath, isDirectory: true)
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { root in
                try FileManager.default.createDirectory(at: Self.target(root), withIntermediateDirectories: true)
            },
            sideC: { root in await self.sideC(item, root) }
        )
        let result = try harness.evaluate(parityCase, declared: [], runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(parityCase), C against C'", file: file, line: line)
        XCTAssertEqual(try Self.digests(under: source), sourceBefore, "no side wrote into the source project", file: file, line: line)
        XCTAssertEqual(runs.c.outcome.end, .completed, "side C: \(runs.c.outcome.detail)", file: file, line: line)
        XCTAssertEqual(
            runs.c.outcome.detail, "Copied to \(parityCase.relativePath)", "side C: the row's complete words", file: file, line: line
        )
        XCTAssertNotNil(runs.c.outcome.recordedCommand, "side C: the row records the command", file: file, line: line)
        XCTAssertEqual(runs.cPrime.outcome.end, .completed, runs.cPrime.outcome.detail, file: file, line: line)
        for run in [runs.c, runs.cPrime] {
            let temp = Self.target(run.root).appendingPathComponent(".tmp", isDirectory: true)
            let stages = ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])
                .filter { $0.hasPrefix("project-copy-") }
            XCTAssertEqual(stages, [], "side \(run.side): the stage is removed", file: file, line: line)
            let copy = Self.target(run.root).appendingPathComponent(parityCase.relativePath, isDirectory: true)
            let record = ProjectItemCopyRecord.load(from: copy)
            let clockMessage = "side \(run.side): the copy is published with its record, which names the class clock "
                + "(a release lungfish-cli ignores \(ProjectCopyItemSubcommand.copiedAtVariable))"
            XCTAssertEqual(record?.copiedAt, Self.clock, clockMessage, file: file, line: line)
        }
    }

    // MARK: - The sides

    private static func target(_ root: URL) -> URL {
        root.appendingPathComponent("T.lungfish", isDirectory: true)
    }

    /// Side C, through the drop handler's begin, copy and complete. Its row records the command, which side C'
    /// replays.
    private func sideC(_ item: URL, _ root: URL) async -> RouteParitySideOutcome {
        let target = Self.target(root)
        let reporter = RecordingOperationReporter()
        let runner = CLIBundleBuildRunner(cliURLOverride: harness.cliBinary)
        let start = MainSplitViewController.beginCrossProjectCopyOperation(
            itemURL: item, projectURL: target, requestedFolder: nil, routeContext: nil, reporter: reporter
        )
        let command = reporter.items.first?.cliCommand
        guard let operationID = start.startedID else {
            return RouteParitySideOutcome(end: .failed, detail: "the row was refused", recordedCommand: command)
        }
        let result = await MainSplitViewController.copyDroppedProjectItem(
            item, intoProject: target, requestedFolder: nil, operationID: operationID
        ) { arguments, id in
            let run = try await runner.run(arguments: arguments, operationID: id, environmentAdditions: Self.clockEnvironment)
            return CrossProjectCopyRoute.Run(outputs: run.outputs, message: run.message)
        }
        switch result {
        case .success(let landed):
            MainSplitViewController.completeCrossProjectCopyRow(
                operationID, landed: landed, projectURL: target, reporter: reporter
            )
            let detail = "Copied to \(MainSplitViewController.projectRelativeDescription(of: landed.destinationURL, in: target))"
            let warned = landed.record?.hasMissingSources ?? false
            return RouteParitySideOutcome(end: warned ? .completedWithWarnings : .completed, detail: detail, recordedCommand: command)
        case .failure(let error):
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: command)
        }
    }

    // MARK: - Fixture

    /// S.lungfish with a read bundle that has its own record and no link into its project, so the copy goes
    /// through `FASTQBundleCopyImportWorkflow`, and a reference bundle, which the native copy takes.
    private static func writeSource(_ source: URL) throws {
        let reads = try writeBundle(source, Case.readBundle.relativePath, name: "reads.fastq", contents: "@r1\nACGT\n+\nIIII\n")
        try writeEnvelope(
            of: ProvenanceFileDescriptor.file(url: reads, format: .fastq, role: .output),
            tool: "source-fastq-tool", workflow: "source FASTQ bundle", into: reads.deletingLastPathComponent()
        )
        _ = try writeBundle(source, Case.referenceBundle.relativePath, name: "sequence.fasta", contents: ">NC_045512\nACGTACGT\n")
        let recorded = try writeBundle(
            source, Case.recordedReferenceBundle.relativePath, name: "sequence.fasta", contents: ">NC_045513\nACGTACGT\n"
        )
        try writeEnvelope(
            of: ProvenanceFileDescriptor.file(url: recorded, role: .output),
            tool: "source-reference-tool", workflow: "source reference bundle", into: recorded.deletingLastPathComponent()
        )
    }

    /// Writes the envelope of the run that made `output` into `bundle`, as a project item holds its own record.
    private static func writeEnvelope(
        of output: ProvenanceFileDescriptor, tool: String, workflow: String, into bundle: URL
    ) throws {
        let argv = [tool, (output.path as NSString).lastPathComponent]
        let step = ProvenanceStep(
            toolName: tool, toolVersion: "1.0", argv: argv, outputs: [output], exitStatus: 0, wallTimeSeconds: 0.1
        )
        let envelope = ProvenanceEnvelope(
            workflowName: workflow, workflowVersion: "1.0", toolName: tool, toolVersion: "1.0",
            argv: argv, files: [output], output: output, outputs: [output], steps: [step], wallTimeSeconds: 0.1, exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundle)
    }

    /// Writes `name` into a new bundle at `relative` inside `project` and returns the file.
    private static func writeBundle(_ project: URL, _ relative: String, name: String, contents: String) throws -> URL {
        let bundle = project.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let file = bundle.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The SHA-256 of every regular file under `folder`, by path.
    private static func digests(under folder: URL) throws -> [String: String] {
        var digests: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            digests[url.path] = try ProvenanceFileHasher.sha256(of: url)
        }
        return digests
    }
}
