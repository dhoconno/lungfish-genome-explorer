// VariantEditRouteParityTests.swift - The two variant deletions in process against variants delete
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A43 M3, decision C3. A deletion's only inputs are the bundle and the selected
// rows, so the drawer runs in process the Workflow function its `lungfish-cli variants delete`
// leaf runs, and its row records that leaf. Each test makes one bundle of one variant database in
// root A and copies it to root C. Side A is the drawer's deletion, its begin helper and the call
// its closure makes on that row's values. Side C replays the command the row recorded, rebased
// onto root C, through the leaf in this process. The route parity harness compares the two roots
// (Tests/Support/LungfishKitTestSupport/RouteParityHarness.swift), and A against C declares only
// the identity paths of R2 (MD62). No side launches the CLI, so the class stays in the unit tier and the harness's binary
// never runs.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class VariantEditRouteParityTests: XCTestCase {
    enum Case: String, Sendable {
        case deleteSelected
        case deleteAll
    }

    private var scratch: URL!
    /// The harness's comparison only. This class runs no CLI.
    private let harness = RouteParityHarness(cliBinary: URL(fileURLWithPath: "/usr/bin/false"), kind: .bundle)

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "variant-edit-parity")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - variant-delete-selected, Variant deletion

    func testSelectedDeletionWritesWhatVariantsDeleteWrites() async throws {
        let found = try await routeDifferences(.deleteSelected) { fixture in
            let ids = try fixture.variantIDs()
            let selection = [VariantEditFixture.trackID: [ids[2], ids[0]]]
            let arguments = VariantDeletionMutationService.deleteSelectedArguments(
                bundleURL: fixture.bundleURL, idsByTrack: selection
            )
            let reporter = RecordingOperationReporter()
            AnnotationTableDrawerView.beginVariantStorageMutationOperation(
                title: "Variant deletion", bundleURL: fixture.bundleURL, command: arguments, routeContext: nil, reporter: reporter
            ) { _ in }
            // The call performVariantDeletion makes, on the same values.
            _ = try VariantDeletionMutationService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).deleteVariants(
                idsByTrack: selection, bundleURL: fixture.bundleURL, targets: [Self.target(of: fixture)],
                invocationArgv: [CLICommandIdentity.executableName] + arguments
            )
            return try XCTUnwrap(reporter.items.first?.cliCommand)
        }
        assertAgree(.deleteSelected, found)
    }

    // MARK: - variant-delete-all, Delete all variants

    func testDeleteAllWritesWhatVariantsDeleteAllWrites() async throws {
        let found = try await routeDifferences(.deleteAll) { fixture in
            let arguments = VariantDeletionMutationService.deleteAllArguments(bundleURL: fixture.bundleURL)
            let reporter = RecordingOperationReporter()
            AnnotationTableDrawerView.beginVariantStorageMutationOperation(
                title: "Delete all variants", bundleURL: fixture.bundleURL, command: arguments, routeContext: nil, reporter: reporter
            ) { _ in }
            // The call performDeleteAllVariants makes, on the same values.
            _ = try VariantDeletionMutationService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).deleteAllVariants(
                bundleURL: fixture.bundleURL, targets: [Self.target(of: fixture)],
                invocationArgv: [CLICommandIdentity.executableName] + arguments
            )
            return try XCTUnwrap(reporter.items.first?.cliCommand)
        }
        assertAgree(.deleteAll, found)
    }

    // MARK: - V1-6, the durable replay of the deletion from the table

    /// 2.13 V1-6. The record the drawer writes may name `lungfish-cli variants delete` as its durable replay argv only if that
    /// leaf writes what the drawer's run in process writes. The drawer's deletion runs on root A and the leaf, from the command
    /// the row records, on root C, a copy of root A. The databases are byte-equal, the drawer's `argv` names the app, and its
    /// durable replay argv and its command are the words the leaf's record holds as its own.
    func testVariantDeletionInProcessRunAndLeafWriteEqualBytes() async throws {
        let caseRoot = scratch.appendingPathComponent("v16-delete", isDirectory: true)
        let rootA = RouteParityHarness.root(of: .a, in: caseRoot)
        let rootC = RouteParityHarness.root(of: .c, in: caseRoot)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        let fixtureA = try VariantEditFixture.make(in: rootA, withTrackManifest: true)
        try FileManager.default.copyItem(at: rootA, to: rootC)
        let fixtureC = fixtureA.rebased(onto: rootC)
        let selection = [VariantEditFixture.trackID: [try fixtureA.variantIDs()[1]]]
        let arguments = VariantDeletionMutationService.deleteSelectedArguments(bundleURL: fixtureA.bundleURL, idsByTrack: selection)
        let reporter = RecordingOperationReporter()
        AnnotationTableDrawerView.beginVariantStorageMutationOperation(
            title: "Variant deletion", bundleURL: fixtureA.bundleURL, command: arguments, routeContext: nil, reporter: reporter
        ) { _ in }
        let command = try XCTUnwrap(reporter.items.first?.cliCommand)

        // The call performVariantDeletion makes, on the same values.
        _ = try VariantDeletionMutationService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind).deleteVariants(
            idsByTrack: selection, bundleURL: fixtureA.bundleURL, targets: [Self.target(of: fixtureA)],
            invocationArgv: [LungfishAppIdentity.recordedToolName] + arguments,
            durableReplayArgv: [CLICommandIdentity.executableName] + arguments
        )
        try await RecordedCLICommand.runInProcess(try RecordedCLICommand.rebased(command, from: rootA, to: rootC))

        XCTAssertEqual(
            try Data(contentsOf: fixtureA.databaseURL), try Data(contentsOf: fixtureC.databaseURL),
            "the drawer's deletion and variants delete leave different database bytes"
        )
        let app = try Self.replayWords(of: fixtureA.bundleURL, root: rootA)
        let leaf = try Self.replayWords(of: fixtureC.bundleURL, root: rootC)
        XCTAssertEqual(leaf.argv.first, CLICommandIdentity.executableName)
        XCTAssertEqual(app.argv.first, LungfishAppIdentity.recordedToolName, "argv names what ran")
        XCTAssertEqual(Array(app.argv.dropFirst()), Array(leaf.argv.dropFirst()), "argv keeps the leaf's words after the tool")
        XCTAssertEqual(app.durableReplayArgv, leaf.argv, "the run's durable replay argv is the leaf's argv")
        XCTAssertEqual(app.stepDurableReplayArgv, leaf.argv, "the step's durable replay argv is the leaf's argv")
        XCTAssertEqual(app.reproducibleCommand, leaf.reproducibleCommand, "the run's command agrees with its replay line")
        XCTAssertEqual(app.stepReproducibleCommand, leaf.stepReproducibleCommand, "the step's command agrees with its replay line")
    }

    /// What a record says it replays, with the root's path written `<ROOT>`, so two roots compare.
    private struct ReplayWords {
        let argv: [String]
        let durableReplayArgv: [String]
        let stepDurableReplayArgv: [String]
        let reproducibleCommand: String
        let stepReproducibleCommand: String
    }

    private static func replayWords(of bundleURL: URL, root: URL) throws -> ReplayWords {
        let record = bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        let step = try XCTUnwrap((json["steps"] as? [[String: Any]])?.first)
        let spellings = [root.resolvingSymlinksInPath().path, root.standardizedFileURL.path, root.path].sorted { $0.count > $1.count }
        func masked(_ text: String) -> String { spellings.reduce(text) { $0.replacingOccurrences(of: $1, with: "<ROOT>") } }
        func words(_ value: Any?) -> [String] { ((value as? [String]) ?? []).map(masked) }
        return ReplayWords(
            argv: words(json["argv"]), durableReplayArgv: words(json["durableReplayArgv"]),
            stepDurableReplayArgv: words(step["durableReplayArgv"]),
            reproducibleCommand: masked(json["reproducibleCommand"] as? String ?? ""),
            stepReproducibleCommand: masked(step["reproducibleCommand"] as? String ?? "")
        )
    }

    // MARK: - The two sides

    /// Makes the fixture bundle in root A, copies root A to root C, runs `appRoute` on root A's
    /// bundle, replays the command it returns on root C through the leaf in this process, and
    /// returns how root C differs from root A.
    private func routeDifferences(
        _ parityCase: Case,
        appRoute: (VariantEditFixture) async throws -> String
    ) async throws -> [RouteParityDifference] {
        let caseRoot = scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true)
        let rootA = RouteParityHarness.root(of: .a, in: caseRoot)
        let rootC = RouteParityHarness.root(of: .c, in: caseRoot)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        let fixtureA = try VariantEditFixture.make(in: rootA, withTrackManifest: true)
        try FileManager.default.copyItem(at: rootA, to: rootC)

        let command = try await appRoute(fixtureA)
        try await RecordedCLICommand.runInProcess(try RecordedCLICommand.rebased(command, from: rootA, to: rootC))

        let sideA = RouteParitySideRun(side: .a, root: rootA, outcome: RouteParitySideOutcome(end: .completed))
        let sideC = RouteParitySideRun(side: .c, root: rootC, outcome: RouteParitySideOutcome(end: .completed, recordedCommand: command))
        return try harness.differences(sideA, sideC)
    }

    /// Fails with every difference of A against C but the identity paths of R2 (MD62), which the cases declare by count.
    private func assertAgree(_ parityCase: Case, _ found: [RouteParityDifference], line: UInt = #line) {
        let failures = RouteParityHarness.failures(
            found: [.aAgainstC: found], parityCase: parityCase,
            declared: [RouteParityHarness.appIdentityDifference([Case.deleteSelected: 12, Case.deleteAll: 12])]
        )
        RouteParityHarness.assertNoFailures(failures, in: parityCase.rawValue, line: line)
    }

    /// The target the drawer builds from its search index's handle of the track.
    private static func target(of fixture: VariantEditFixture) -> VariantDeletionMutationTarget {
        VariantDeletionMutationTarget(
            trackId: VariantEditFixture.trackID, databaseURL: fixture.databaseURL, trackName: VariantEditFixture.trackName
        )
    }
}
