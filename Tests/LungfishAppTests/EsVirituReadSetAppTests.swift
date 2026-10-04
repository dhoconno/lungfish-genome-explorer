// EsVirituReadSetAppTests.swift - The EsViritu launch hands EsViritu the pairs and every read of a bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner decision 1 of 2026-10-03 (docs/contracts/READ-PAIRING.md): pairs that
// were not merged reach a tool as pairs whenever it can take them, and nothing
// is dropped. EsViritu 1.3.3 takes `-p paired` with exactly two files and
// `-p unpaired` or `-p interleaved` with exactly one. Given several files with
// `-p unpaired` it logs "must provide exactly 1 read file", writes nothing and
// exits 0, so LGE reports `detectionOutputNotProduced`.
//
// The wizard builds each sample's config, the launch resolves its inputs, and
// `EsVirituConfig.esVirituArguments()` is the argument list the pipeline hands
// EsViritu. Read names say what each read is, as in ReadSetFixtures.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class EsVirituReadSetAppTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "esviritu-read-sets-app")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("fixtures", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Samples EsViritu already runs, pinned

    func testASingleEndRootRunsUnpairedWithItsOneFile() async throws {
        let run = try await launch(fixtures.singleRoot)
        XCTAssertEqual(run.format, "unpaired")
        XCTAssertEqual(run.files, [["s1", "s2", "s3"]])
    }

    func testAnInterleavedRootRunsInterleavedWithItsOneFile() async throws {
        let run = try await launch(fixtures.interleavedRoot)
        XCTAssertEqual(run.format, "interleaved")
        XCTAssertEqual(run.files, [["i1/1", "i1/2", "i2/1", "i2/2"]])
    }

    func testAMixedRootRunsItsOneFileUnpaired() async throws {
        let run = try await launch(fixtures.mixedRoot)
        XCTAssertEqual(run.format, "unpaired")
        XCTAssertEqual(run.files, [["m1", "m2", "m3", "p1/1", "p1/2", "p2/1", "p2/2"]])
    }

    // MARK: - Pairs run as pairs and every other read runs in one file

    /// L5b. Before: `-p unpaired` with R1 and R2, which EsViritu refuses.
    func testAPairedDerivativeRunsAsAPair() async throws {
        let run = try await launch(fixtures.pairedDerivative)
        XCTAssertEqual(run.format, "paired")
        XCTAssertEqual(run.files, [["p1/1", "p2/1"], ["p1/2", "p2/2"]])
    }

    /// L5c. Before: three files with `-p unpaired`, which EsViritu refuses.
    func testAMergeDerivativeRunsEveryReadSingleEndInOneFile() async throws {
        let run = try await launch(fixtures.mergeDerivative)
        XCTAssertEqual(run.format, "unpaired")
        XCTAssertEqual(run.files.count, 1)
        XCTAssertEqual(run.files.first?.sorted(), ["u1/1", "u1/2", "x1", "x2", "x3"])
    }

    /// L5d. Before: three files with `-p unpaired`, which EsViritu refuses.
    func testARepairDerivativeRunsEveryReadSingleEndInOneFile() async throws {
        let run = try await launch(fixtures.repairDerivative)
        XCTAssertEqual(run.format, "unpaired")
        XCTAssertEqual(run.files.count, 1)
        XCTAssertEqual(run.files.first?.sorted(), ["o1", "r1/1", "r1/2", "r2/1", "r2/2"])
    }

    /// L4. Before: two files with `-p unpaired`, which EsViritu refuses.
    func testAChunkedRootRunsItsChunksJoinedInOneFile() async throws {
        let run = try await launch(fixtures.chunkedRoot)
        XCTAssertEqual(run.format, "unpaired")
        XCTAssertEqual(run.files, [["c1", "c2", "c3"]])
    }

    // MARK: - Helpers

    private struct Launch {
        /// The `-p` value EsViritu is handed.
        let format: String
        /// The record names of each file after `-r`, in argument order.
        let files: [[String]]
    }

    /// Builds the config the wizard builds for one bundle, resolves it through
    /// the app's EsViritu launch and reads the arguments EsViritu is handed.
    private func launch(_ bundle: URL) async throws -> Launch {
        let sample = try XCTUnwrap(MetagenomicsSampleGrouper.group([bundle]).first)
        let plan = EsVirituSampleReadPlan.plan(for: sample)
        let config = EsVirituConfig(
            inputFiles: sample.inputFiles,
            isPairedEnd: sample.isPairedEnd,
            sampleName: "sample",
            outputDirectory: root.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true),
            databasePath: root.appendingPathComponent("db", isDirectory: true),
            readFormat: plan.format,
            inputLayout: plan.layout
        )
        let resolved = try await AppDelegate().resolvedEsVirituConfig(
            config,
            tempDirectory: root.appendingPathComponent("inputs-\(UUID().uuidString)", isDirectory: true)
        ).verifyingInterleavedInput()
        let arguments = resolved.esVirituArguments()
        let reads = try XCTUnwrap(arguments.firstIndex(of: "-r"))
        let files = arguments[(reads + 1)...].prefix { !$0.hasPrefix("-") }
        let format = try XCTUnwrap(arguments.firstIndex(of: "-p"))
        return Launch(
            format: arguments[format + 1],
            files: try files.map { try ReadSetFixtures.readNames(in: URL(fileURLWithPath: $0)) }
        )
    }
}
