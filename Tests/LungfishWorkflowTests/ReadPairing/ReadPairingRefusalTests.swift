// ReadPairingRefusalTests.swift - Each read-pairing refusal Phase 1.5 added, reached from a real input
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Final review B note 12. Phase 1.5 added refusals that were checked only
// for reachability. Every one without a test is reached here from the input
// that triggers it, through the entry point a tool calls, and its message
// is checked. The lane report names the refusals that already had a test,
// and the one no input reaches, with the reason.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ReadPairingRefusalTests: XCTestCase {
    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "read-pairing-refusals")
        fixtures = try ReadSetFixtures(in: root)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Kraken2

    /// kraken2 takes one pair of files per sample, so a bundle of two pairs
    /// of files stops the run rather than leave a pair out.
    func testKraken2RefusesASampleOfTwoPairsOfFiles() async throws {
        let bundle = try mixedBundle("two-pairs", roles: [
            ("a_R1", .pairedR1, "a/1"), ("a_R2", .pairedR2, "a/2"),
            ("b_R1", .pairedR1, "b/1"), ("b_R2", .pairedR2, "b/2"),
        ])
        var config = ClassificationConfig(
            inputFiles: [bundle], isPairedEnd: false, databaseName: "Viral",
            databasePath: root.appendingPathComponent("db"), outputDirectory: scratch()
        )
        let plan = try await KrakenReadSetPlanner.plan(
            bundle: bundle, materializedInputs: [], materializationDirectory: scratch()
        )

        XCTAssertThrowsError(try KrakenReadSetPlanner.apply(plan, to: &config)) { error in
            XCTAssertEqual(error as? KrakenReadSetPlannerError, .severalMatePairs(count: 2))
            XCTAssertTrue(error.localizedDescription.contains("2 separate R1 and R2 pairs of files"), error.localizedDescription)
        }
    }

    /// The planner reads a virtual bundle from the file the caller already
    /// materialized. Both callers always pass that one file (`conda classify`
    /// its execution input, the app its resolved file), so only a caller
    /// that passes none reaches this guard.
    func testKraken2RefusesAVirtualBundleWithNoMaterializedFile() async throws {
        let bundle = fixtures.subsetOfMerge.standardizedFileURL
        do {
            _ = try await KrakenReadSetPlanner.plan(bundle: bundle, materializedInputs: [], materializationDirectory: scratch())
            XCTFail("a virtual bundle with no materialized file must be refused")
        } catch let error as KrakenReadSetPlannerError {
            guard case .noMaterializedInput(let path) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(path.hasSuffix(bundle.lastPathComponent), path)
            XCTAssertTrue(error.localizedDescription.contains("was not materialized before it was planned"))
        }
    }

    /// Files of single reads run beside a pair. A config that names them
    /// without a pair is refused by its own validation.
    func testAKraken2ConfigWithSingleReadFilesAndNoPairIsRefused() throws {
        let merged = fixtures.mergeDerivative.appendingPathComponent("merged.fastq")
        var config = ClassificationConfig(
            inputFiles: [merged], isPairedEnd: false, databaseName: "Viral",
            databasePath: root, outputDirectory: scratch()
        )
        config.singleReadFiles = [merged]

        XCTAssertThrowsError(try config.validate()) { error in
            guard case .singleReadFilesNeedAPair = error as? ClassificationConfigError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(error.localizedDescription, "Files of single reads run beside an R1 and R2 pair, and this run has no pair")
        }
    }

    // MARK: - The resolver and the materializer

    /// A bundle that lists more R1 files than R2 files cannot pair them.
    func testABundleWithUnmatchedMateFilesIsRefused() async throws {
        let bundle = try mixedBundle("unmatched", roles: [
            ("a_R1", .pairedR1, "a/1"), ("b_R1", .pairedR1, "b/1"), ("a_R2", .pairedR2, "a/2"),
        ])
        do {
            _ = try await KrakenReadSetPlanner.plan(bundle: bundle, materializedInputs: [], materializationDirectory: scratch())
            XCTFail("unmatched mate files must be refused")
        } catch let error as ReadSetResolverError {
            XCTAssertEqual(error, .unmatchedMateFiles(bundlePath: bundle.standardizedFileURL.path, r1Files: 2, r2Files: 1))
            XCTAssertTrue(error.localizedDescription.contains("2 R1 file(s) and 1 R2 file(s)"), error.localizedDescription)
        }
    }

    /// Materializing a mixed bundle reads every file it lists, so a listed
    /// file that is gone, or an R1 file with no R2 file, stops it.
    func testMaterializingAMixedBundleRefusesAMissingOrUnpartneredRoleFile() async throws {
        let missing = try mixedBundle("missing-merged", roles: [
            ("u_R1", .pairedR1, "u1/1"), ("u_R2", .pairedR2, "u1/2"), ("merged", .merged, "x1"),
        ])
        try FileManager.default.removeItem(at: missing.appendingPathComponent("merged.fastq"))
        let unpartnered = try mixedBundle("unpartnered", roles: [
            ("u_R1", .pairedR1, "u1/1"), ("v_R1", .pairedR1, "v1/1"), ("u_R2", .pairedR2, "u1/2"),
        ])
        let materializer = FASTQCLIMaterializer(runner: .shared)
        for (bundle, detail) in [
            (missing, "merged.fastq (merged) is listed but does not exist"),
            (unpartnered, "2 paired R1 file(s) are listed with 1 paired R2 file(s)"),
        ] {
            do {
                _ = try await materializer.materialize(bundleURL: bundle, tempDirectory: scratch(), progress: nil)
                XCTFail("\(bundle.lastPathComponent) must be refused")
            } catch let error as FASTQCLIMaterializerError {
                guard case .roleFileMissing(let message) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(message.contains(detail), message)
                XCTAssertTrue(error.localizedDescription.hasPrefix("The mixed bundle cannot be read whole"))
            }
        }
    }

    // MARK: - EsViritu and TaxTriage

    /// The planner reads a virtual bundle from the file its caller
    /// materialized, so a caller that passes none is refused.
    func testTheSamplesheetPlannerRefusesAVirtualBundleWithNoMaterializedFile() async throws {
        let bundle = fixtures.subsetOfMerge.standardizedFileURL
        for consumerID in [EsVirituConfig.readPairingConsumerID, TaxTriageReadSetPlanner.consumerID] {
            do {
                _ = try await SamplesheetReadSetPlanner.plan(
                    input: bundle, consumerID: consumerID, materializedInputs: [], materializationDirectory: scratch()
                )
                XCTFail("\(consumerID): a virtual bundle with no materialized file must be refused")
            } catch let error as SamplesheetReadSetPlannerError {
                guard case .noMaterializedInput(let path) = error else { return XCTFail("\(consumerID): \(error)") }
                XCTAssertTrue(path.hasSuffix(bundle.lastPathComponent), path)
            }
        }
    }

    /// A sample of several files of single reads is joined into one file,
    /// and the joined files must be exactly the files the plan found. A file
    /// the bundle holds but does not list would be joined too, so the run
    /// stops rather than read reads the plan never saw.
    func testTheSamplesheetPlannerRefusesAJoinThatDiffersFromItsPlan() async throws {
        let bundle = try mixedBundle("singles", roles: [("merged", .merged, "x1"), ("orphans", .unpaired, "o1")])
        try ReadSetFixtures.fastq(["stray1"]).write(
            to: bundle.appendingPathComponent("stray.fastq"), atomically: true, encoding: .utf8
        )
        do {
            let readSet = try await SamplesheetReadSetPlanner.plan(
                input: bundle,
                consumerID: EsVirituConfig.readPairingConsumerID,
                materializationDirectory: scratch(),
                materializer: fixtures.materializer
            )
            XCTFail("the join must not read a file the plan did not find, got \(readSet.executionURLs)")
        } catch let error as SamplesheetReadSetPlannerError {
            XCTAssertEqual(error, .joinedFilesDiffer(bundlePath: bundle.standardizedFileURL.path))
        }
    }

    // MARK: - Viral Recon

    /// viralrecon's Nanopore mode copies FASTQ files, and a virtual bundle
    /// lists only its preview, so it is refused before anything is written.
    func testViralReconNanoporeStagingRefusesAVirtualBundle() throws {
        let bundle = fixtures.subsetOfMerge
        let directory = scratch()
        let sample = ViralReconSample(
            sampleName: "virtual",
            sourceBundleURL: bundle,
            fastqURLs: [bundle.appendingPathComponent("preview.fastq")],
            barcode: nil,
            sequencingSummaryURL: nil
        )

        XCTAssertThrowsError(try ViralReconSamplesheetBuilder.stageNanoporeInputs(samples: [sample], in: directory)) { error in
            XCTAssertEqual(error as? ViralReconSamplesheetBuilder.ValidationError, .virtualNanoporeBundle(bundle))
            XCTAssertTrue(error.localizedDescription.contains("lungfish-cli fastq materialize"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "nothing is written")
    }

    /// A paired bundle whose R1 and R2 files hold different numbers of reads
    /// cannot be staged as pairs for viralrecon.
    func testViralReconRefusesAPairedBundleWhoseMateFilesDifferInLength() async throws {
        let bundle = fixtures.importsURL.appendingPathComponent("uneven.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try ReadSetFixtures.fastq(["p1/1", "p2/1"]).write(to: bundle.appendingPathComponent("s_R1.fastq"), atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["p1/2"]).write(to: bundle.appendingPathComponent("s_R2.fastq"), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .interleaveReformat)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "uneven",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "s_R1.fastq",
                payload: .fullPaired(r1Filename: "s_R1.fastq", r2Filename: "s_R2.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 3, baseCount: 30),
                pairingMode: .pairedEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        let sample = ViralReconSample(
            sampleName: "uneven", sourceBundleURL: bundle,
            fastqURLs: [bundle.appendingPathComponent("s_R1.fastq"), bundle.appendingPathComponent("s_R2.fastq")],
            barcode: nil, sequencingSummaryURL: nil
        )
        let directory = scratch()

        do {
            _ = try await ViralReconReadPairing.stageBundle(
                of: sample, bundleURL: bundle, into: directory, materializer: fixtures.materializer, progress: nil
            )
            XCTFail("mate files of different lengths must be refused")
        } catch let error as ViralReconReadPairing.PairingError {
            guard case .bundleStagingFailed(let name, let reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, "uneven")
            XCTAssertEqual(reason, "its R1 file holds 2 reads and its R2 file holds 1")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "the staging folder is removed")
    }

    // MARK: - Fixtures

    private func scratch() -> URL {
        root.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
    }

    /// A `fullMixed` bundle with one file per role entry, each holding one read.
    private func mixedBundle(_ name: String, roles: [(file: String, role: ReadClassification.FileRole, read: String)]) throws -> URL {
        let bundle = fixtures.importsURL.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for entry in roles {
            try ReadSetFixtures.fastq([entry.read]).write(
                to: bundle.appendingPathComponent("\(entry.file).fastq"), atomically: true, encoding: .utf8
            )
        }
        let classification = ReadClassification(files: roles.map {
            .init(filename: "\($0.file).fastq", role: $0.role, readCount: 1)
        })
        let operation = FASTQDerivativeOperation(kind: .pairedEndRepair)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: name,
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "\(roles[0].file).fastq",
                payload: .fullMixed(classification),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: roles.count, baseCount: Int64(roles.count * 10)),
                pairingMode: .pairedEnd,
                readClassification: nil,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }
}
