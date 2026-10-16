// TaxTriageParityLiveConformanceTests.swift - The TaxTriage parity cases on the real engine, with BIO's per-sample compare
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane Q32, with 2.10 T2 and T7, 2.11 B6, B8 and K1 and the QA ruling on 2.9 O5. No real run had
// compared side A, today's in-process GUI route, with side C, the routed `taxtriage run --project` through the
// built lungfish-cli, so the flip of the route rested on stand-in parity. This class runs the cases of
// TaxTriageParityHarness on the real engine, the managed Nextflow 26.04.6 of the live root with the docker profile
// and the Kraken2 Viral database.
//
// - X1, one sample of the virtual subset bundle, runs sides A, C and C' one after another. Side B, side A's
//   recorded command replayed in this process, stays with the stand-in class. Every real side keeps its fixed
//   facts (`fixedFactViolations`, Q31 review R1) with the side declarations of TaxTriageParityKnownDifferences,
//   and every pair compares its source manifests through `sourceManifestPolicy` (B30 vote condition 4) with
//   none declared.
// - BIO's compare (+Payloads.swift). Each sample's payload files by SHA-256, A against C and C against C', with
//   the declared differences of that file only. The folder compare of every pair and the keys in which
//   `all.odr.json` differs are written down and printed but never asserted (BIO R3), so BIO rules on them first.
// - X6 (+Cancel.swift). Side C is cancelled once a container of the run runs, and must exit 125 with a
//   `cancelled` record inside `CLIProcessLauncher.operationGrace` and leave no container in `docker ps -a`.
//
// The evidence folder (+Evidence.swift, B8). `LUNGFISH_PARITY_EVIDENCE=<folder>` names where a live run writes
// each real record's raw bytes, each sample's payload hashes and every comparison, so a later run in another
// worktree (Q32 M3) compares against them and never reads the records again through `PortablePath`. It is the
// one write outside TestTempDirectory (QA 6), because the evidence must outlive the test and its worktree. A
// case folder that exists is never written again. `LUNGFISH_PARITY_BASELINE=<folder>` names an earlier evidence
// folder, whose sides' payload hashes this run's must equal with the declared differences only.
//
// The live tests run only when the live switch is on (LUNGFISH_LIVE_NEXTFLOW_ROOT, or LUNGFISH_REQUIRE_TOOLS=1
// with LUNGFISH_STORAGE_ROOT), this process resolves its managed tools from that root, Docker answers `docker
// info`, the root holds the Kraken2 Viral database and the evidence folder is named. They never start Docker
// Desktop, and a real run takes up to 10 minutes. The stand-in tests run the same code on TaxTriageStandInEngine
// without the switch, so the compare, the evidence and the cancel's checks are shown before any real run. The
// class name holds Conformance, so only the conformance tier selects it.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class TaxTriageParityLiveConformanceTests: XCTestCase {
    var cliBinary: URL!
    private var savedCLIPath: String?

    override func setUp() async throws {
        try await super.setUp()
        let productsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        guard let cli = CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: productsDirectory) else {
            XCTFail("No lungfish-cli beside \(productsDirectory.path) and none named by LUNGFISH_CLI_PATH.")
            throw TaxTriageCLIGUIParityReplayTests.ParityError.missingCLI
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
        try await super.tearDown()
    }

    // MARK: - X1 on the real engine (M1)

    func testX1OneSampleOfTheVirtualSubsetBundleOnTheRealEngine() async throws {
        let run = try LiveNextflowRun.begin()
        let caseRoot = run.directory.appendingPathComponent(TaxTriageParityCase.x1.rawValue, isDirectory: true)
        var workFolders = [caseRoot]
        defer { XCTAssertEqual(run.teardown(engineWorkFolders: workFolders).problems, []) }
        let evidence = try TaxTriageParityEvidence.requireFolder()
        let baseline = try TaxTriageParityEvidence.baselineFolder()
        let engine = try await Self.liveEngine(run)
        let pass = try await runSides(.x1, engine: engine, caseRoot: caseRoot)
        workFolders += Self.engineWorkFolders(under: caseRoot)
        try check(pass, evidence: evidence, baseline: baseline, engineNote: "live root \(run.root.path), key \(run.key)")
    }

    // MARK: - X1 on the stand-in

    /// The X1 pass of the live test on the stand-in engine, which shows that the evidence holds each side's records
    /// and payload hashes, that a run compares clean against its own evidence as a baseline, that a changed hash
    /// fails the compare, and that a case folder is never written twice.
    func testTheX1PassAndItsEvidenceOnTheStandIn() async throws {
        let scratch = try TestTempDirectory.make(prefix: "taxtriage-parity-live")
        defer { TestTempDirectory.cleanup(scratch) }
        let caseRoot = scratch.appendingPathComponent(TaxTriageParityCase.x1.rawValue, isDirectory: true)
        let engine = try standInEngine(in: caseRoot, for: .x1)
        let pass = try await runSides(.x1, engine: engine, caseRoot: caseRoot)
        let evidence = scratch.appendingPathComponent("evidence", isDirectory: true)
        try check(pass, evidence: evidence, baseline: nil, engineNote: "stand-in")

        let written = evidence.appendingPathComponent(TaxTriageParityCase.x1.rawValue, isDirectory: true)
        let rows = try TaxTriageParityEvidence.payloadRows(in: written)
        let sample = TaxTriageParitySampleFacts.forBundle(ClassifierParityFixtures.subsetBundlePath).sampleID
        let report = "report/\(sample).odr.txt"
        let accessionMap = "combine/\(sample).combined.gcfmap.tsv"
        let topReport = "top/\(sample).top_report.tsv"
        XCTAssertEqual(rows.filter { $0.side == "A" }.map(\.key), [accessionMap, report], "side A's cleanup deleted top/")
        for side in ["C", "C'"] {
            XCTAssertEqual(rows.filter { $0.side == side }.map(\.key), [accessionMap, report, topReport], side)
        }
        XCTAssertEqual(Set(rows.map(\.sample)), [sample])
        XCTAssertEqual(rows.first { $0.key == report }?.kind, .report)
        let records = try TaxTriageParityEvidence.savedRecords(in: written)
        for side in TaxTriageParityLivePass.sides {
            XCTAssertTrue(
                records.contains { $0.hasPrefix("\(side.folderName)/") && $0.hasSuffix("/.lungfish-provenance.json") },
                "side \(side)'s root record is saved raw, \(records)"
            )
        }

        // The same pass against its own evidence as a baseline compares clean, and a second write of the case refuses.
        let again = scratch.appendingPathComponent("evidence-again", isDirectory: true)
        try check(pass, evidence: again, baseline: evidence, engineNote: "stand-in against its own evidence")
        XCTAssertThrowsError(try TaxTriageParityEvidence.write(pass, to: evidence, findings: [:], notes: []))

        // A changed hash fails the compare, by sample, kind and key.
        let sideC = try XCTUnwrap(pass.payloads[.c])
        let changed = sideC.map { $0.key == report ? $0.withSHA256(String(repeating: "0", count: 64)) : $0 }
        let differences = TaxTriageParityPayloads.differences(reference: pass.payloads[.a] ?? [], .a, candidate: changed, .c)
        XCTAssertEqual(
            TaxTriageParityPayloads.failures(found: differences, parityCase: .x1, scope: .pair(.a, .c)),
            ["not declared: report: \(sample): differs: \(report)\n        " + (differences.first { $0.id.hasSuffix(report) }?.detail ?? "")]
        )
    }

    // MARK: - One pass

    /// Runs sides A, C and C' of `parityCase` on `engine` in `caseRoot`, one after another, each from a copy of one
    /// project, and gathers every side's fixed facts, every pair's folder compare and each sample's payload hashes.
    func runSides(
        _ parityCase: TaxTriageParityCase,
        engine: TaxTriageParityEngine,
        caseRoot: URL
    ) async throws -> TaxTriageParityLivePass {
        let harness = TaxTriageParityHarness(testCase: self, cliBinary: cliBinary)
        func root(_ side: TaxTriageParitySide) -> URL {
            caseRoot.appendingPathComponent(side.folderName, isDirectory: true)
        }
        let projectA = try parityCase.makeProject(in: root(.a))
        let pristine = caseRoot.appendingPathComponent("pristine", isDirectory: true)
            .appendingPathComponent(projectA.lastPathComponent, isDirectory: true)
        let copies = [TaxTriageParitySide.c, .cPrime].map { root($0).appendingPathComponent(projectA.lastPathComponent, isDirectory: true) }
        for copy in copies + [pristine] {
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: projectA, to: copy)
        }
        let runA = try await harness.runGUISide(parityCase, root: root(.a), engine: engine)
        let runC = await harness.runRoutedSide(parityCase, root: root(.c), engine: engine)
        let runCPrime = await harness.runRecordedArgv(of: runC, parityCase, root: root(.cPrime), engine: engine)
        let runs = [runA, runC, runCPrime]

        var found: [TaxTriageParityScope: [TaxTriageParityDifference]] = [:]
        var payloads: [TaxTriageParitySide: [TaxTriageParityPayload]] = [:]
        for run in runs {
            found[.side(run.side)] = try harness.fixedFactViolations(parityCase, run: run, engine: engine, pristineProject: pristine)
            payloads[run.side] = try TaxTriageParityPayloads.payloads(of: run, parityCase: parityCase)
        }
        for (reference, candidate) in TaxTriageParityLivePass.pairs {
            let referenceRun = runs[TaxTriageParityLivePass.sides.firstIndex(of: reference)!]
            let candidateRun = runs[TaxTriageParityLivePass.sides.firstIndex(of: candidate)!]
            found[.pair(reference, candidate)] = try TaxTriageParityComparison.differences(
                reference: referenceRun, candidate: candidateRun, bundlePaths: parityCase.bundlePaths
            )
        }
        return TaxTriageParityLivePass(parityCase: parityCase, caseRoot: caseRoot, runs: runs, found: found, payloads: payloads)
    }

    /// Writes the pass's evidence first, so a failing pass still leaves it, then fails the test on every side fact
    /// the declared list does not hold, every source manifest difference and every payload difference of the
    /// report, the per-read output and the kept reads that the payload declarations do not hold.
    func check(_ pass: TaxTriageParityLivePass, evidence: URL, baseline: URL?, engineNote: String) throws {
        var findings: [String: [String]] = [:]
        for side in TaxTriageParityLivePass.sides {
            findings["side \(side)"] = TaxTriageParityKnownDifferences.failures(
                found: pass.found[.side(side)] ?? [], parityCase: pass.parityCase, scope: .side(side)
            )
        }
        for (reference, candidate) in TaxTriageParityLivePass.pairs {
            let scope = TaxTriageParityScope.pair(reference, candidate)
            findings["\(scope), source manifests"] = (pass.found[scope] ?? [])
                .filter { $0.id.hasPrefix("source manifest:") }
                .map { "not declared: \($0)" }
        }
        let comparisons = try TaxTriageParityEvidence.comparisons(pass, baseline: baseline)
        for comparison in comparisons {
            findings["\(comparison.title), payloads"] = TaxTriageParityPayloads.failures(
                found: comparison.differences, parityCase: pass.parityCase, scope: comparison.scope
            )
        }
        let folder = try TaxTriageParityEvidence.write(
            pass, to: evidence, findings: findings, comparisons: comparisons, notes: [engineNote]
        )
        print("[live-nextflow] \(pass.parityCase.rawValue) evidence in \(folder.path)")
        for line in TaxTriageParityEvidence.summary(pass) { print("[live-nextflow] \(line)") }
        for (title, failures) in findings.sorted(by: { $0.key < $1.key }) where !failures.isEmpty {
            XCTFail("\(pass.parityCase.rawValue), \(title):\n" + failures.joined(separator: "\n"))
        }
    }
}

/// What one pass of a case on sides A, C and C' left.
struct TaxTriageParityLivePass {
    /// The sides a live pass runs. Side B stays with the stand-in class.
    static let sides: [TaxTriageParitySide] = [.a, .c, .cPrime]
    /// The pairs a live pass compares, A against C, the route's switch, and C against C' both ways, the acceptance.
    static let pairs: [(TaxTriageParitySide, TaxTriageParitySide)] = [(.a, .c), (.c, .cPrime), (.cPrime, .c)]

    let parityCase: TaxTriageParityCase
    let caseRoot: URL
    /// Sides A, C and C', in that order.
    let runs: [TaxTriageParitySideRun]
    /// Each side's fixed facts it does not hold, and each pair's folder and record differences.
    let found: [TaxTriageParityScope: [TaxTriageParityDifference]]
    /// Each side's payload files, by sample.
    let payloads: [TaxTriageParitySide: [TaxTriageParityPayload]]
}
