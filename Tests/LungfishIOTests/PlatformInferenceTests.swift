// PlatformInferenceTests.swift - The shared sequencing-platform detector (owner decision 3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// One row per fixture in Tests/Fixtures/platform-headers. Each fixture holds
/// a real header form with synthetic bases. A wrong row here means the import
/// would label the reads with the wrong platform, which then picks the wrong
/// mapper preset, assembler and read-group platform.
final class PlatformInferenceTests: XCTestCase {

    private struct Row {
        let file: String
        let platform: SequencingPlatform
        let readClass: FASTQAssemblyReadType?
        let confidence: PlatformInference.Confidence
        var vendorDetail: String? = nil
    }

    private let rows: [Row] = [
        Row(file: "illumina-novaseq6000.fastq", platform: .illumina, readClass: .illuminaShortReads, confidence: .high),
        Row(file: "illumina-miseq-dash-flowcell.fastq", platform: .illumina, readClass: .illuminaShortReads, confidence: .high),
        Row(file: "illumina-nextseq2000-umi.fastq", platform: .illumina, readClass: .illuminaShortReads, confidence: .high),
        Row(file: "illumina-pre18.fastq", platform: .illumina, readClass: .illuminaShortReads, confidence: .high),
        Row(file: "ena-renamed-illumina.fastq", platform: .illumina, readClass: .illuminaShortReads, confidence: .high),
        Row(file: "sra-renamed-short.fastq", platform: .unknown, readClass: nil, confidence: .low),
        Row(file: "sra-renamed-long.fastq", platform: .unknown, readClass: nil, confidence: .low),
        Row(file: "element-aviti.fastq", platform: .element, readClass: .illuminaShortReads, confidence: .high),
        Row(file: "mgi-dnbseq.fastq", platform: .mgi, readClass: .illuminaShortReads, confidence: .high),
        Row(file: "iontorrent.fastq", platform: .unknown, readClass: nil, confidence: .medium, vendorDetail: "ionTorrent"),
        Row(file: "ont-minknow-full.fastq", platform: .oxfordNanopore, readClass: .ontReads, confidence: .high),
        Row(file: "ont-guppy-runid-only.fastq", platform: .oxfordNanopore, readClass: .ontReads, confidence: .high),
        Row(file: "ont-dorado-samtags-tab.fastq", platform: .oxfordNanopore, readClass: .ontReads, confidence: .high),
        Row(file: "ont-dorado-samtags-space.fastq", platform: .oxfordNanopore, readClass: .ontReads, confidence: .high),
        Row(file: "ont-uuid-only-long.fastq", platform: .oxfordNanopore, readClass: .ontReads, confidence: .medium),
        Row(file: "ont-uuid-only-short.fastq", platform: .unknown, readClass: nil, confidence: .low),
        Row(file: "pacbio-sequel2-ccs.fastq", platform: .pacbio, readClass: .pacBioHiFi, confidence: .high),
        Row(file: "pacbio-sequel2e-ccs.fastq", platform: .pacbio, readClass: .pacBioHiFi, confidence: .high),
        Row(file: "pacbio-revio-ccs.fastq", platform: .pacbio, readClass: .pacBioHiFi, confidence: .high),
        Row(file: "pacbio-ccs-bystrand.fastq", platform: .pacbio, readClass: .pacBioHiFi, confidence: .high),
        Row(file: "pacbio-subreads.fastq", platform: .pacbio, readClass: nil, confidence: .high, vendorDetail: "pacbioSubreads"),
        Row(file: "pacbio-hifi-tags.fastq", platform: .pacbio, readClass: .pacBioHiFi, confidence: .medium),
        Row(file: "zmw-word-not-pacbio.fastq", platform: .unknown, readClass: nil, confidence: .low),
        Row(file: "illumina-header-long-reads.fastq", platform: .unknown, readClass: nil, confidence: .none),
        Row(file: "mixed-ont-then-illumina.fastq", platform: .unknown, readClass: nil, confidence: .none),
    ]

