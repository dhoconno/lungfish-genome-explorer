// RNASeqCellMapComputeConformanceTests.swift - X4, computed clusters repeat (Phase 5.5 lane CM-COMPUTE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The real route on 10x's full pbmc_1k_v3 filtered matrix. The test imports the staged `pbmc_1k_v3/outs` in process,
// checks the result's `source/` matrix against the staged file's sha256 (ruling ARCH-X4-INPUT item 3), and runs
// `rnaseq cell-map compute` on that result twice at threads 1 and seed 0. On a host whose record names the pin's host,
// the labels and coordinates equal CM-REPRO's pin byte for byte and the two runs are equal (tier A, 5.5 T2). Elsewhere it
// compares by meaning at the bars of ruling ADJ-SC-EMBED item 2 with BIO's items of ruling TIERB-BIO, prints the byte
// result and one of the four verdicts, and never skips. The floors of 5.5 T6 are CM-REPRO's G2 row of `claims.tsv`, made
// by the same script on the same matrix bytes, so this test computes none. A missing staged input or environment skips,
// which `--require-tools` fails.
//
// The route's environment is CM-DATA's `env-sc-embed` on the scratch disk, reached as `envs/sc-embed` of a conda root in
// the test's own folder, so nothing under the person's `~/.lungfish` is read or written.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqCellMapComputeConformanceTests: XCTestCase {
    static let cache = URL(fileURLWithPath: "/Users/Shared/lungfish-golden/cache/sc-embed-pin", isDirectory: true)
    static let outs = cache.appendingPathComponent("pbmc_1k_v3/outs", isDirectory: true)
    static let environment = URL(fileURLWithPath: "/Volumes/lge_scratch/lge/rnaseq/env-sc-embed", isDirectory: true)
    static let micromamba = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lungfish/conda/bin/micromamba")
    static let matrixSHA256 = "b80e55b5577ca56faa404f08faffbccd024119066ef194aa883708a9fe9170f6"
    static let hostKeys = ["cpu_model", "numba_cpu_name", "platform"]

    private var root: URL!

    override func setUpWithError() throws {
        for (url, what) in [(Self.outs, "the staged pbmc_1k_v3/outs"), (Self.environment, "env-sc-embed"), (Self.micromamba, "micromamba")]
        where !FileManager.default.fileExists(atPath: url.path) {
            try ToolAvailability.skipOrFail("\(what) is not at \(url.path)")
        }
        root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-compute-x4")
    }

    override func tearDownWithError() throws { if let root { TestTempDirectory.cleanup(root) } }

    /// A conda root whose `envs/sc-embed` is the scratch environment and whose `bin/micromamba` is the installed one.
    private func condaManager() throws -> CondaManager {
        let conda = root.appendingPathComponent("conda", isDirectory: true)
        try FileManager.default.createDirectory(at: conda.appendingPathComponent("envs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conda.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: conda.appendingPathComponent("envs/sc-embed"), withDestinationURL: Self.environment)
        try FileManager.default.createSymbolicLink(at: conda.appendingPathComponent("bin/micromamba"), withDestinationURL: Self.micromamba)
        return CondaManager(rootPrefix: conda)
    }

    /// The staged folder imported in process as the project's `pbmc_1k_v3`, from a copy laid out as
    /// `<project>/Inputs/pbmc_1k_v3/outs`, since the import takes the sample name from the folder above `outs/`.
    private func importedResult() async throws -> URL {
        let project = root.appendingPathComponent("x4.lungfish", isDirectory: true)
        let outs = project.appendingPathComponent("Inputs/pbmc_1k_v3/outs", isDirectory: true)
        try FileManager.default.createDirectory(at: outs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.outs, to: outs)
        let command = try ImportCommand.RNASeqSubcommand.parse([outs.path, "--project", project.path, "--name", "pbmc_1k_v3", "--quiet"])
        try await command.run()
        let result = project.appendingPathComponent("Analyses/pbmc_1k_v3.lungfishrnaseq", isDirectory: true)
        let matrix = result.appendingPathComponent("source/pbmc_1k_v3/filtered_feature_bc_matrix/matrix.mtx.gz")
        XCTAssertEqual(try RNASeqResultBundle.sha256Hex(fileAt: matrix), Self.matrixSHA256, "the import's source/ matrix is not the staged file")
        return result
    }

    private static func compute(_ parent: URL, name: String, launch: @escaping RNASeqCellMapCompute.Launch) async throws -> URL {
        let output = parent.deletingLastPathComponent().appendingPathComponent("\(name).lungfishrnaseq", isDirectory: true)
        let command = try RNASeqCellMapComputeSubcommand.parse([parent.path, "--seed", "0", "--threads", "1", "--output", output.path, "--quiet"])
        _ = try await command.compute(launch: launch) { _ in }
        return output
    }

    /// The rows of a table after its header, as bytes.
    private func body(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        return data.firstIndex(of: UInt8(ascii: "\n")).map { data[data.index(after: $0)...] } ?? Data()
    }

    /// The real launch, which also copies the route's `variable_genes.tsv` and `pca_variance_ratio.tsv` into `folder`
    /// before the run's temporary folder is removed, for the lines of TIERB-BIO item 4.
    private func keeping(_ real: @escaping RNASeqCellMapCompute.Launch, into folder: URL) -> RNASeqCellMapCompute.Launch {
        { arguments, environment, stderr in
            let result = try await real(arguments, environment, stderr)
            if let at = arguments.firstIndex(of: "--out") {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for name in ["variable_genes.tsv", "pca_variance_ratio.tsv"] {
                    try? FileManager.default.copyItem(at: URL(fileURLWithPath: arguments[at + 1]).appendingPathComponent(name),
                                                      to: folder.appendingPathComponent(name))
                }
            }
            return result
        }
    }

    func testTheRouteOnThePbmc1kV3ImportEqualsThePinOrPassesByMeaning() async throws {
        let parent = try await importedResult()
        let real = RNASeqCellMapCompute.condaLaunch(try condaManager())
        let kept = root.appendingPathComponent("kept-first", isDirectory: true)
        let first = try await Self.compute(parent, name: "x4-first", launch: keeping(real, into: kept))
        let second = try await Self.compute(parent, name: "x4-second", launch: real)
        let pin = RNASeqFixtures.root.appendingPathComponent("sc-embed-pin", isDirectory: true)
        let table = RNASeqCellMapCompute.keptTable
        let firstBody = try body(first.appendingPathComponent(table))
        XCTAssertEqual(firstBody, try body(second.appendingPathComponent(table)), "two runs at threads 1 and seed 0 differ")

        let facts = try CellMapImportFixture.facts(first)
        guard case .dictionary(let record)? = facts["routeRecord"], case .dictionary(let host)? = record["host"] else {
            return XCTFail("the record holds no route record with a host")
        }
        let pinRecord = try XCTUnwrap(try JSONSerialization.jsonObject(with: try ComputeStandIn.pinRecord) as? [String: Any])
        let pinHost = try XCTUnwrap(pinRecord["host"] as? [String: Any])
        func architecture(_ value: ParameterValue?) -> ParameterValue? {
            guard case .dictionary(let openblas)? = value else { return nil }
            return openblas["architecture"]
        }
        let pinHostValue = RNASeqCellMapCompute.parameterValue(pinHost)
        guard case .dictionary(let pinHostFields) = pinHostValue else { return XCTFail("the pin's record holds no host") }
        let sameHost = Self.hostKeys.allSatisfy { host[$0] == pinHostFields[$0] }
            && architecture(host["openblas"]) == architecture(pinHostFields["openblas"])
        let byBytes = firstBody == (try body(pin.appendingPathComponent("cells.tsv")))
        let pinValue = RNASeqCellMapCompute.parameterValue(pinRecord)
        print("X4 byte result: labels and coordinates \(byBytes ? "equal" : "differ from") the pin's by bytes; host \(sameHost ? "is" : "is not") the pin's")
        let differences = RNASeqCellMapTierB.recordDifferences(.dictionary(record), pinValue)
        print("X4 record keys that differ from the pin's, TIERB-BIO item 2's keys and TIERB-ENV's launch names aside: \(differences)")
        print("X4 launch names left out: run \(RNASeqCellMapTierB.launchNamesLeftOut(.dictionary(record))) "
              + "pin \(RNASeqCellMapTierB.launchNamesLeftOut(pinValue))")
        if sameHost {
            XCTAssertTrue(byBytes, "tier A: on the pin's host the labels and coordinates must equal the pin byte for byte")
            XCTAssertEqual(differences, [], "tier A: on the pin's host the record must equal the pin's (ruling TIERB-ENV item 4)")
            return
        }
        let verdict = try RNASeqCellMapTierB.verdict(run: first.appendingPathComponent(table), pin: pin.appendingPathComponent("cells.tsv"),
                                                    record: .dictionary(record), pinRecord: pinValue, runFolder: kept, pinFolder: pin)
        print("X4 tier B verdict: \(verdict)")
        XCTAssertFalse(verdict.hasPrefix("fail"), verdict)
    }

    /// Vote S-2: the route on a seeded synthetic matrix of 8,192 cells, the old bar of 5.5 C11, passes with exact
    /// neighbours and is never refused. The record check of the CLI holds `knn` to "kNN: exact, brute, transformer=sklearn".
    func testTheRouteComputes8192SyntheticCellsWithExactNeighbours() async throws {
        let parent = try ComputeSynthetic.result(cells: 8_192, seed: 8_192, in: root)
        let map = try await Self.compute(parent, name: "synthetic-8192", launch: RNASeqCellMapCompute.condaLaunch(try condaManager()))
        let facts = try CellMapImportFixture.facts(map)
        guard case .dictionary(let record)? = facts["routeRecord"] else { return XCTFail("the record holds no route record") }
        XCTAssertEqual(record["knn"], .string("kNN: exact, brute, transformer=sklearn"))
        let manifest = try RNASeqResultBundle.loadManifest(from: map)
        XCTAssertEqual(manifest.origin.settings, ["seed": "0", "threads": "1"])
        let table = try String(contentsOf: map.appendingPathComponent(RNASeqCellMapCompute.keptTable), encoding: .utf8)
        let rows = table.split(separator: "\n").dropFirst()
        XCTAssertEqual(rows.count, 8_192)
        let clusters = Set(rows.map { $0.split(separator: "\t").last ?? "" })
        print("X4 8,192 synthetic cells: \(rows.count) rows, \(clusters.count) Leiden clusters, knn \(record["knn"].map { "\($0)" } ?? "none")")
        XCTAssertGreaterThanOrEqual(clusters.count, 2)
    }

    /// A cancel while the route runs stops the whole tree and leaves no cell map, no stage and no temporary folder.
    func testACancelWhileTheRouteRunsLeavesNothing() async throws {
        let parent = try await importedResult()
        let real = RNASeqCellMapCompute.condaLaunch(try condaManager())
        let started = AsyncStream<Void>.makeStream()
        let launch: RNASeqCellMapCompute.Launch = { arguments, environment, stderr in
            try await real(arguments, environment) { line in
                started.continuation.yield()
                stderr(line)
            }
        }
        let output = parent.deletingLastPathComponent().appendingPathComponent("x4-cancel.lungfishrnaseq", isDirectory: true)
        let task = Task { try await Self.compute(parent, name: "x4-cancel", launch: launch) }
        Task { _ = await task.result; started.continuation.finish() }
        for await _ in started.stream { break }
        task.cancel()
        let outcome = await task.result
        XCTAssertThrowsError(try outcome.get()) { error in XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let analyses = try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
        XCTAssertEqual(analyses.filter { $0.hasPrefix(".") }, [], "a stage is left")
        let temporary = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        XCTAssertEqual(temporary.filter { $0.hasPrefix("lungfish-cell-map-compute-") }, [], "a temporary folder is left")
        // The route's argv names the parent's source/ files, which lie under this test's own folder.
        let left = try await ToolProcess.run(ToolProcessSpec(executableURL: URL(fileURLWithPath: "/usr/bin/pgrep"),
                                                             arguments: ["-f", root.lastPathComponent], environment: [:]))
        XCTAssertEqual(left.termination, .exited(code: 1), "a process of the cancelled run is left: \(left.stdoutText)")
    }
}
