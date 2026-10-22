// FASTQBatchImporterHashOnceTests.swift - An import's record reads each large file once (CHTC lane L7-HASHONCE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import LungfishWorkflow
import LungfishCore
import LungfishIO

/// Counts, per resolved path, how many times the provenance hasher was about to read a file.
private final class HashReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ url: URL) {
        lock.withLock { counts[url.resolvingSymlinksInPath().path, default: 0] += 1 }
    }

    func count(of url: URL) -> Int {
        lock.withLock { counts[url.resolvingSymlinksInPath().path, default: 0] }
    }

    var all: [String: Int] { lock.withLock { counts } }
}

/// The records stage of a paired import through a five step recipe, the stretch L6-O10 measured at 660.7 s because
/// it read each 30 GB input 8 times and the staged payload 6 times. The fixture is small, the counts are the same.
final class FASTQBatchImporterHashOnceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQBatchImporterHashOnce-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private struct Staging {
        let bundle: URL
        let fastq: URL
        let metadata: URL
    }

    private struct Fixture {
        let pair: SamplePair
        let config: FASTQBatchImporter.ImportConfig
        let publishedBundle: URL
        let publishedFASTQ: URL
        let workspaceOutput: URL
        let recipeSteps: [RecipeStepResult]
        let r1Bytes: Data
        let r2Bytes: Data
        let payloadBytes: Data
        let metadataBytes: Data
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeFixture() throws -> Fixture {
        let inputs = tempDir.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let r1Bytes = Data("@p1/1\nACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIII\n@p2/1\nTGCATGCATGCATGCA\n+\nIIIIIIIIIIIIIIII\n".utf8)
        let r2Bytes = Data("@p1/2\nTGCATGCATGCATGCA\n+\nIIIIIIIIIIIIIIII\n@p2/2\nACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIII\n".utf8)
        let pair = SamplePair(
            sampleName: "sample",
            r1: inputs.appendingPathComponent("sample_R1.fastq"),
            r2: inputs.appendingPathComponent("sample_R2.fastq")
        )
        try r1Bytes.write(to: pair.r1)
        try r2Bytes.write(to: try XCTUnwrap(pair.r2))

        let project = tempDir.appendingPathComponent("Project.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let publishedBundle = imports.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        let workspace = project.appendingPathComponent(".tmp/fastq-import-fixture", isDirectory: true)

        func stepOutput(_ name: String) -> [RecipeStepOutputFile] {
            [RecipeStepOutputFile(
                path: workspace.appendingPathComponent(name).path,
                checksumSHA256: String(repeating: "ab", count: 32),
                sizeBytes: 100
            )]
        }
        func step(_ name: String, _ tool: String, outputs: [RecipeStepOutputFile]) -> RecipeStepResult {
            RecipeStepResult(
                stepName: name, tool: tool, toolVersion: "1.0",
                commandArguments: [tool, "-i", pair.r1.path, "-I", pair.r2?.path ?? ""],
                durationSeconds: 1, executionOutputFiles: outputs, exitStatus: 0
            )
        }
        // Three steps carry the digests of their outputs, as the recipe engine records them. The seqkit step
        // carries none, so the record names the staged payload for it. Statistics and storage are not recipe steps.
        let recipeSteps = [
            step("Adapter + quality trim", "fastp", outputs: stepOutput("step1.fastq")),
            step("Remove human reads", "deacon", outputs: stepOutput("step2.fastq")),
            step("Remove short reads", "seqkit", outputs: []),
            step("Merge overlapping pairs", "fastp", outputs: stepOutput("step4.fastq")),
            step("Optimize storage + Compress", "clumpify", outputs: []),
            step("Compute statistics", "seqkit", outputs: []),
        ]
        return Fixture(
            pair: pair,
            config: FASTQBatchImporter.ImportConfig(
                projectDirectory: project, platform: .illumina,
                qualityBinning: QualityBinningScheme.none, optimizeStorage: false, threads: 2
            ),
            publishedBundle: publishedBundle,
            publishedFASTQ: publishedBundle.appendingPathComponent("sample.fastq.gz"),
            workspaceOutput: workspace.appendingPathComponent("sample.fastq.gz"),
            recipeSteps: recipeSteps,
            r1Bytes: r1Bytes,
            r2Bytes: r2Bytes,
            payloadBytes: Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }),
            metadataBytes: Data("{\"fixture\":\"metadata\"}\n".utf8)
        )
    }

    private func makeStaging(for fixture: Fixture, name: String) throws -> Staging {
        let imports = fixture.publishedBundle.deletingLastPathComponent()
        let bundle = imports.appendingPathComponent(".sample.building-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastq = bundle.appendingPathComponent("sample.fastq.gz")
        try fixture.payloadBytes.write(to: fastq)
        let metadata = FASTQMetadataStore.metadataURL(for: fastq)
        try fixture.metadataBytes.write(to: metadata)
        return Staging(bundle: bundle, fastq: fastq, metadata: metadata)
    }

    /// Writes the record of one sample the way `processSingleSample` does after the statistics step.
    private func writeRecord(_ fixture: Fixture, _ staging: Staging) async throws -> ProvenanceEnvelope {
        let ingestion = FASTQIngestionResult(
            outputFile: fixture.workspaceOutput,
            wasClumpified: false,
            qualityBinning: .none,
            originalFilenames: ["sample_R1.fastq", "sample_R2.fastq"],
            originalSizeBytes: Int64(fixture.r1Bytes.count + fixture.r2Bytes.count),
            finalSizeBytes: Int64(fixture.payloadBytes.count),
            pairingMode: .pairedEnd
        )
        let statsAt = Date()
        try await FASTQBatchImporter.writeImportProvenance(
            pair: fixture.pair,
            processingPair: fixture.pair,
            materializationSteps: [],
            unpairedReads: nil,
            config: fixture.config,
            importedPairing: .init(mode: .interleaved, source: .detected),
            stagingBundleURL: staging.bundle,
            stagingBundleFASTQURL: staging.fastq,
            publishedBundleURL: fixture.publishedBundle,
            publishedBundleFASTQURL: fixture.publishedFASTQ,
            sourceIngestionOutputURL: fixture.workspaceOutput,
            ingestionResult: ingestion,
            recipeStepResults: fixture.recipeSteps,
            runClock: ProvenanceRunClock(),
            statsStartedAt: statsAt,
            statsCompletedAt: statsAt,
            statsError: nil
        )
        let loaded = try ProvenanceEnvelopeReader.load(from: staging.bundle)
        return try XCTUnwrap(loaded)
    }

    /// Every descriptor the record holds, in the order it holds them.
    private func descriptors(of envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        envelope.files + envelope.outputs + envelope.steps.flatMap { $0.inputs + $0.outputs }
    }

    /// The scope `runBatchImport` gives one command.
    private func underCommandScope<T>(_ body: () async throws -> T) async rethrows -> T {
        try await ProvenanceDigestCache.scoped { try await body() }
    }

    func testRecordsStageReadsEachInputAndThePayloadOnce() async throws {
        let fixture = try makeFixture()
        let staging = try makeStaging(for: fixture, name: "once")
        let log = HashReadLog()

        _ = try await ProvenanceFileHasher.$readObserver.withValue({ log.record($0) }) {
            try await underCommandScope { try await writeRecord(fixture, staging) }
        }

        XCTAssertEqual(log.count(of: fixture.pair.r1), 1, "R1 is read once per import, whatever the recipe has for steps")
        XCTAssertEqual(log.count(of: try XCTUnwrap(fixture.pair.r2)), 1, "R2 is read once per import")
        XCTAssertEqual(log.count(of: staging.fastq), 1, "the staged payload is read once per import")
        XCTAssertEqual(log.count(of: staging.metadata), 1, "the payload's metadata sidecar is read once per import")
        XCTAssertEqual(log.all.values.max(), 1, "no file is read twice: \(log.all)")
    }

    func testRecordHoldsTheSameDigestsWhenEachFileIsReadOnce() async throws {
        let fixture = try makeFixture()
        let before = try await writeRecord(fixture, try makeStaging(for: fixture, name: "before")) // every site hashes
        let after = try await underCommandScope { try await writeRecord(fixture, try makeStaging(for: fixture, name: "after")) }

        let beforeDescriptors = descriptors(of: before)
        XCTAssertFalse(beforeDescriptors.isEmpty)
        XCTAssertEqual(descriptors(of: after), beforeDescriptors, "digest by digest, size by size, role by role")
        XCTAssertEqual(after.steps.map(\.toolName), before.steps.map(\.toolName))

        let digestsByPath = Dictionary(
            beforeDescriptors.compactMap { descriptor in descriptor.checksumSHA256.map { (descriptor.path, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(digestsByPath[fixture.pair.r1.path], sha256Hex(fixture.r1Bytes))
        XCTAssertEqual(digestsByPath[try XCTUnwrap(fixture.pair.r2).path], sha256Hex(fixture.r2Bytes))
        XCTAssertEqual(digestsByPath[fixture.publishedFASTQ.path], sha256Hex(fixture.payloadBytes))
        XCTAssertEqual(
            digestsByPath[FASTQMetadataStore.metadataURL(for: fixture.publishedFASTQ).path],
            sha256Hex(fixture.metadataBytes)
        )
    }

    func testRunBatchImportRunsUnderOneFreshDigestCachePerCommand() async throws {
        let fixture = try makeFixture()
        let log = DigestCacheLog()

        // An empty batch still logs .importStart inside the command's scope and needs no tool.
        for _ in 0..<2 {
            _ = await FASTQBatchImporter.runBatchImport(
                pairs: [], config: fixture.config,
                log: { _ in log.append(ProvenanceDigestCache.current) }
            )
        }

        let seen = log.all
        XCTAssertFalse(seen.isEmpty, "the command logs from inside its scope")
        XCTAssertTrue(seen.allSatisfy { $0 != nil }, "the command runs with a cache bound")
        var distinct: [ProvenanceDigestCache] = []
        for cache in seen.compactMap({ $0 }) where !distinct.contains(where: { $0 === cache }) {
            distinct.append(cache)
        }
        XCTAssertEqual(distinct.count, 2, "no cache is shared between commands")
        XCTAssertNil(ProvenanceDigestCache.current, "nothing outlives the command")
    }
}

/// Keeps, in order, the cache each log event of a command saw. It holds them strongly, so no address is reused.
private final class DigestCacheLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ProvenanceDigestCache?] = []

    func append(_ cache: ProvenanceDigestCache?) { lock.withLock { seen.append(cache) } }
    var all: [ProvenanceDigestCache?] { lock.withLock { seen } }
}
