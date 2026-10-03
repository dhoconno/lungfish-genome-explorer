// FASTQBatchImporterPlatformTests.swift - What `import fastq` records when no platform is given
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishIO
import LungfishTestSupport

/// End-to-end imports of the platform-header fixtures with `--platform auto`.
/// Before platform inference, every one of these except the MinKNOW header
/// imported as Illumina short reads and was clumpified, which then chose
/// short-read mappers and assemblers for long reads.
final class FASTQBatchImporterPlatformTests: XCTestCase {

    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "import-platform")
        project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private struct Imported {
        let metadata: PersistedFASTQMetadata
        let envelope: ProvenanceEnvelope
    }

    private func importFixture(
        _ fixture: String,
        sample: String,
        platform: ImportPlatformRequest = .auto,
        events: EventLog? = nil
    ) async throws -> Imported {
        let source = root.appendingPathComponent("source-\(sample)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let reads = try PlatformHeaderFixtures.copy(fixture, to: source, as: "\(sample).fastq")
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: project,
            platform: platform,
            recipe: nil,
            qualityBinning: QualityBinningScheme.none,
            threads: 1
        )
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [SamplePair(sampleName: sample, r1: reads, r2: nil)],
            config: config,
            log: { event in events?.append(event) }
        )
        XCTAssertEqual(result.completed, 1, "Errors: \(result.errors)")
        return try loadImported(sample: sample)
    }

    private func loadImported(sample: String) throws -> Imported {
        let bundle = project.appendingPathComponent("Imports/\(sample).lungfishfastq", isDirectory: true)
        let fastq = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle))
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        let provenanceURL = bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let data = PortablePath.resolveJSON(try Data(contentsOf: provenanceURL), forFileAt: provenanceURL)
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
        return Imported(metadata: metadata, envelope: envelope)
    }

    private func value(after flag: String, in argv: [String]?) -> String? {
        guard let argv, let index = argv.firstIndex(of: flag), argv.indices.contains(index + 1) else { return nil }
        return argv[index + 1]
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ImportLogEvent] = []
        func append(_ event: ImportLogEvent) { lock.withLock { stored.append(event) } }
        var events: [ImportLogEvent] { lock.withLock { stored } }
    }

    func testDoradoSAMTagReadsImportAsNanoporeWithTheEvidence() async throws {
        let log = EventLog()
        let imported = try await importFixture("ont-dorado-samtags-tab.fastq", sample: "Dorado", events: log)
        XCTAssertEqual(imported.metadata.sequencingPlatform, .oxfordNanopore)
        XCTAssertEqual(imported.metadata.assemblyReadType, .ontReads)
        XCTAssertEqual(imported.metadata.platformAssignment?.source, .inferred)
        XCTAssertEqual(imported.metadata.platformAssignment?.confidence, .high)
        XCTAssertEqual(imported.metadata.ingestion?.isClumpified, false)

        let options = imported.envelope.options
        XCTAssertEqual(options.explicit["platform"], .string("ont"))
        XCTAssertEqual(options.explicit["platformSource"], .string("inferred"))
        XCTAssertEqual(options.explicit["platformConfidence"], .string("high"))
        XCTAssertEqual(options.defaults["platform"], .string("auto"))
        XCTAssertEqual(value(after: "--platform", in: imported.envelope.argv), "auto")
        XCTAssertEqual(value(after: "--platform", in: imported.envelope.durableReplayArgv), "ont")

        let resolved = log.events.compactMap { event -> String? in
            if case .platformResolved(let sample, let platform, let source, _, _, _, _) = event {
                return "\(sample) \(platform) \(source)"
            }
            return nil
        }
        XCTAssertEqual(resolved, ["Dorado ont inferred"])
    }

    func testRevioCCSImportsAsPacBioHiFi() async throws {
        let imported = try await importFixture("pacbio-revio-ccs.fastq", sample: "Revio")
        XCTAssertEqual(imported.metadata.sequencingPlatform, .pacbio)
        XCTAssertEqual(imported.metadata.assemblyReadType, .pacBioHiFi)
        XCTAssertEqual(imported.metadata.ingestion?.isClumpified, false)
        XCTAssertEqual(value(after: "--platform", in: imported.envelope.durableReplayArgv), "pacbio")
    }

    func testUnrecognisedHeadersImportAsUnknownWithNoReadType() async throws {
        let imported = try await importFixture("sra-renamed-short.fastq", sample: "Spots")
        XCTAssertEqual(imported.metadata.sequencingPlatform, .unknown)
        XCTAssertNil(imported.metadata.assemblyReadType)
        XCTAssertEqual(imported.metadata.ingestion?.isClumpified, false)
        XCTAssertEqual(imported.metadata.platformAssignment?.confidence, .low)
        XCTAssertEqual(value(after: "--platform", in: imported.envelope.durableReplayArgv), "unknown")
    }

    func testElementReadsRecordElementWithTheShortReadClass() async throws {
        let imported = try await importFixture("element-aviti.fastq", sample: "Aviti")
        XCTAssertEqual(imported.metadata.sequencingPlatform, .element)
        XCTAssertEqual(imported.metadata.assemblyReadType, .illuminaShortReads)
        XCTAssertEqual(value(after: "--platform", in: imported.envelope.durableReplayArgv), "element")
    }

    func testABatchLabelsEachSampleFromItsOwnReads() async throws {
        let source = root.appendingPathComponent("batch", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let nano = try PlatformHeaderFixtures.copy("ont-minknow-full.fastq", to: source, as: "Nano.fastq")
        let short = try PlatformHeaderFixtures.copy("illumina-novaseq6000.fastq", to: source, as: "Short.fastq")
        let config = FASTQBatchImporter.ImportConfig(
            projectDirectory: project, platform: .auto, recipe: nil,
            qualityBinning: QualityBinningScheme.none, optimizeStorage: false, threads: 1
        )
        let result = await FASTQBatchImporter.runBatchImport(
            pairs: [SamplePair(sampleName: "Nano", r1: nano, r2: nil), SamplePair(sampleName: "Short", r1: short, r2: nil)],
            config: config
        )
        XCTAssertEqual(result.completed, 2, "Errors: \(result.errors)")
        XCTAssertEqual(try loadImported(sample: "Nano").metadata.sequencingPlatform, .oxfordNanopore)
        XCTAssertEqual(try loadImported(sample: "Short").metadata.sequencingPlatform, .illumina)
    }

    func testAGivenPlatformIsObeyedAndAContradictionIsReported() async throws {
        let log = EventLog()
        let imported = try await importFixture(
            "ont-dorado-samtags-tab.fastq", sample: "Given", platform: .given(.illumina), events: log
        )
        XCTAssertEqual(imported.metadata.sequencingPlatform, .illumina)
        XCTAssertEqual(imported.metadata.assemblyReadType, .illuminaShortReads)
        XCTAssertEqual(imported.metadata.platformAssignment?.source, .given)
        XCTAssertEqual(imported.envelope.options.explicit["platformSource"], .string("given"))
        XCTAssertEqual(value(after: "--platform", in: imported.envelope.argv), "illumina")

        let notices = log.events.compactMap { event -> String? in
            if case .notice(_, let message) = event { return message }
            return nil
        }
        XCTAssertTrue(notices.contains { $0.contains("Oxford Nanopore") }, "\(notices)")
    }

    // MARK: - Request parsing and BAM input

    func testPlatformRequestVocabulary() {
        XCTAssertEqual(ImportPlatformRequest(cliValue: "auto"), .auto)
        XCTAssertEqual(ImportPlatformRequest(cliValue: "ont"), .given(.oxfordNanopore))
        XCTAssertEqual(ImportPlatformRequest(cliValue: "nanopore"), .given(.oxfordNanopore))
        XCTAssertEqual(ImportPlatformRequest(cliValue: "oxford-nanopore"), .given(.oxfordNanopore))
        XCTAssertEqual(ImportPlatformRequest(cliValue: "oxfordNanopore"), .given(.oxfordNanopore))
        XCTAssertEqual(ImportPlatformRequest(cliValue: "PacBio"), .given(.pacbio))
        XCTAssertEqual(ImportPlatformRequest(cliValue: "element"), .given(.element))
        XCTAssertEqual(ImportPlatformRequest(cliValue: "mgi"), .given(.mgi))
        XCTAssertEqual(ImportPlatformRequest(cliValue: "unknown"), .given(.unknown))
        XCTAssertNil(ImportPlatformRequest(cliValue: "sanger"))
        XCTAssertEqual(
            LungfishIO.SequencingPlatform.allCases.map(\.importCLIValue),
            ["illumina", "ont", "pacbio", "element", "ultima", "mgi", "unknown"]
        )
    }

    func testPacBioBAMIsRefusedAndAnUnlabelledBAMIsNot() async throws {
        let pacbio = SamplePair(sampleName: "hifi", r1: PlatformHeaderFixtures.url("pacbio-hifi.bam"), r2: nil)
        XCTAssertEqual(FASTQBatchImporter.resolvePlatform(for: pacbio, request: .auto).platform, .pacbio)
        do {
            _ = try await ONTBAMImportMaterializer.materializeIfNeeded(pair: pacbio, platform: .pacbio, workspace: root)
            XCTFail("A PacBio BAM import must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("PacBio BAM import is not supported"), error.localizedDescription)
        }

        let unlabelled = SamplePair(sampleName: "plain", r1: PlatformHeaderFixtures.url("unlabelled.bam"), r2: nil)
        XCTAssertEqual(FASTQBatchImporter.resolvePlatform(for: unlabelled, request: .auto).platform, .unknown)
        let ont = SamplePair(sampleName: "ont", r1: PlatformHeaderFixtures.url("ont-dorado.bam"), r2: nil)
        XCTAssertEqual(FASTQBatchImporter.resolvePlatform(for: ont, request: .auto).platform, .oxfordNanopore)
        XCTAssertNoThrow(try ONTBAMImportMaterializer.checkPlatform(.unknown, for: unlabelled))
        XCTAssertNoThrow(try ONTBAMImportMaterializer.checkPlatform(.oxfordNanopore, for: ont))
    }
}
