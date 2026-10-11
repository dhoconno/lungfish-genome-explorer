// ClassifierCLIGUIParityReplayTests.swift - Today's classifier GUI paths against their recorded commands, with real tools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane F2, the freeze of today's classifier runs before they move onto the analysis
// run executor (panel decisions T1, T2, T3 and T9 in docs/plans/2026-10-11-phase-2-7.md).
// Each case runs on two sides.
//
// - Side A is today's GUI path. `AppDelegate.runClassification(configs:...)` or
//   `runEsViritu(configs:...)` runs the configs the wizard builds on `OperationCenter.shared`,
//   one case at a time, with `LUNGFISH_CLI_PATH` naming the built CLI for its `build-db` step.
// - Side B is the command side A's row recorded, rebased onto a fresh root and run in this
//   process, as docs/contracts/CLI-EQUIVALENCE.md replays a command.
//
// Lane F3 adds side C, the new GUI route through `lungfish-cli`, and side C', the command C
// records replayed the same way, through `ClassifierParitySide` and `ClassifierParityScope`.
//
// Each case compares the two side roots (the analysis folder and the source bundle's
// analyses-manifest.json, SQLite files as sorted dumps), every provenance record by its facts,
// and the terminal state (ClassifierCLIGUIParityReplayTests+Compare.swift). It checks fixed facts
// on every side and the row outcome of side A (ClassifierCLIGUIParityReplayTests+FixedFacts.swift).
// ClassifierParityKnownDifferences declares every difference with its reason and the lane that
// closes it.
//
// Real tools run, so the class name ends in ReplayTests, which sends it to the integration tier
// and the replay step and keeps it out of the parallel unit tier. The tools and the Kraken2
// Viral database come from `~/.lungfish-stable`. The EsViritu database is read in place from
// `LUNGFISH_TEST_ESVIRITU_DB`, by default the golden folder, with a listing taken before and
// after, and the Stable database registry must keep its bytes. `LUNGFISH_REQUIRE_TOOLS=1` turns a
// missing tool or database into a failure. `LUNGFISH_PARITY_DUMP=<folder>` keeps both side roots,
// the facts of every record and the differences of each case in that folder.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ClassifierCLIGUIParityReplayTests: XCTestCase {
    var scratch: URL!
    var cliBinary: URL!
    private var savedCLIPath: String?
    private var registryDigestBefore: String?

    enum ParityError: Error {
        case missingCLI
    }

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "classifier-parity")
        let productsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        guard let cli = CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: productsDirectory) else {
            XCTFail(
                "No lungfish-cli beside \(productsDirectory.path) and none named by LUNGFISH_CLI_PATH. "
                    + "Without it the GUI EsViritu path builds no esviritu.sqlite, so the parity cases cannot run."
            )
            throw ParityError.missingCLI
        }
        cliBinary = cli
        savedCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        registryDigestBefore = Self.registryDigest()
    }

    override func tearDown() async throws {
        if let savedCLIPath {
            setenv("LUNGFISH_CLI_PATH", savedCLIPath, 1)
        } else {
            unsetenv("LUNGFISH_CLI_PATH")
        }
        if cliBinary != nil {
            XCTAssertEqual(Self.registryDigest(), registryDigestBefore, "a parity case wrote \(ClassifierParityFixtures.stableRegistryURL.path)")
        }
        OperationCenter.shared.clearCompleted()
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    func testK1Kraken2ClassifiesTheVirtualSubsetBundle() async throws {
        try await assertParity(.k1)
    }

    func testK2Kraken2ClassifiesTheMergeBundleWithItsReadSetPlan() async throws {
        try await assertParity(.k2)
    }

    func testK3Kraken2BatchOfTheSubsetAndMergeBundles() async throws {
        try await assertParity(.k3)
    }

    func testK4Kraken2WithABrackenSpeciesProfile() async throws {
        try await assertParity(.k4)
    }

    func testK5Kraken2AndBrackenOnTheNegativeControl() async throws {
        try await assertParity(.k5)
    }

    func testE1EsVirituOnTheVirtualSubsetBundle() async throws {
        try await assertParity(.e1)
    }

    func testE2EsVirituOnTheSARSCoV2Pair() async throws {
        try await assertParity(.e2)
    }

    func testE3EsVirituBatchOfTheSubsetBundleAndThePair() async throws {
        try await assertParity(.e3)
    }

    // MARK: - One case

    func assertParity(_ parityCase: ClassifierParityCase) async throws {
        let esVirituDatabase = try await requireToolsAndDatabases(for: parityCase)
        let databaseListing = try esVirituDatabase.map { try ClassifierParityFixtures.folderListing($0.folder) }
        if let folder = esVirituDatabase?.folder, let databaseListing {
            // Registered before anything below can throw, so a write followed by a throw
            // still fails the case.
            let name = parityCase.rawValue
            addTeardownBlock {
                XCTAssertEqual(
                    try ClassifierParityFixtures.folderListing(folder),
                    databaseListing,
                    "\(name) wrote into the EsViritu database folder \(folder.path)"
                )
            }
        }

        let caseRoot = Self.dumpFolder?.appendingPathComponent(parityCase.rawValue, isDirectory: true)
            ?? scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true)
        try? FileManager.default.removeItem(at: caseRoot)
        let rootA = caseRoot.appendingPathComponent(ClassifierParitySide.a.rawValue, isDirectory: true)
        let rootB = caseRoot.appendingPathComponent(ClassifierParitySide.b.rawValue, isDirectory: true)
        // One project, copied, so both sides start from the same bytes.
        let projectA = try ClassifierParityFixtures.makeProject(in: rootA)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: projectA, to: rootB.appendingPathComponent(projectA.lastPathComponent, isDirectory: true))

        let runA = try await runSideA(parityCase, root: rootA, esVirituDatabase: esVirituDatabase?.files)
        if parityCase.tool == .esViritu, let analysis = runA.analysisFolder {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: analysis.appendingPathComponent("esviritu.sqlite").path),
                "\(parityCase.rawValue): side A's EsViritu tree has no esviritu.sqlite, so its build-db step failed"
            )
        }
        let runB = await runSideB(replaying: runA, root: rootB, timeout: parityCase.timeout)

        var found: [ClassifierParityScope: [ClassifierParityDifference]] = [:]
        found[.side(.a)] = try fixedFactViolations(parityCase, run: runA) + rowOutcomeViolations(parityCase, run: runA)
        found[.side(.b)] = try fixedFactViolations(parityCase, run: runB)
        found[.pair(.a, .b)] = try ClassifierParityComparison.differences(
            reference: runA,
            candidate: runB,
            bundlePaths: parityCase.bundlePaths
        )
        try dumpIfRequested(parityCase, runs: [runA, runB], found: found)

        for scope in [ClassifierParityScope.side(.a), .side(.b), .pair(.a, .b)] {
            let failures = ClassifierParityKnownDifferences.failures(found: found[scope] ?? [], parityCase: parityCase, scope: scope)
            if !failures.isEmpty {
                XCTFail("\(parityCase.rawValue), \(scope):\n" + failures.joined(separator: "\n"))
            }
        }
    }

    /// The tools and databases the case runs, through `ToolAvailability`, so
    /// `LUNGFISH_REQUIRE_TOOLS=1` fails instead of skipping. Returns the EsViritu database for
    /// an EsViritu case: the folder whose listing is guarded and the folder its files are in.
    private func requireToolsAndDatabases(
        for parityCase: ClassifierParityCase
    ) async throws -> (folder: URL, files: URL)? {
        _ = try await ToolAvailability.require("seqkit", environment: "seqkit")
        switch parityCase.tool {
        case .kraken2:
            _ = try await ToolAvailability.require("kraken2", environment: "kraken2")
            if parityCase.profiles {
                _ = try await ToolAvailability.require("bracken", environment: "bracken")
            }
            let viral = try await MetagenomicsDatabaseRegistry.shared.database(named: "Viral")?.path
            _ = try await Self.requireDatabase(at: viral, name: "Kraken2 Viral in the Stable registry")
            return nil
        case .esViritu:
            _ = try await ToolAvailability.require("EsViritu", environment: "esviritu")
            _ = try await ToolAvailability.require("samtools", environment: "samtools")
            let folder = try await Self.requireDatabase(
                at: ClassifierParityFixtures.esVirituDatabaseFolder(),
                name: "EsViritu Viral DB (\(ClassifierParityFixtures.esVirituDatabaseVariable))"
            )
            let files = try await Self.requireDatabase(
                at: ClassifierParityFixtures.esVirituDatabaseFiles(in: folder),
                name: "EsViritu database files under \(folder.path)"
            )
            return (folder, files)
        }
    }

    /// `ToolAvailability.requireDatabase` for a location already resolved, called outside the
    /// main actor so its resolver closure stays in one isolation domain.
    nonisolated private static func requireDatabase(at url: URL?, name: String) async throws -> URL {
        try await ToolAvailability.requireDatabase({ url }, name: name)
    }

    private static func registryDigest() -> String? {
        let registry = ClassifierParityFixtures.stableRegistryURL
        guard FileManager.default.fileExists(atPath: registry.path) else { return nil }
        return try? ClassifierParityFixtures.sha256(of: registry)
    }

    // MARK: - Dump

    /// `LUNGFISH_PARITY_DUMP`, the folder that keeps each case's side roots and findings.
    static var dumpFolder: URL? {
        ProcessInfo.processInfo.environment["LUNGFISH_PARITY_DUMP"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// Writes the row outcome, every difference and the facts of every record of each side
    /// beside the side roots, when `LUNGFISH_PARITY_DUMP` is set.
    private func dumpIfRequested(
        _ parityCase: ClassifierParityCase,
        runs: [ClassifierParitySideRun],
        found: [ClassifierParityScope: [ClassifierParityDifference]]
    ) throws {
        guard let folder = Self.dumpFolder?.appendingPathComponent(parityCase.rawValue, isDirectory: true) else { return }
        var report: [String] = []
        for run in runs {
            report.append("side \(run.side): \(run.terminal), analysis \(run.analysisPath ?? "none")")
            if let command = run.recordedCommand { report.append("recorded command:\n\(command)") }
            if let row = run.row {
                report.append("row: \(row.title) | \(row.firstDetail) | \(row.stateLabel) | \(row.completionDetail) | error \(row.errorMessage ?? "none") | alert \(row.alertText ?? "none")")
                report += row.logLines.map { "  \($0)" }
            }
            for record in ClassifierParityComparison.recordPaths(under: run.root) {
                let facts = try ProvenanceCompatFacts.project(sidecar: run.root.appendingPathComponent(record), projectRoot: run.project)
                let target = folder.appendingPathComponent("facts-\(run.side)/\(record).facts.json")
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try facts.canonicalJSON().write(to: target)
            }
        }
        for (scope, differences) in found.sorted(by: { $0.key.description < $1.key.description }) {
            report.append("\(scope): \(differences.count)")
            report += differences.map { "  \($0)" }
        }
        try (report.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
