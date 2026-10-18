// TaxonomyExtractionClipboardShareParityReplayTests.swift - The clipboard and share extraction in process against extract reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.11 M2, on lane Q30's harness (decisions C4, C5 and C13 of 2.10, R-A1). The
// extraction sheet's clipboard and share destinations ran `ClassifierReadResolver` in the app and
// recorded no command. They now run `lungfish-cli extract reads --by-classifier` into a scratch file on
// `CLIBundleBuildRunner` and copy that file (`ClassifierExtractionCopyRoute`). Each case runs on
// sides that start as copies of one project with a single-end Kraken2 result, taxon 20 selected.
//
// - Side A was the in-process route at the base, the resolver with the `.clipboard` or `.share`
//   destination. A against C declared nothing, so side A retired with the resolver's two branches in
//   lane 12.11 M3 (review fix 9, R-A1). It no longer runs, and the class compares C against C'.
// - Side C is the route as the sheet runs it, the copy route, the begin helper and the runner, which
//   launches the built lungfish-cli, then the copy. Its row records the command.
// - Side C' is the harness's replay of that command, then the same copy of the file the replay wrote.
//
// Each side then hands over what the person gets. It writes the pasteboard text, or moves the shared file,
// into `Delivered/` of its root, and removes the folder of `.lungfish/.tmp/shares` the picker read the
// file from, so the hand-over removes the share folder on every side. On sides C and C' that folder held
// the command's record beside the shared file. Side A as it was built here wrote no app sidecar, since
// its options carried no `fileProvenance`, so an app sidecar there held only for the real app's options.
// Nothing is declared for C against C'.
//
// It runs the managed seqkit and launches the built lungfish-cli, so its name ends in ReplayTests, which
// sends it to the integration tier, and it skips without the tool unless `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class TaxonomyExtractionClipboardShareParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case clipboard
        case share
    }

    private static let options = ExtractionOptions(format: .fastq)
    private static let expectedFASTQ = ReadSetFixtures.fastq(["b1", "b2"])

    private var scratch: URL!
    private var cli: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "clipboard-share-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    func testTheClipboardRouteCopiesWhatItsReplayCopies() async throws {
        try await requireSeqkit()
        try await assertCase(.clipboard)
    }

    func testTheShareRouteSharesWhatItsReplayShares() async throws {
        try await requireSeqkit()
        try await assertCase(.share)
    }

    /// Side A, the resolver's `.clipboard` and `.share` branches, retired in lane 12.11 M3. The harness
    /// still runs a side A, so it is this outcome, and the class compares C against C' alone.
    private static let retiredSideA = RouteParitySideOutcome(
        end: .completed, detail: "not run, the resolver's clipboard and share branches retired in 2.12 lane 12.11"
    )

    private func assertCase(_ parityCase: Case) async throws {
        let runs = try await harness.run(
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { root in _ = try TaxaCollectionFixtures(in: root) },
            sideA: { _ in Self.retiredSideA },
            sideC: { root in await self.sideC(root, parityCase) }
        )
        for run in [runs.c, runs.cPrime] {
            XCTAssertEqual(run.outcome.end, .completed, "\(run.side): \(run.outcome.detail)")
        }
        // Side C' replayed the command. The same copy hands over the file the replay wrote.
        let copied = try await Self.copyReplayed(runs.cPrime, parityCase)
        let differences = try harness.differences(runs.c, runs.cPrime)
        RouteParityHarness.assertNoFailures(differences.map { "\($0)" }, in: "\(parityCase), C against C'")

        XCTAssertEqual(runs.c.outcome.detail, "Extracted 2 reads", "the row's complete words")
        XCTAssertEqual(copied, "Extracted 2 reads")
        let delivered = Self.delivered(runs.c.root).appendingPathComponent("kraken2-concat.fastq")
        XCTAssertEqual(String(decoding: try Data(contentsOf: delivered), as: UTF8.self), Self.expectedFASTQ)
        let scratchFolders = (try? FileManager.default.contentsOfDirectory(atPath: ProjectTempDirectory.tempRoot(for: Self.project(runs.c.root)).path)) ?? []
        XCTAssertEqual(scratchFolders.filter { $0.hasPrefix("classifier-clipboard-") }, [], "the route removes its scratch folder")
    }

    // MARK: - The sides

    private static func project(_ root: URL) -> URL {
        root.appendingPathComponent("Project.lungfish", isDirectory: true)
    }

    private static func delivered(_ root: URL) -> URL {
        root.appendingPathComponent("Delivered", isDirectory: true)
    }

    private static func context(_ root: URL) -> TaxonomyReadExtractionAction.Context {
        TaxonomyReadExtractionAction.Context(
            tool: .kraken2,
            resultPath: project(root).appendingPathComponent("Analyses/kraken2-single", isDirectory: true),
            selections: [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [TaxaCollectionFixtures.speciesB])],
            suggestedName: "my-extract"
        )
    }

    /// The destination the sheet resolves, with the share root it creates.
    private static func destination(_ root: URL, _ parityCase: Case) throws -> ExtractionDestination {
        switch parityCase {
        case .clipboard:
            return .clipboard(format: .fastq, cap: TaxonomyReadExtractionAction.clipboardReadCap)
        case .share:
            let shareRoot = project(root).appendingPathComponent(".lungfish/.tmp", isDirectory: true)
            try FileManager.default.createDirectory(at: shareRoot, withIntermediateDirectories: true)
            return .share(tempDirectory: shareRoot)
        }
    }

    /// Hands over what the person gets, into `Delivered/`, and removes the share picker's folder.
    private static func handOver(_ outcome: ExtractionOutcome, root: URL) throws -> RouteParitySideOutcome {
        let folder = delivered(root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch outcome {
        case .clipboard(let payload, let byteCount, let readCount):
            XCTAssertEqual(byteCount, payload.utf8.count)
            try Data(payload.utf8).write(to: folder.appendingPathComponent("kraken2-concat.fastq"))
            return RouteParitySideOutcome(end: .completed, detail: "Extracted \(readCount) reads")
        case .share(let url, let readCount):
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
            try FileManager.default.removeItem(at: project(root).appendingPathComponent(".lungfish/.tmp/shares", isDirectory: true))
            return RouteParitySideOutcome(end: .completed, detail: "Extracted \(readCount) reads")
        case .file, .bundle:
            return RouteParitySideOutcome(end: .failed, detail: "not a clipboard or share outcome: \(outcome)")
        }
    }

    /// Side C. The copy route the sheet makes, the begin helper with its command and the runner on the
    /// built CLI, then the copy. It returns the row's command, which side C' replays.
    private func sideC(_ root: URL, _ parityCase: Case) async -> RouteParitySideOutcome {
        let reporter = RecordingOperationReporter()
        do {
            let context = Self.context(root)
            let destination = try Self.destination(root, parityCase)
            let route = try XCTUnwrap(try ClassifierExtractionCopyRoute.make(destination: destination, context: context, options: Self.options))
            let command = TaxonomyReadExtractionAction.buildCLIString(
                context: context, options: Self.options, destination: destination, scratchFile: route.scratchFile
            )
            var operationID: UUID?
            TaxonomyReadExtractionAction.beginExtractionOperation(context: context, cliCommand: command, reporter: reporter) { operationID = $0 }
            let id = try XCTUnwrap(operationID, "the row did not start")
            let outcome = try await route.run(operationID: id, cliURLOverride: cli)
            var handed = try Self.handOver(outcome, root: root)
            handed.recordedCommand = reporter.items.first?.cliCommand
            return handed
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: reporter.items.first?.cliCommand)
        }
    }

    /// The copy of side C', on the file its replayed `-o` names, as the route copies side C's.
    private static func copyReplayed(_ run: RouteParitySideRun, _ parityCase: Case) async throws -> String {
        let arguments = try XCTUnwrap(run.replayedArguments.first, "side C' replayed nothing")
        let index = try XCTUnwrap(arguments.firstIndex(of: "-o"), "the command names no -o")
        let file = URL(fileURLWithPath: arguments[index + 1])
        let route = ClassifierExtractionCopyRoute(
            delivery: parityCase == .clipboard ? .clipboard(cap: TaxonomyReadExtractionAction.clipboardReadCap) : .share,
            format: .fastq,
            scratchDirectory: file.deletingLastPathComponent(),
            scratchFile: file,
            arguments: arguments
        )
        let outcome = try await route.deliver()
        if parityCase == .clipboard {
            try FileManager.default.removeItem(at: route.scratchDirectory)
        }
        return try handOver(outcome, root: run.root).detail
    }

    private func requireSeqkit(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await NativeToolRunner.shared.findTool(.seqkit)
        } catch {
            try ToolAvailability.skipOrFail("Managed seqkit is required: \(error)", file: file, line: line)
        }
    }
}
