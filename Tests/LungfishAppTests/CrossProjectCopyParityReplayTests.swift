// CrossProjectCopyParityReplayTests.swift - The cross-project copy in the app against project copy-item
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18 M3, decision C4 of 2.10, R-A1 and U-R1 of 2.12, on lane Q30's harness. A project item
// dropped from S.lungfish onto the sidebar of T.lungfish is copied into T. Each case runs on three sides whose
// roots start as copies of one fixture, an empty T.lungfish.
//
// - Side A is `legacy` of the hidden key `CrossProjectCopyRoute`, `CrossProjectItemCopier.copy` in this
//   process, which the sidebar ran before 2.12. Its row records no command.
// - Side C is `cli`, the route the sidebar calls, on `CLIBundleBuildRunner`, which launches the built
//   `lungfish-cli project copy-item`. Its row records the command.
// - Side C' is the harness's replay of that command.
//
// All three sides read one S.lungfish beside the case folder, which no side writes, and the class checks that
// its bytes do not change. A source inside each side's root would be recorded as each root's own temporary
// path, a difference of the fixture and not of the route. The harness reads `project-copy.json` as a payload,
// which no wall-clock mask covers, so every side gets one clock for its `copiedAt` (BIO ruling on `caller`,
// answer 2). Side A passes it to the copier and sides C and C' get it in `LUNGFISH_TEST_COPIED_AT`, which only
// a debug build of the command reads.
//
// A against C declares the entries of the BIO ruling on `caller` (answer 2) for the read bundle, of the BIO
// ruling on F4 (section 2) for the reference bundle and of the BIO ruling on T5 for both, each with `<ANY>`.
// Side A's records name the command that copied the item in the app, `lungfish fastq import-ont` with
// `caller` `app-cross-project-copy` or `Lungfish.app import-native` with no `caller`, and side C's name
// `lungfish project copy-item` with `caller` `cli`. C against C' declares nothing. The class also checks that
// the stage under T's `.tmp` is gone.
//
// The third case, a reference bundle that has its own `.lungfish-provenance.json` (review N3 of lane 12.18), is
// the common real case of the native path. The service rehydrates that record and appends one step, so the
// found differences all sit in `steps[1]` and the envelope's own identity is the source's on both sides.
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

    /// The differences of A against C, the BIO ruling on `caller` (answer 2) for the read bundle and the
    /// BIO ruling on F4 (section 2) for the reference bundle. Each matches the bundle's envelope and the two
    /// copies of it under `provenance/`, three files a case. Lane 13.03 deletes side A, the key and every entry.
    ///
    /// A against C also declares the entries of the BIO ruling on T5 (`SCR/rulings/BIO-12.18-T5.md`): each command's
    /// option names, `reproducibleCommand` and its step's, and for the reference bundle `options.defaults`,
    /// `tool.name` and the step's `resolvedOptions`, which differ because side A records another command. Each key
    /// ends in `.<ANY>` so that no two entries match one id.
    static let declared: [RouteParityDeclaredDifference<Case>] = {
        let readFiles = "differs: T.lungfish/Imports/R.lungfishfastq/<ANY>provenance.json at "
        let referenceFiles = "differs: T.lungfish/Reference Sequences/NC_045512.lungfishref/<ANY>provenance.json at "
        let command = "Side A records the command that copied the item in the app, side C `lungfish project copy-item`"
        let closedBy = "13.03 (DEL-REST) deletes side A and the key"
        let readOptions = "Side A names `fastq import-ont`'s options, side C the leaf's (BIO T5)"
        let referenceOptions = "Side A names `Lungfish.app import-native`'s options, side C the leaf's (BIO T5)"
        let read: [(String, Int, String)] = [
            ("argv[<ANY>]", 21, command), ("durableReplayArgv[<ANY>]", 21, command),
            ("workflowName", 3, command), ("toolName", 3, command), ("tool.name", 3, command),
            ("steps[<ANY>].argv[<ANY>]", 21, command), ("steps[<ANY>].durableReplayArgv[<ANY>]", 21, command),
            ("steps[<ANY>].toolName", 3, command),
            ("options.resolvedDefaults.caller<ANY>", 3, "Side A `app-cross-project-copy`, side C `cli` (BIO-caller 1 and 2)"),
            ("options.defaults<ANY>", 15, "Side A `fastq import-ont`'s defaults, side C the leaf's real defaults (BIO 3)"),
            ("options.explicit.input.<ANY>", 6, readOptions), ("options.explicit.output.<ANY>", 6, readOptions),
            ("options.explicit.item.<ANY>", 6, readOptions), ("options.explicit.project.<ANY>", 6, readOptions),
            ("options.explicit.sourceProject.<ANY>", 6, readOptions),
            ("options.resolvedDefaults.input.<ANY>", 6, readOptions),
            ("options.resolvedDefaults.output.<ANY>", 6, readOptions),
            ("options.resolvedDefaults.destinationBundle.<ANY>", 6, readOptions),
            ("options.resolvedDefaults.destination.<ANY>", 6, readOptions),
            ("options.resolvedDefaults.item.<ANY>", 6, readOptions),
            ("options.resolvedDefaults.project.<ANY>", 6, readOptions),
            ("reproducibleCommand", 3, command), ("steps[<ANY>].reproducibleCommand", 3, command),
        ]
        let reference: [(String, Int, String)] = [
            ("argv[<ANY>]", 24, command), ("durableReplayArgv[<ANY>]", 24, command),
            ("workflowName", 3, command), ("toolName", 3, command),
            ("steps[<ANY>].argv[<ANY>]", 24, command), ("steps[<ANY>].durableReplayArgv[<ANY>]", 24, command),
            ("steps[<ANY>].toolName", 3, command),
            ("options.resolvedDefaults.caller<ANY>", 6, "Side A writes no `caller`, side C `cli` (F4 section 2)"),
            ("tool.name", 3, command),
            ("options.defaults<ANY>", 9,
             "Side A `import-native`'s default `replaceExisting`, side C the leaf's real defaults, none (BIO 3, BIO T5)"),
            ("options.explicit.source.<ANY>", 6, referenceOptions),
            ("options.explicit.destination.<ANY>", 6, referenceOptions),
            ("options.explicit.item.<ANY>", 6, referenceOptions), ("options.explicit.project.<ANY>", 6, referenceOptions),
            ("options.explicit.sourceProject.<ANY>", 6, referenceOptions),
            ("options.resolvedDefaults.source.<ANY>", 6, referenceOptions),
            ("options.resolvedDefaults.item.<ANY>", 6, referenceOptions),
            ("options.resolvedDefaults.project.<ANY>", 6, referenceOptions),
            ("steps[<ANY>].resolvedOptions.caller.<ANY>", 6, "Side A writes no `caller`, side C `cli` (F4 section 2, BIO T5)"),
            ("steps[<ANY>].resolvedOptions.source.<ANY>", 6, referenceOptions),
            ("steps[<ANY>].resolvedOptions.item.<ANY>", 6, referenceOptions),
            ("steps[<ANY>].resolvedOptions.project.<ANY>", 6, referenceOptions),
            ("reproducibleCommand", 3, command), ("steps[<ANY>].reproducibleCommand", 3, command),
        ]
        let recordedFiles = "differs: T.lungfish/Reference Sequences/NC_045513.lungfishref/<ANY>provenance.json at "
        let recordedStep = "Side A appends the step of `Lungfish.app import-native`, side C the step of `lungfish project copy-item` (BIO T5)"
        let recorded: [(String, Int, String)] = [
            ("steps[<ANY>].argv[<ANY>]", 24, recordedStep), ("steps[<ANY>].durableReplayArgv[<ANY>]", 24, recordedStep),
            ("steps[<ANY>].toolName", 3, recordedStep), ("steps[<ANY>].reproducibleCommand", 3, recordedStep),
            ("steps[<ANY>].resolvedOptions.caller.<ANY>", 6, "Side A writes no `caller`, side C `cli` (F4 section 2, BIO T5)"),
            ("steps[<ANY>].resolvedOptions.source.<ANY>", 6, referenceOptions),
            ("steps[<ANY>].resolvedOptions.item.<ANY>", 6, referenceOptions),
            ("steps[<ANY>].resolvedOptions.project.<ANY>", 6, referenceOptions),
        ]
        return read.map { RouteParityDeclaredDifference([.readBundle: $0.1], readFiles + $0.0, reason: $0.2, closedBy: closedBy) }
            + reference.map {
                RouteParityDeclaredDifference([.referenceBundle: $0.1], referenceFiles + $0.0, reason: $0.2, closedBy: closedBy)
            }
            + recorded.map {
                RouteParityDeclaredDifference([.recordedReferenceBundle: $0.1], recordedFiles + $0.0, reason: $0.2, closedBy: closedBy)
            }
    }()

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

    func testTheCopyRowCopiesAReadBundleAsTheInAppCopyDid() async throws {
        try await assertCase(.readBundle)
    }

    func testTheCopyRowCopiesAReferenceBundleAsTheInAppCopyDid() async throws {
        try await assertCase(.referenceBundle)
    }

    func testTheCopyRowCopiesARecordedReferenceBundleAsTheInAppCopyDid() async throws {
        try await assertCase(.recordedReferenceBundle)
    }

    private func assertCase(_ parityCase: Case, file: StaticString = #filePath, line: UInt = #line) async throws {
        let source = scratch.appendingPathComponent("source-\(parityCase.rawValue)/S.lungfish", isDirectory: true)
        try Self.writeSource(source)
        let sourceBefore = try Self.digests(under: source)
        let item = source.appendingPathComponent(parityCase.relativePath, isDirectory: true)
        let result = try await harness.assertParity(
            parityCase,
            declared: Self.declared,
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { root in
                try FileManager.default.createDirectory(at: Self.target(root), withIntermediateDirectories: true)
            },
            sideA: { root in await self.side(.legacy, item, root) },
            sideC: { root in await self.side(.cli, item, root) },
            file: file,
            line: line
        )
        XCTAssertEqual(try Self.digests(under: source), sourceBefore, "no side wrote into the source project", file: file, line: line)
        let landed = "Copied to \(parityCase.relativePath)"
        for run in [result.runs.a, result.runs.c] {
            XCTAssertEqual(run.outcome.end, .completed, "\(run.side): \(run.outcome.detail)", file: file, line: line)
            XCTAssertEqual(run.outcome.detail, landed, "side \(run.side): the row's complete words", file: file, line: line)
        }
        XCTAssertEqual(result.runs.cPrime.outcome.end, .completed, result.runs.cPrime.outcome.detail, file: file, line: line)
        XCTAssertNil(result.runs.a.outcome.recordedCommand, "side A ran no command", file: file, line: line)
        for run in result.runs.all {
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

    /// Side A on `legacy` or side C on `cli`, through the drop handler's begin, copy and complete. Side A runs
    /// the copier as `copyInProcess` does, with the class's clock. Side C's row records the command, which
    /// side C' replays.
    private func side(_ route: CrossProjectCopyRoute, _ item: URL, _ root: URL) async -> RouteParitySideOutcome {
        let target = Self.target(root)
        let reporter = RecordingOperationReporter()
        let runner = CLIBundleBuildRunner(cliURLOverride: harness.cliBinary)
        let start = MainSplitViewController.beginCrossProjectCopyOperation(
            itemURL: item, projectURL: target, requestedFolder: nil, route: route, routeContext: nil, reporter: reporter
        )
        let command = reporter.items.first?.cliCommand
        guard let operationID = start.startedID else {
            return RouteParitySideOutcome(end: .failed, detail: "the row was refused", recordedCommand: command)
        }
        let result: Result<CrossProjectCopyRoute.Landed, any Error>
        switch route {
        case .legacy:
            result = Result {
                let outcome = try CrossProjectItemCopier.copy(itemAt: item, intoProject: target, requestedFolder: nil, now: Self.clock)
                return CrossProjectCopyRoute.Landed(destinationURL: outcome.destinationURL, record: outcome.record)
            }
        case .cli:
            result = await MainSplitViewController.copyDroppedProjectItem(
                item, intoProject: target, requestedFolder: nil, route: .cli, operationID: operationID
            ) { arguments, id in
                let run = try await runner.run(arguments: arguments, operationID: id, environmentAdditions: Self.clockEnvironment)
                return CrossProjectCopyRoute.Run(outputs: run.outputs, message: run.message)
            }
        }
        switch result {
        case .success(let landed):
            MainSplitViewController.completeCrossProjectCopyRow(
                operationID, landed: landed, route: route, projectURL: target, reporter: reporter
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
