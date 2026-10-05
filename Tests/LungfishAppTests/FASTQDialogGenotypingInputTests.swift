// FASTQDialogGenotypingInputTests.swift - The FASTQ Operations dialog genotypes each bundle as one sample of every read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTQ Operations dialog resolved a genotyping bundle into its files
// before it ran `lungfish-cli fastq genotype`, so a paired derivative ran as
// two samples (R1 and R2) and a merge derivative as three. The dialog now
// hands the CLI the bundle, as the Workflow Operations dialog does, and the
// CLI plans it with the read-set resolver (Phase 1.5 lane A6b, finding D5).

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class FASTQDialogGenotypingInputTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-dialog-genotyping-input")
        root = root.resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// The paired and the merge derivative each reach `fastq genotype` as the
    /// bundle, the run's command and the Operations row name that bundle, and
    /// the CLI genotypes it as one sample holding every read.
    func testAPairedAndAMergeDerivativeGenotypeOneSampleOfEveryReadAndTheCommandNamesTheBundle() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("read-sets", isDirectory: true))
        let reference = root.appendingPathComponent("reference.fa")
        try ">allele1\nACGTACGTAC\n".write(to: reference, atomically: true, encoding: .utf8)
        let cases: [(URL, [String])] = [
            (fixtures.pairedDerivative, ["p1/1", "p1/2", "p2/1", "p2/2"]),
            (fixtures.mergeDerivative, ["u1/1", "u1/2", "x1", "x2", "x3"]),
        ]
        for (bundle, reads) in cases {
            let name = bundle.deletingPathExtension().lastPathComponent
            let request = FASTQOperationLaunchRequest.ontGenotyping(request: ONTBarcodeDemuxGenotypingRunRequest(
                inputFASTQURLs: [bundle],
                referenceSourceURL: reference,
                outputDirectory: root.appendingPathComponent("\(name).lungfishgenotype", isDirectory: true),
                outputName: name,
                analysisName: name,
                threads: 1,
                minSupport: 1,
                mode: .illuminaPaired,
                readType: .illumina
            ))
            let spy = GenotypeInvocationSpy()
            let service = FASTQOperationExecutionService(commandRunner: spy)
            let work = root.appendingPathComponent("work-\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            _ = try? await service.execute(request: request, workingDirectory: work)

            let invocation = try XCTUnwrap(spy.invocations.first, name)
            XCTAssertEqual(spy.invocations.count, 1, name)
            let run = try Self.genotypeCommand(invocation)
            XCTAssertEqual(run.inputs, [bundle.path], "\(name): the run hands the CLI the bundle")
            let row = try Self.genotypeCommand(try service.buildInvocation(for: request))
            XCTAssertEqual(row.inputs, run.inputs, "\(name): the Operations row names what the run read")

            let staging = root.appendingPathComponent("staging-\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let samples = try await ONTBarcodeDemuxGenotypingPipeline.resolveIlluminaSampleInputsForTesting(
                from: run.inputs.map { URL(fileURLWithPath: $0) },
                stagingDirectory: staging
            )
            XCTAssertEqual(samples.map { $0.sampleID }, [name], "\(name): one sample, named for the bundle")
            XCTAssertEqual(try ReadSetFixtures.readNames(in: try XCTUnwrap(samples.first).fastqURL), reads, name)
        }
    }

    /// Final review A, S2. Two ONT barcode bundles that were each imported
    /// from several files reach `fastq genotype --mode ont-sample-bundles` as
    /// the bundles, and the CLI genotypes each one as one sample of every
    /// chunk, joined in import order. The run used to stop with a message
    /// about Illumina inputs.
    func testTwoONTChunkedBundlesGenotypeOneSampleEachOfEveryChunk() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("ont-chunks", isDirectory: true))
        let reference = root.appendingPathComponent("reference.fa")
        try ">allele1\nACGTACGTAC\n".write(to: reference, atomically: true, encoding: .utf8)
        let bundles = [fixtures.nanoporeChunkedRoot, fixtures.chunkedRoot]
        let request = FASTQOperationLaunchRequest.ontGenotyping(request: ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: bundles,
            referenceSourceURL: reference,
            outputDirectory: root.appendingPathComponent("ont.lungfishgenotype", isDirectory: true),
            outputName: "ont",
            analysisName: "ont",
            threads: 1,
            minSupport: 1,
            mode: .ontSampleBundles,
            readType: .ont
        ))
        let spy = GenotypeInvocationSpy()
        let service = FASTQOperationExecutionService(commandRunner: spy)
        let work = root.appendingPathComponent("work-ont", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        _ = try? await service.execute(request: request, workingDirectory: work)

        let run = try Self.genotypeCommand(try XCTUnwrap(spy.invocations.first))
        XCTAssertEqual(run.inputs, bundles.map(\.path), "the run hands the CLI the bundles")
        XCTAssertEqual(run.mode, "ont-sample-bundles")

        let staging = root.appendingPathComponent("staging-ont", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let samples = try await ONTBarcodeDemuxGenotypingPipeline.resolveIlluminaSampleInputsForTesting(
            from: run.inputs.map { URL(fileURLWithPath: $0) },
            stagingDirectory: staging,
            readType: .ont
        )
        XCTAssertEqual(samples.map { $0.sampleID }, ["nanopore", "chunked"])
        XCTAssertEqual(try samples.map { try ReadSetFixtures.readNames(in: $0.fastqURL) }, [["o-a", "o-b", "o-c"], ["c1", "c2", "c3"]])
    }

    /// `invocation` parsed by the shipped `lungfish-cli fastq genotype` parser.
    private static func genotypeCommand(_ invocation: FASTQCLIInvocation) throws -> FastqGenotypingSubcommand {
        XCTAssertEqual(invocation.subcommand, "fastq")
        XCTAssertEqual(invocation.arguments.first, "genotype")
        return try FastqGenotypingSubcommand.parse(Array(invocation.arguments.dropFirst()))
    }
}

/// Keeps every invocation the dialog's execution service launches.
private final class GenotypeInvocationSpy: @unchecked Sendable, FASTQOperationCommandRunning {
    private let lock = NSLock()
    private var recorded: [FASTQCLIInvocation] = []

    var invocations: [FASTQCLIInvocation] { lock.withLock { recorded } }

    func run(
        invocation: FASTQCLIInvocation,
        outputDirectory: URL,
        progress: @escaping FASTQOperationProgressHandler
    ) async throws -> FASTQCLIExecutionResult {
        lock.withLock { recorded.append(invocation) }
        return FASTQCLIExecutionResult(outputURLs: [outputDirectory])
    }
}
