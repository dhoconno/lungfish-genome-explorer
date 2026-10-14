// NakedBundleReferenceParityReplayTests.swift - The variant-only reference download, in process against lungfish-cli
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A44 M3, review A44-M2d rulings M3-1 to M3-3, panel decisions C4 and G5, on lane
// Q30's harness. A VCF imported with no reference leaves a variant-only bundle in the project, and
// the app then downloads the reference and merges it into that bundle. Each case runs on three
// sides that start as copies of one project holding such a bundle.
//
// - Side A is the in-process route the hidden key keeps for one release. The app finds the
//   assembly, builds its bundle in the project's `.tmp` folder and merges the genome and
//   annotations in.
// - Side C is the CLI route. The app finds the assembly the same way, records the command and
//   launches `fetch genome <accession> --into-bundle <bundle> --format json` through
//   `CLISubprocessTransport`.
// - Side C' is the harness's replay of the command side C recorded.
//
// Both routes read the loopback NCBI stand-in, which the process environment names. The record
// side C writes in the bundle's `genome/` folder must name each output it lists with that file's
// digest (B-5), and no other record may reach the bundle.
//
// The GenBank fallback has no case yet. It stays in process on both routes, because `fetch genome`
// builds the record's bundle with differences BIO has not signed (ruling M3-2, lane A44 M3 report).
//
// It launches the built lungfish-cli and the managed bgzip and samtools, so its name ends in
// ReplayTests, which sends it to the integration tier.

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class NakedBundleReferenceParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        /// The VCF's header names the assembly by its accession.
        case assemblyByAccession
        /// The VCF names an assembly the app finds by organism and assembly name (ruling M3-1).
        case assemblyByName
    }

    static let closer = "2.11, which deletes the in-process reference download with its key (C4)"

    /// What side C writes that side A does not, and the reverse, with BIO's reason.
    static let declared: [RouteParityDeclaredDifference<Case>] = [
        RouteParityDeclaredDifference(
            [.assemblyByAccession: 1, .assemblyByName: 1],
            "only in C: Project.lungfish/Cohort calls.lungfishref/genome/.lungfish-provenance.json",
            reason: "fetch genome --into-bundle writes the record of what it fetched, each file with its source URL, "
                + "digest and size (B-3), in the genome folder it merged. The in-process route writes no record, the "
                + "declared difference that keeps its key (C4).",
            closedBy: closer
        ),
    ]

    /// What the import found in the VCF, the input of a case.
    struct Input: Sendable {
        let inferredRef: ReferenceInference.Result
        let ncbiAccessions: [String]
        /// The VCF's one chromosome.
        let chromosome: String
        /// The accession the app finds, which side C's command names.
        let fetched: String
    }

    static func input(of parityCase: Case) -> Input {
        switch parityCase {
        case .assemblyByAccession:
            return Input(
                inferredRef: reference(assembly: "StandInAsm1", accession: NCBIGenomeStandIn.assemblyAccession),
                ncbiAccessions: ["NC_000001.1"], chromosome: "NC_000001.1", fetched: NCBIGenomeStandIn.assemblyAccession)
        case .assemblyByName:
            return Input(
                inferredRef: reference(assembly: "StandInAsm1", accession: nil),
                ncbiAccessions: ["NC_000001.1"], chromosome: "NC_000001.1", fetched: NCBIGenomeStandIn.assemblyAccession)
        }
    }

    static func reference(assembly: String, accession: String?) -> ReferenceInference.Result {
        ReferenceInference.Result(
            assembly: assembly,
            organism: "Lungfish stand-in organism",
            accession: accession,
            namingConvention: "RefSeq",
            confidence: .high,
            sequenceCount: 1,
            totalLength: 150
        )
    }

    // MARK: - Cases

    /// The VCF names the assembly's accession. Both routes find it by that accession, and the CLI
    /// merges the same genome and annotations and writes its record.
    func testTheAssemblyTheVCFNamesMergesTheSameGenomeOnBothRoutes() async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let runs = try await runParity(.assemblyByAccession, cli: cli, root: root)
        try Self.assertRecordedMerge(runs, of: .assemblyByAccession)
    }

    /// Ruling M3-1. The VCF names an assembly but no accession. The app still finds it by organism
    /// and assembly name on both routes, and the CLI fetches the accession it found.
    func testTheAssemblyFoundByNameMergesTheSameGenomeOnBothRoutes() async throws {
        let (cli, root) = try await prepare()
        defer { TestTempDirectory.cleanup(root) }
        let runs = try await runParity(.assemblyByName, cli: cli, root: root)
        try Self.assertRecordedMerge(runs, of: .assemblyByName)
    }

    // MARK: - Running a case

    /// Runs `parityCase` on its three sides in `root` against the stand-in and checks that C
    /// against C' lists nothing, A against C exactly the declared entries, and every side merged.
    func runParity(_ parityCase: Case, cli: URL, root: URL) async throws -> RouteParityRuns {
        let server = try await NCBIGenomeStandIn.start(servingIn: root.appendingPathComponent("served", isDirectory: true))
        defer { server.stop() }
        let saved = ProcessEnvironmentOverride(
            set: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString], unset: ["NCBI_API_KEY"])
        defer { saved.restore() }

        let input = Self.input(of: parityCase)
        let harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
        let runs = try await harness.run(
            in: root.appendingPathComponent("case", isDirectory: true),
            fixture: { try Self.makeProject($0, chromosome: input.chromosome) },
            sideA: { try await Self.side($0, route: .legacy, input: input, cli: nil) },
            sideC: { try await Self.side($0, route: .cli, input: input, cli: cli) }
        )
        let result = try harness.evaluate(parityCase, declared: Self.declared, runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(parityCase)")
        for run in runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(
            runs.cPrime.replayedArguments.map { Array($0.prefix(3)) }, [["fetch", "genome", input.fetched]],
            "side C' replays the one fetch genome command side C recorded")
        return runs
    }

    /// One side, the site's download on `route` into the side's variant-only bundle, and the
    /// command its row recorded.
    static func side(_ root: URL, route: NakedBundleReferenceRoute, input: Input, cli: URL?) async throws -> RouteParitySideOutcome {
        let recorded = RecordedCommandBox()
        do {
            let found = try await MainSplitViewController.downloadNakedBundleReference(
                inferredRef: input.inferredRef,
                ncbiAccessions: input.ncbiAccessions,
                bundleURL: bundle(in: root),
                operationID: UUID(),
                route: route,
                cliURLOverride: cli
            ) { recorded.set($0) }
            return RouteParitySideOutcome(
                end: found ? .completed : .failed, detail: found ? "merged" : "no reference found",
                recordedCommand: recorded.value)
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: recorded.value)
        }
    }

    /// B-5 and the merge's own record. On each CLI side the one record in the bundle is the run's,
    /// in `genome/`, which names the accession fetched and each output with the digest it has, so
    /// no record of the builder's staging reached the bundle. Side A writes none.
    static func assertRecordedMerge(_ runs: RouteParityRuns, of parityCase: Case) throws {
        let fetched = input(of: parityCase).fetched
        XCTAssertEqual(try recordPaths(in: bundle(in: runs.a.root)), [], "side A writes no record")
        for run in [runs.c, runs.cPrime] {
            let target = bundle(in: run.root)
            XCTAssertEqual(try recordPaths(in: target), ["genome/.lungfish-provenance.json"], "side \(run.side)")
            let genome = target.appendingPathComponent("genome", isDirectory: true)
            let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: genome), "side \(run.side) wrote no record")
            XCTAssertTrue(envelope.argv.contains(fetched), "side \(run.side): \(envelope.argv)")
            XCTAssertFalse(envelope.outputs.isEmpty, "side \(run.side)")
            for output in envelope.outputs {
                let url = URL(fileURLWithPath: output.path)
                XCTAssertTrue(output.path.contains("/Cohort calls.lungfishref/"), "side \(run.side): \(output.path)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "side \(run.side): \(output.path)")
                let stated = try XCTUnwrap(output.checksumSHA256, "side \(run.side): \(output.path)")
                XCTAssertEqual(try ProvenanceFileHasher.sha256(of: url), stated, "side \(run.side): \(output.path)")
            }
        }
    }

    // MARK: - Fixture and readers

    /// The built CLI and a scratch root, or a skip without the managed tools.
    func prepare() async throws -> (cli: URL, root: URL) {
        do {
            try await GenomeDownloadBundleBuilder(ncbiService: NCBIService(apiKey: nil, environment: [:])).validateTools()
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        return (cli, try TestTempDirectory.make(prefix: "naked-reference-parity"))
    }

    /// A project holding the bundle a VCF import with no reference leaves, one variant on
    /// `chromosome`, a variant track and no genome.
    static func makeProject(_ root: URL, chromosome: String) throws {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try FetchGenomeCLIBundlePinConformanceTests.makeVariantOnlyBundle(in: project, chromosome: chromosome)
    }

    /// The variant-only bundle of a side root.
    static func bundle(in root: URL) -> URL {
        root.appendingPathComponent("Project.lungfish/Cohort calls.lungfishref", isDirectory: true)
    }

    /// Every provenance record in `bundle`, by its path in the bundle.
    static func recordPaths(in bundle: URL) throws -> [String] {
        let names = FileManager.default.enumerator(atPath: bundle.path)?.compactMap { $0 as? String } ?? []
        return names.filter { $0.hasSuffix(ProvenanceRecorder.provenanceFilename) }.sorted()
    }
}

/// The command a side's row recorded, set from the download's task.
private final class RecordedCommandBox: Sendable {
    private let command = Mutex<String?>(nil)

    func set(_ value: String) {
        command.withLock { $0 = value }
    }

    var value: String? {
        command.withLock { $0 }
    }
}
