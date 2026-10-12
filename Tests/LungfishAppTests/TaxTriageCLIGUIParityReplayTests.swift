// TaxTriageCLIGUIParityReplayTests.swift - Today's TaxTriage GUI route against its recorded command, on the stand-in engine
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane Q1a, the freeze that lands before any behaviour commit of A1 or A2 (QA 1). It
// carries Moved out row 249 of the 2.8 plan, 2.7 T2 and T9, 2.8 T16 with the TF-G stand-in, and
// the QA ruling on O5, under which this class runs only the stand-in. Each case runs two sides,
// one after another, on one stand-in engine.
//
// - Side A is today's GUI route. `AppDelegate.runTaxTriage(config:...)` runs the config the
//   TaxTriage wizard builds for the case's bundles on `OperationCenter.shared`, with
//   `AppDelegate.TaxTriageLaunchSeam.makeRunner` bound to the engine and `LUNGFISH_CLI_PATH`
//   naming the built CLI for its `build-db taxtriage` step (2.7 T9).
// - Side B is the command side A's row recorded, rebased onto a fresh root and run in this
//   process with `TaxTriageCommand.RunSubcommand.makePipeline` bound to the same engine, as
//   docs/contracts/CLI-EQUIVALENCE.md replays a command. A request of several samples records
//   no command (cli-parity-gap taxtriage-multi-sample), so side B runs today's one command for
//   it, a folder `--input` that pools the samples in one Nextflow run (2.8 T2, QA inventory 2.2).
//
// Each case checks the fixed facts on each side (TaxTriageCLIGUIParityReplayTests+FixedFacts.swift)
// and compares the two side roots, every provenance record by its facts and the terminal state
// (TaxTriageCLIGUIParityReplayTests+Compare.swift). TaxTriageParityKnownDifferences declares every
// difference of A against B with its count, and the case fails on any other. Lane Q1b adds sides
// C and C' to the same cases (TaxTriageCLIGUIParityReplayTests+RouteC.swift): C runs the routed
// `taxtriage run --project` through the built `lungfish-cli`, and C' the argv C's root record
// names, rebased. C against C' declares nothing (2.7 T2).
//
// The stand-in starts processes and side A runs on `OperationCenter.shared`, so the class name ends
// in ReplayTests, which sends it to the serial replay tier. `TaxTriageParityEngine` takes the
// engine's root, profile and database as parameters, so a live class can run the same sides on a
// managed root (ruling O5). `LUNGFISH_PARITY_DUMP=<folder>` keeps a copy of each case's roots and
// its findings in that folder.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class TaxTriageCLIGUIParityReplayTests: XCTestCase {
    var scratch: URL!
    var cliBinary: URL!
    private var savedCLIPath: String?

    enum ParityError: Error {
        case missingCLI
        /// The stand-in keeps no organism report fixture at the path, which X7 empties.
        case noOrganismReportFixture(String)
    }

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "taxtriage-parity")
        let productsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        guard let cli = CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: productsDirectory) else {
            XCTFail(
                "No lungfish-cli beside \(productsDirectory.path) and none named by LUNGFISH_CLI_PATH. "
                    + "Without it side A's build-db step builds no taxtriage.sqlite."
            )
            throw ParityError.missingCLI
        }
        cliBinary = cli
        savedCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
    }

    override func tearDown() async throws {
        if cliBinary != nil {
            if let savedCLIPath {
                setenv("LUNGFISH_CLI_PATH", savedCLIPath, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }
        OperationCenter.shared.clearCompleted()
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    func testX1OneSampleOfTheVirtualSubsetBundle() async throws {
        try await assertParity(.x1)
    }

    func testX2TheSARSCoV2PairAsOneSample() async throws {
        try await assertParity(.x2)
    }

    func testX3TwoSamplesInOneLaunchRequest() async throws {
        try await assertParity(.x3)
    }

    func testX4OneFailedSampleOfTwo() async throws {
        try await assertParity(.x4)
    }

    func testX5ErroredTasksTheRunIgnores() async throws {
        try await assertParity(.x5)
    }

    func testX6CancelOnceTheEngineStarted() async throws {
        try await assertParity(.x6)
    }

    func testX7ForceRebuildAfterTheCleanup() async throws {
        try await assertParity(.x7)
    }

    func testX8PlainOutputOfTwoSamplesOnSideB() async throws {
        try await assertParity(.x8)
    }

    // MARK: - One case

    /// Runs `parityCase` on its own stand-in engine through TaxTriageParityHarness, which a live
    /// class calls the same way with an engine on a managed root (ruling O5).
    func assertParity(_ parityCase: TaxTriageParityCase) async throws {
        let caseRoot = scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true)
        try? FileManager.default.removeItem(at: caseRoot)
        let engine = try makeStandInEngine(in: caseRoot, for: parityCase)
        try await TaxTriageParityHarness(testCase: self, cliBinary: cliBinary)
            .assertParity(parityCase, engine: engine, caseRoot: caseRoot)
    }

    /// The case's stand-in engine in `caseRoot`, with the case's behaviour and an empty Kraken2
    /// database folder beside it, which the pipeline checks and the stand-in never reads. Both
    /// sides run on it one after the other, so the launches it numbers by counting a folder never
    /// collide (2.8 row 249). A teardown block stops any stand-in process the case left (QA
    /// checklist 2), and a waiting launch gives up after 60 seconds, which bounds a cancel that
    /// never arrives.
    private func makeStandInEngine(in caseRoot: URL, for parityCase: TaxTriageParityCase) throws -> TaxTriageParityEngine {
        let database = caseRoot.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let engine = try TaxTriageStandInEngine(
            root: caseRoot.appendingPathComponent("engine", isDirectory: true),
            behaviour: parityCase.behaviour,
            maximumWait: .seconds(60)
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        if !parityCase.organismReportsHaveRows {
            try Self.emptyOrganismReport(of: engine)
        }
        if parityCase.materializesVirtualBundle {
            try Self.linkManagedEnvironment("seqkit", into: engine)
        }
        return .standIn(engine, databasePath: database)
    }

    /// Links the managed environment `name` of this Mac's tool root into the stand-in's conda root,
    /// which the built `lungfish-cli` of sides C and C' reads as its own, so the CLI materializes a
    /// virtual bundle with the managed seqkit as the in-process sides do. The link is read only.
    private static func linkManagedEnvironment(_ name: String, into engine: TaxTriageStandInEngine) throws {
        let managed = ManagedStorageConfigStore().currentCondaRootURL().appendingPathComponent("envs/\(name)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: managed.path) else { return }
        try FileManager.default.createSymbolicLink(
            at: engine.condaRoot.appendingPathComponent("envs/\(name)", isDirectory: true),
            withDestinationURL: managed
        )
    }
}
