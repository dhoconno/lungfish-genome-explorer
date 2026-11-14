// FASTQBatchImporterRepeatedReadsTests.swift - Import warns when a project already holds the same read pairs (row RS-INSTRUMENT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// The sarscov2 fixtures stand for one library. Two imports of them under two names hold the same reads, so the second
/// import warns once in words that name both bundles, and it still imports.
final class FASTQBatchImporterRepeatedReadsTests: XCTestCase {

    private static let pairhashPySum = "ab5a1dba405f30483ea69f8ff5db4d25"
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "repeated-reads")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ImportLogEvent] = []
        func append(_ event: ImportLogEvent) { lock.withLock { stored.append(event) } }
        var notices: [String] {
            lock.withLock {
                stored.compactMap { event -> String? in
                    if case .notice(_, let message) = event { return message }
                    return nil
                }
            }
        }
    }

    private func importSarscov2(as sample: String, log: EventLog) async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/sarscov2", isDirectory: true)
        let source = root.appendingPathComponent("source-\(sample)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let first = source.appendingPathComponent("\(sample)_1.fastq.gz")
        let second = source.appendingPathComponent("\(sample)_2.fastq.gz")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("test_1.fastq.gz"), to: first)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("test_2.fastq.gz"), to: second)
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: project, platform: .auto, recipe: nil,
            qualityBinning: QualityBinningScheme.none, optimizeStorage: false, threads: 1
        )
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [SamplePair(sampleName: sample, r1: first, r2: second)], config: config,
            log: { event in log.append(event) }
        )
        XCTAssertEqual(result.completed, 1, "Errors: \(result.errors)")
    }

    private func metadata(of sample: String) throws -> PersistedFASTQMetadata {
        let bundle = project.appendingPathComponent("Imports/\(sample).lungfishfastq", isDirectory: true)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        return try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
    }

    func testImportingTheSameReadsTwiceWarnsOnce() async throws {
        let log = EventLog()
        try await importSarscov2(as: "RunA", log: log)
        XCTAssertEqual(log.notices.filter { $0.contains("one library twice") }, [], "The first import has nothing to repeat")
        try await importSarscov2(as: "RunB", log: log)
        let warnings = log.notices.filter { $0.contains("one library twice") }
        XCTAssertEqual(warnings.count, 1, "Notices: \(log.notices)")
        XCTAssertTrue(warnings[0].contains("RunA.lungfishfastq") && warnings[0].contains("RunB.lungfishfastq"), warnings[0])
        XCTAssertNotNil(try? metadata(of: "RunB"), "A warning never refuses the import")
    }

    func testTheSidecarHoldsTheHashTheCountAndTheInstrument() async throws {
        try await importSarscov2(as: "RunA", log: EventLog())
        let recorded = try XCTUnwrap(try metadata(of: "RunA").recordedReadCount)
        XCTAssertEqual(recorded.pairedR1, 100)
        XCTAssertEqual(recorded.pairHash, Self.pairhashPySum)
        let instrument = try XCTUnwrap(try metadata(of: "RunA").sequencerInstrument)
        XCTAssertEqual(instrument.instrumentIDs, ["NS500628"])
        XCTAssertEqual(instrument.runNumbers, [121])
        XCTAssertEqual(instrument.flowcells, ["HK3MMAFX2"])
        XCTAssertEqual(instrument.models, ["NextSeq 500"])
    }

    func testTheImportRecordNamesTheInstrumentAndThePairHash() async throws {
        try await importSarscov2(as: "RunA", log: EventLog())
        let bundle = project.appendingPathComponent("Imports/RunA.lungfishfastq", isDirectory: true)
        let provenanceURL = bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let data = PortablePath.resolveJSON(try Data(contentsOf: provenanceURL), forFileAt: provenanceURL)
        let options = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data).options
        XCTAssertEqual(options.resolved["instrumentIDs"], .array([.string("NS500628")]))
        XCTAssertEqual(options.resolved["instrumentModelsInferred"], .boolean(true))
        XCTAssertEqual(options.resolved["readPairHash"], .string(Self.pairhashPySum))
        XCTAssertEqual(options.resolved["readPairCount"], .integer(100))
    }
}