    func testEveryFixtureInfersItsPlatform() {
        for row in rows {
            let url = PlatformHeaderFixtures.url(row.file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), row.file)
            let inference = PlatformInference.infer(fromFASTQ: url)
            XCTAssertEqual(inference.platform, row.platform, row.file)
            XCTAssertEqual(inference.readClass, row.readClass, row.file)
            XCTAssertEqual(inference.confidence, row.confidence, row.file)
            XCTAssertEqual(inference.vendorDetail, row.vendorDetail, row.file)
            XCTAssertEqual(inference.sampledRecords, 4, row.file)
            XCTAssertFalse(inference.evidence.isEmpty, row.file)
        }
    }

    func testSequencingPlatformDetectWrapsTheInference() {
        for row in rows {
            let expected: SequencingPlatform? = row.platform == .unknown ? nil : row.platform
            XCTAssertEqual(SequencingPlatform.detect(fromFASTQ: PlatformHeaderFixtures.url(row.file)), expected, row.file)
        }
    }

    func testEvidenceNamesTheFormAndTheCounts() {
        let dorado = PlatformInference.infer(fromFASTQ: PlatformHeaderFixtures.url("ont-dorado-samtags-tab.fastq"))
        XCTAssertEqual(dorado.evidence.first, "dorado SAM tags in 4 of 4 sampled reads.")
        XCTAssertEqual(dorado.lengthProfile, .long)
        XCTAssertEqual(dorado.maxSampledReadLength, 3050)

        let mixed = PlatformInference.infer(fromFASTQ: PlatformHeaderFixtures.url("mixed-ont-then-illumina.fastq"))
        XCTAssertTrue(mixed.evidence[0].contains("1 look like Oxford Nanopore"), mixed.evidence[0])
        XCTAssertTrue(mixed.evidence[0].contains("3 look like Illumina"), mixed.evidence[0])

        let longIllumina = PlatformInference.infer(fromFASTQ: PlatformHeaderFixtures.url("illumina-header-long-reads.fastq"))
        XCTAssertTrue(longIllumina.evidence.joined().contains("conflict"), "\(longIllumina.evidence)")

        let sraLong = PlatformInference.infer(fromFASTQ: PlatformHeaderFixtures.url("sra-renamed-long.fastq"))
        XCTAssertEqual(sraLong.lengthProfile, .long)
        XCTAssertTrue(sraLong.evidence.contains("Sampled reads are 1,800 bases long."), "\(sraLong.evidence)")
    }

    func testGzipAndBGZFGiveTheSameInferenceAsThePlainFile() {
        let plain = PlatformInference.infer(fromFASTQ: PlatformHeaderFixtures.url("ont-dorado-samtags-tab.fastq"))
        let gzip = PlatformInference.infer(fromFASTQ: PlatformHeaderFixtures.url("ont-dorado-samtags.fastq.gz"))
        let bgzf = PlatformInference.infer(fromFASTQ: PlatformHeaderFixtures.url("ont-dorado-samtags.bgzf.fastq.gz"))
        XCTAssertEqual(gzip, plain)
        XCTAssertEqual(bgzf, plain)

        let plainBytes = GzipPrefixDecoder.decodedPrefix(of: PlatformHeaderFixtures.url("ont-dorado-samtags-tab.fastq"), maxBytes: 1 << 20)
        let bgzfBytes = GzipPrefixDecoder.decodedPrefix(of: PlatformHeaderFixtures.url("ont-dorado-samtags.bgzf.fastq.gz"), maxBytes: 1 << 20)
        XCTAssertEqual(plainBytes, bgzfBytes)
    }

    func testRecordAndByteBounds() throws {
        let root = try TestTempDirectory.make(prefix: "platform-inference-bounds")
        defer { TestTempDirectory.cleanup(root) }
        let url = root.appendingPathComponent("many.fastq")
        var text = ""
        for index in 0..<40 {
            text += "@A00488:61:HMLGNDSXX:4:1101:\(index):1 1:N:0:ACGT\nACGTACGTAC\n+\nFFFFFFFFFF\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(PlatformInference.infer(fromFASTQ: url).sampledRecords, 32)
        XCTAssertEqual(PlatformInference.infer(fromFASTQ: url, maxRecords: 5).sampledRecords, 5)
        // A byte bound in the middle of the third record keeps two complete records.
        let recordBytes = text.utf8.count / 40
        XCTAssertEqual(PlatformInference.infer(fromFASTQ: url, maxBytes: recordBytes * 2 + 7).sampledRecords, 2)
    }

    func testHeaderOnlyRules() {
        XCTAssertEqual(PlatformInference.infer(fromHeader: "@d3ef25a0-5d5c-4a5f-8c3b-12345abcdef0 runid=abc123 sampleid=s1").confidence, .medium)
        XCTAssertEqual(PlatformInference.infer(fromHeader: "@read1 basecall_gpu=Tesla_V100").platform, .oxfordNanopore)
        XCTAssertNil(SequencingPlatform.detect(fromHeader: "@read1 start_time=2019-05-01T10:20:30Z"))
        XCTAssertNil(SequencingPlatform.detect(fromHeader: "@a:b:c:d:e:f:g"))
        XCTAssertEqual(SequencingPlatform.detect(fromHeader: "@sample:1:2:3:4:5:6"), .illumina)
        XCTAssertEqual(PlatformInference.infer(fromHeader: "@sample:1:2:3:4:5:6").confidence, .medium)
        XCTAssertEqual(SequencingPlatform.detect(fromHeader: "@SRR6750055.1 A00123:8:H5YNKDSXX:1:1101:1000:1000 length=151"), .illumina)
        XCTAssertEqual(PlatformInference.infer(fromHeader: "@m54006_160504_020705/4194370/0_3920").vendorDetail, "pacbioSubreads")
        XCTAssertNil(SequencingPlatform.detect(fromHeader: "@read_zmw_123"))
        XCTAssertNil(SequencingPlatform.detect(fromHeader: ""))
        XCTAssertNil(SequencingPlatform.detect(fromHeader: "@"))
        XCTAssertEqual(PlatformInference.infer(fromHeader: "@movie/12/ccs\tnp:i:3\trq:f:0.95").readClass, nil)
        XCTAssertEqual(PlatformInference.infer(fromHeader: "@movie/12/ccs\tnp:i:3\trq:f:0.95").confidence, .high)
    }

    func testAWrappedFASTQFallsBackToTheFirstHeader() throws {
        let root = try TestTempDirectory.make(prefix: "platform-inference-wrapped")
        defer { TestTempDirectory.cleanup(root) }
        let url = root.appendingPathComponent("wrapped.fastq")
        try "@m84011_220902_175841_s1/12345/ccs\nACGTACGT\nACGTACGT\n+\nIIIIIIII\nIIIIIIII\n".write(to: url, atomically: true, encoding: .utf8)
        let inference = PlatformInference.infer(fromFASTQ: url)
        XCTAssertEqual(inference.platform, .pacbio)
        XCTAssertNil(inference.lengthProfile)
    }

    func testElementOrMGIRecordedAsIlluminaIsNotSuspect() throws {
        let root = try TestTempDirectory.make(prefix: "platform-label-short-family")
        defer { TestTempDirectory.cleanup(root) }
        let legacy = PersistedFASTQMetadata(sequencingPlatform: .illumina, assemblyReadType: .illuminaShortReads)
        for fixture in ["element-aviti.fastq", "mgi-dnbseq.fastq"] {
            let fastq = try PlatformHeaderFixtures.copy(fixture, to: root)
            XCTAssertEqual(PlatformLabelCheck.check(fastqURL: fastq, metadata: legacy).verdict, .consistent, fixture)
        }
    }

    func testLengthAloneNeverNamesAPlatform() {
        let records = (0..<4).map { PlatformInference.Record(header: "@read\($0)", length: 5_000) }
        let inference = PlatformInference.infer(records: records)
        XCTAssertEqual(inference.platform, .unknown)
        XCTAssertNil(inference.readClass)
        XCTAssertEqual(inference.confidence, .low)
        XCTAssertEqual(inference.lengthProfile, .long)
    }

    // MARK: - BAM headers

    func testBAMHeaders() {
        let ont = PlatformInference.infer(fromBAM: PlatformHeaderFixtures.url("ont-dorado.bam"))
        XCTAssertEqual(ont.platform, .oxfordNanopore)
        XCTAssertEqual(ont.readClass, .ontReads)
        XCTAssertEqual(ont.confidence, .high)

        let pacbio = PlatformInference.infer(fromBAM: PlatformHeaderFixtures.url("pacbio-hifi.bam"))
        XCTAssertEqual(pacbio.platform, .pacbio)
        XCTAssertEqual(pacbio.readClass, .pacBioHiFi)

        let illumina = PlatformInference.infer(fromBAM: PlatformHeaderFixtures.url("illumina-paired.bam"))
        XCTAssertEqual(illumina.platform, .illumina)
        XCTAssertEqual(illumina.readClass, .illuminaShortReads)

        let unlabelled = PlatformInference.infer(fromBAM: PlatformHeaderFixtures.url("unlabelled.bam"))
        XCTAssertEqual(unlabelled.platform, .unknown)
        XCTAssertEqual(unlabelled.confidence, .none)

        XCTAssertNil(PlatformInference.bamHeaderText(at: PlatformHeaderFixtures.url("ont-dorado-samtags.fastq.gz")))
    }

    // MARK: - Sidecar

    func testUnknownPlatformRawValuesDecodeAsUnknownAndKeepTheSidecar() throws {
        let json = Data(#"{"sequencingPlatform":"ionTorrent","assemblyReadType":"ontReads","downloadSource":"x"}"#.utf8)
        let decoded = try JSONDecoder().decode(PersistedFASTQMetadata.self, from: json)
        XCTAssertEqual(decoded.sequencingPlatform, .unknown)
        XCTAssertEqual(decoded.assemblyReadType, .ontReads)
        XCTAssertEqual(decoded.downloadSource, "x")
    }

    func testPlatformAssignmentRoundTripsAndLegacySidecarsLoad() throws {
        let root = try TestTempDirectory.make(prefix: "platform-assignment")
        defer { TestTempDirectory.cleanup(root) }
        let fastq = try PlatformHeaderFixtures.copy("ont-dorado-samtags-tab.fastq", to: root)
        let inference = PlatformInference.infer(fromFASTQ: fastq)
        let assignment = PlatformAssignment(inferred: inference, recordedAt: Date(timeIntervalSince1970: 1_800_000_000))
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore, assemblyReadType: .ontReads, platformAssignment: assignment),
            for: fastq
        )
        let loaded = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertEqual(loaded.platformAssignment, assignment)
        XCTAssertEqual(loaded.platformAssignment?.source, .inferred)
        XCTAssertEqual(loaded.platformAssignment?.detectorVersion, PlatformInference.detectorVersion)

        let legacy = try JSONDecoder().decode(
            PersistedFASTQMetadata.self,
            from: Data(#"{"sequencingPlatform":"illumina","assemblyReadType":"illuminaShortReads"}"#.utf8)
        )
        XCTAssertNil(legacy.platformAssignment)
    }

    // MARK: - Suspect labels

    func testLegacyIlluminaLabelOnNanoporeReadsIsSuspect() throws {
        let root = try TestTempDirectory.make(prefix: "platform-label-check")
        defer { TestTempDirectory.cleanup(root) }
        let fastq = try PlatformHeaderFixtures.copy("ont-dorado-samtags-tab.fastq", to: root)

        let legacy = PersistedFASTQMetadata(sequencingPlatform: .illumina, assemblyReadType: .illuminaShortReads)
        let suspect = PlatformLabelCheck.check(fastqURL: fastq, metadata: legacy)
        XCTAssertEqual(suspect.verdict, .suspect)
        XCTAssertEqual(suspect.suggestedPlatform, .oxfordNanopore)
        XCTAssertTrue(suspect.reasons[0].contains("Oxford Nanopore"), suspect.reasons[0])

        var decided = legacy
        decided.platformAssignment = PlatformAssignment(source: .userConfirmed, platform: .illumina, readClass: .illuminaShortReads)
        XCTAssertEqual(PlatformLabelCheck.check(fastqURL: fastq, metadata: decided).verdict, .decided)

        let agreeing = PersistedFASTQMetadata(sequencingPlatform: .oxfordNanopore, assemblyReadType: .ontReads)
        XCTAssertEqual(PlatformLabelCheck.check(fastqURL: fastq, metadata: agreeing).verdict, .consistent)
        XCTAssertEqual(PlatformLabelCheck.check(fastqURL: fastq, metadata: nil).verdict, .unlabelled)
    }

    func testShortReadLabelOnLongReadStatisticsIsSuspect() throws {
        let root = try TestTempDirectory.make(prefix: "platform-label-length")
        defer { TestTempDirectory.cleanup(root) }
        let fastq = try PlatformHeaderFixtures.copy("sra-renamed-long.fastq", to: root)
        var metadata = PersistedFASTQMetadata(sequencingPlatform: .illumina, assemblyReadType: .illuminaShortReads)
        metadata.computedStatistics = FASTQDatasetStatistics(
            readCount: 4, baseCount: 7_200,
            meanReadLength: 1_800, minReadLength: 1_800, maxReadLength: 1_800,
            medianReadLength: 1_800, n50ReadLength: 1_800,
            meanQuality: 20, q20Percentage: 50, q30Percentage: 10,
            gcContent: 0.5,
            readLengthHistogram: [:], qualityScoreHistogram: [:],
            perPositionQuality: []
        )
        let check = PlatformLabelCheck.check(fastqURL: fastq, metadata: metadata)
        XCTAssertEqual(check.verdict, .suspect)
        XCTAssertNil(check.suggestedPlatform)
    }
}
