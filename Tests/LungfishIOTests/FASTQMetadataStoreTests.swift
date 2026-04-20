// FASTQMetadataStoreTests.swift - Tests for FASTQ sidecar metadata persistence
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
@testable import LungfishIO
@testable import LungfishCore

final class FASTQMetadataStoreTests: XCTestCase {

    // MARK: - Setup

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQMetadataStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Helpers

    private func makeSampleStatistics() -> FASTQDatasetStatistics {
        FASTQDatasetStatistics(
            readCount: 1000,
            baseCount: 150_000,
            meanReadLength: 150.0,
            minReadLength: 100,
            maxReadLength: 200,
            medianReadLength: 150,
            n50ReadLength: 160,
            meanQuality: 35.0,
            q20Percentage: 98.5,
            q30Percentage: 92.3,
            gcContent: 0.48,
            readLengthHistogram: [100: 50, 150: 800, 200: 150],
            qualityScoreHistogram: [30: 50000, 35: 80000, 40: 20000],
            perPositionQuality: [
                PositionQualitySummary(
                    position: 0, mean: 35.0, median: 36.0,
                    lowerQuartile: 32.0, upperQuartile: 38.0,
                    percentile10: 28.0, percentile90: 40.0
                ),
                PositionQualitySummary(
                    position: 1, mean: 34.5, median: 35.0,
                    lowerQuartile: 31.0, upperQuartile: 37.0,
                    percentile10: 27.0, percentile90: 39.0
                ),
            ]
        )
    }

    private func makeSampleSRARunInfo() -> SRARunInfo {
        SRARunInfo(
            accession: "SRR12345678",
            experiment: "SRX11111111",
            sample: "SRS22222222",
            study: "SRP33333333",
            bioproject: "PRJNA444444",
            biosample: "SAMN55555555",
            organism: "Homo sapiens",
            platform: "ILLUMINA",
            libraryStrategy: "WGS",
            librarySource: "GENOMIC",
            libraryLayout: "PAIRED",
            spots: 5_000_000,
            bases: 750_000_000,
            avgLength: 150,
            size: 1200,
            releaseDate: Date(timeIntervalSince1970: 1700000000)
        )
    }

    private func makeSampleENAReadRecord() -> ENAReadRecord {
        // Use JSON decoding since ENAReadRecord has custom CodingKeys
        let json = """
        {
            "run_accession": "ERR9876543",
            "experiment_accession": "ERX1111111",
            "sample_accession": "ERS2222222",
            "study_accession": "ERP3333333",
            "experiment_title": "Whole genome sequencing of test sample",
            "library_layout": "PAIRED",
            "library_source": "GENOMIC",
            "library_strategy": "WGS",
            "instrument_platform": "ILLUMINA",
            "base_count": 500000000,
            "read_count": 3333333
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(ENAReadRecord.self, from: json)
    }

    @discardableResult
    private func createFASTQFixture(at url: URL) -> URL {
        let fixture = "@read1\nACGT\n+\nIIII\n"
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data(fixture.utf8)
        )
        return url
    }

    // MARK: - Metadata URL Convention

    func testMetadataURLAppendsSuffix() {
        let fastqURL = tempDir.appendingPathComponent("SRR12345.fastq.gz")
        let metaURL = FASTQMetadataStore.metadataURL(for: fastqURL)

        XCTAssertEqual(metaURL.lastPathComponent, "SRR12345.fastq.gz.lungfish-meta.json")
    }

    func testMetadataURLForPlainFASTQ() {
        let fastqURL = tempDir.appendingPathComponent("reads.fastq")
        let metaURL = FASTQMetadataStore.metadataURL(for: fastqURL)

        XCTAssertEqual(metaURL.lastPathComponent, "reads.fastq.lungfish-meta.json")
    }

    // MARK: - Save and Load Round-Trip

    func testSaveAndLoadRoundTrip() {
        let fastqURL = tempDir.appendingPathComponent("test.fastq.gz")
        createFASTQFixture(at: fastqURL)
        let stats = makeSampleStatistics()
        let metadata = PersistedFASTQMetadata(
            computedStatistics: stats,
            downloadDate: Date(timeIntervalSince1970: 1700000000),
            downloadSource: "https://example.com/test.fastq.gz"
        )

        FASTQMetadataStore.save(metadata, for: fastqURL)

        let loaded = FASTQMetadataStore.load(for: fastqURL)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.computedStatistics?.readCount, 1000)
        XCTAssertEqual(loaded?.computedStatistics?.baseCount, 150_000)
        XCTAssertEqual(loaded?.computedStatistics?.meanReadLength, 150.0)
        XCTAssertEqual(loaded?.computedStatistics?.gcContent ?? 0, 0.48, accuracy: 0.001)
        XCTAssertEqual(loaded?.downloadSource, "https://example.com/test.fastq.gz")
    }

    func testSaveAndLoadWithSRAMetadata() {
        let fastqURL = tempDir.appendingPathComponent("SRR12345.fastq.gz")
        createFASTQFixture(at: fastqURL)
        let sra = makeSampleSRARunInfo()
        let metadata = PersistedFASTQMetadata(
            sraRunInfo: sra,
            downloadDate: Date(),
            downloadSource: "SRA"
        )

        FASTQMetadataStore.save(metadata, for: fastqURL)

        let loaded = FASTQMetadataStore.load(for: fastqURL)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.sraRunInfo?.accession, "SRR12345678")
        XCTAssertEqual(loaded?.sraRunInfo?.experiment, "SRX11111111")
        XCTAssertEqual(loaded?.sraRunInfo?.organism, "Homo sapiens")
        XCTAssertEqual(loaded?.sraRunInfo?.platform, "ILLUMINA")
        XCTAssertEqual(loaded?.sraRunInfo?.libraryStrategy, "WGS")
        XCTAssertEqual(loaded?.sraRunInfo?.spots, 5_000_000)
    }

    func testSaveAndLoadWithENAMetadata() {
        let fastqURL = tempDir.appendingPathComponent("ERR9876543.fastq.gz")
        createFASTQFixture(at: fastqURL)
        let ena = makeSampleENAReadRecord()
        let metadata = PersistedFASTQMetadata(
            enaReadRecord: ena,
            downloadDate: Date(),
            downloadSource: "ENA"
        )

        FASTQMetadataStore.save(metadata, for: fastqURL)

        let loaded = FASTQMetadataStore.load(for: fastqURL)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.enaReadRecord?.runAccession, "ERR9876543")
        XCTAssertEqual(loaded?.enaReadRecord?.experimentAccession, "ERX1111111")
        XCTAssertEqual(loaded?.enaReadRecord?.libraryLayout, "PAIRED")
        XCTAssertEqual(loaded?.enaReadRecord?.instrumentPlatform, "ILLUMINA")
        XCTAssertEqual(loaded?.enaReadRecord?.baseCount, 500_000_000)
    }

    func testSaveAndLoadFullMetadata() {
        let fastqURL = tempDir.appendingPathComponent("full_test.fastq.gz")
        createFASTQFixture(at: fastqURL)
        let metadata = PersistedFASTQMetadata(
            computedStatistics: makeSampleStatistics(),
            sraRunInfo: makeSampleSRARunInfo(),
            enaReadRecord: makeSampleENAReadRecord(),
            downloadDate: Date(timeIntervalSince1970: 1700000000),
            downloadSource: "NCBI SRA",
            assemblyReadType: .illuminaShortReads
        )

        FASTQMetadataStore.save(metadata, for: fastqURL)

        let loaded = FASTQMetadataStore.load(for: fastqURL)
        XCTAssertNotNil(loaded)
        XCTAssertNotNil(loaded?.computedStatistics)
        XCTAssertNotNil(loaded?.sraRunInfo)
        XCTAssertNotNil(loaded?.enaReadRecord)
        XCTAssertEqual(loaded?.assemblyReadType, .illuminaShortReads)
        XCTAssertEqual(loaded?.downloadSource, "NCBI SRA")
    }

    // MARK: - Load Nonexistent File

    func testLoadReturnsNilWhenNoSidecar() {
        let fastqURL = tempDir.appendingPathComponent("nonexistent.fastq.gz")
        let loaded = FASTQMetadataStore.load(for: fastqURL)
        XCTAssertNil(loaded)
    }

    // MARK: - Delete

    func testDeleteRemovesSidecar() {
        let fastqURL = tempDir.appendingPathComponent("delete_test.fastq.gz")
        createFASTQFixture(at: fastqURL)
        let metadata = PersistedFASTQMetadata(downloadSource: "test")

        FASTQMetadataStore.save(metadata, for: fastqURL)
        XCTAssertNotNil(FASTQMetadataStore.load(for: fastqURL))

        FASTQMetadataStore.delete(for: fastqURL)
        XCTAssertNil(FASTQMetadataStore.load(for: fastqURL))
    }

    func testDeleteNonexistentFileDoesNotCrash() {
        let fastqURL = tempDir.appendingPathComponent("no_such_file.fastq.gz")
        // Should not throw or crash
        FASTQMetadataStore.delete(for: fastqURL)
    }

    // MARK: - Overwrite

    func testSaveOverwritesExisting() {
        let fastqURL = tempDir.appendingPathComponent("overwrite_test.fastq.gz")
        createFASTQFixture(at: fastqURL)

        let metadata1 = PersistedFASTQMetadata(downloadSource: "first")
        FASTQMetadataStore.save(metadata1, for: fastqURL)

        let metadata2 = PersistedFASTQMetadata(downloadSource: "second")
        FASTQMetadataStore.save(metadata2, for: fastqURL)

        let loaded = FASTQMetadataStore.load(for: fastqURL)
        XCTAssertEqual(loaded?.downloadSource, "second")
    }

    func testSaveSkipsWhenFASTQMissing() {
        let fastqURL = tempDir.appendingPathComponent("missing.fastq.gz")
        let sidecarURL = FASTQMetadataStore.metadataURL(for: fastqURL)

        let metadata = PersistedFASTQMetadata(downloadSource: "should-not-write")
        FASTQMetadataStore.save(metadata, for: fastqURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
        XCTAssertNil(FASTQMetadataStore.load(for: fastqURL))
    }

    // MARK: - PersistedFASTQMetadata Codable

    func testPersistedMetadataEmptyCodable() throws {
        let metadata = PersistedFASTQMetadata()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistedFASTQMetadata.self, from: data)

        XCTAssertNil(decoded.computedStatistics)
        XCTAssertNil(decoded.sraRunInfo)
        XCTAssertNil(decoded.enaReadRecord)
        XCTAssertNil(decoded.downloadDate)
        XCTAssertNil(decoded.downloadSource)
    }

    func testPersistedMetadataPartialFieldsCodable() throws {
        let metadata = PersistedFASTQMetadata(
            downloadDate: Date(timeIntervalSince1970: 1700000000),
            downloadSource: "manual"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistedFASTQMetadata.self, from: data)

        XCTAssertNil(decoded.computedStatistics)
        XCTAssertNotNil(decoded.downloadDate)
        XCTAssertEqual(decoded.downloadSource, "manual")
    }

    func testPersistedMetadataAssemblyReadTypeCodable() throws {
        let metadata = PersistedFASTQMetadata(
            assemblyReadType: .pacBioHiFi
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(metadata)

        let decoded = try JSONDecoder().decode(PersistedFASTQMetadata.self, from: data)

        XCTAssertEqual(decoded.assemblyReadType, .pacBioHiFi)
    }

    func testPersistedAssemblyReadTypeDisplayNameUsesHiFiCCSLabel() {
        XCTAssertEqual(FASTQAssemblyReadType.pacBioHiFi.displayName, "PacBio HiFi/CCS")
    }

    // MARK: - SRARunInfo Codable

    func testSRARunInfoCodableRoundTrip() throws {
        let sra = makeSampleSRARunInfo()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sra)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SRARunInfo.self, from: data)

        XCTAssertEqual(decoded.accession, sra.accession)
        XCTAssertEqual(decoded.experiment, sra.experiment)
        XCTAssertEqual(decoded.sample, sra.sample)
        XCTAssertEqual(decoded.study, sra.study)
        XCTAssertEqual(decoded.bioproject, sra.bioproject)
        XCTAssertEqual(decoded.biosample, sra.biosample)
        XCTAssertEqual(decoded.organism, sra.organism)
        XCTAssertEqual(decoded.platform, sra.platform)
        XCTAssertEqual(decoded.libraryStrategy, sra.libraryStrategy)
        XCTAssertEqual(decoded.librarySource, sra.librarySource)
        XCTAssertEqual(decoded.libraryLayout, sra.libraryLayout)
        XCTAssertEqual(decoded.spots, sra.spots)
        XCTAssertEqual(decoded.bases, sra.bases)
        XCTAssertEqual(decoded.avgLength, sra.avgLength)
        XCTAssertEqual(decoded.size, sra.size)
    }

    func testSRARunInfoMinimalCodable() throws {
        let sra = SRARunInfo(
            accession: "SRR99999999",
            experiment: nil, sample: nil, study: nil,
            bioproject: nil, biosample: nil, organism: nil,
            platform: nil, libraryStrategy: nil, librarySource: nil,
            libraryLayout: nil, spots: nil, bases: nil,
            avgLength: nil, size: nil, releaseDate: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(sra)
        let decoded = try JSONDecoder().decode(SRARunInfo.self, from: data)

        XCTAssertEqual(decoded.accession, "SRR99999999")
        XCTAssertNil(decoded.experiment)
        XCTAssertNil(decoded.organism)
        XCTAssertNil(decoded.spots)
    }

    func testSRARunInfoIdentifiable() {
        let sra = makeSampleSRARunInfo()
        XCTAssertEqual(sra.id, "SRR12345678")
    }

    func testSRARunInfoSizeString() {
        let smallSRA = SRARunInfo(
            accession: "SRR1", experiment: nil, sample: nil, study: nil,
            bioproject: nil, biosample: nil, organism: nil, platform: nil,
            libraryStrategy: nil, librarySource: nil, libraryLayout: nil,
            spots: nil, bases: nil, avgLength: nil, size: 500, releaseDate: nil
        )
        XCTAssertEqual(smallSRA.sizeString, "500 MB")

        let largeSRA = SRARunInfo(
            accession: "SRR2", experiment: nil, sample: nil, study: nil,
            bioproject: nil, biosample: nil, organism: nil, platform: nil,
            libraryStrategy: nil, librarySource: nil, libraryLayout: nil,
            spots: nil, bases: nil, avgLength: nil, size: 2500, releaseDate: nil
        )
        XCTAssertEqual(largeSRA.sizeString, "2.5 GB")

        let noSizeSRA = SRARunInfo(
            accession: "SRR3", experiment: nil, sample: nil, study: nil,
            bioproject: nil, biosample: nil, organism: nil, platform: nil,
            libraryStrategy: nil, librarySource: nil, libraryLayout: nil,
            spots: nil, bases: nil, avgLength: nil, size: nil, releaseDate: nil
        )
        XCTAssertEqual(noSizeSRA.sizeString, "Unknown")
    }

    func testSRARunInfoSpotsString() {
        let fewSpots = SRARunInfo(
            accession: "SRR1", experiment: nil, sample: nil, study: nil,
            bioproject: nil, biosample: nil, organism: nil, platform: nil,
            libraryStrategy: nil, librarySource: nil, libraryLayout: nil,
            spots: 500, bases: nil, avgLength: nil, size: nil, releaseDate: nil
        )
        XCTAssertEqual(fewSpots.spotsString, "500 reads")

        let kSpots = SRARunInfo(
            accession: "SRR2", experiment: nil, sample: nil, study: nil,
            bioproject: nil, biosample: nil, organism: nil, platform: nil,
            libraryStrategy: nil, librarySource: nil, libraryLayout: nil,
            spots: 50_000, bases: nil, avgLength: nil, size: nil, releaseDate: nil
        )
        XCTAssertEqual(kSpots.spotsString, "50.0K reads")

        let mSpots = SRARunInfo(
            accession: "SRR3", experiment: nil, sample: nil, study: nil,
            bioproject: nil, biosample: nil, organism: nil, platform: nil,
            libraryStrategy: nil, librarySource: nil, libraryLayout: nil,
            spots: 5_000_000, bases: nil, avgLength: nil, size: nil, releaseDate: nil
        )
        XCTAssertEqual(mSpots.spotsString, "5.0M reads")
    }

    // MARK: - FASTQDatasetStatistics Codable (Distributions)

    func testStatisticsHistogramCodableRoundTrip() throws {
        let stats = makeSampleStatistics()

        let encoder = JSONEncoder()
        let data = try encoder.encode(stats)
        let decoded = try JSONDecoder().decode(FASTQDatasetStatistics.self, from: data)

        XCTAssertEqual(decoded.readLengthHistogram, stats.readLengthHistogram)
        XCTAssertEqual(decoded.qualityScoreHistogram, stats.qualityScoreHistogram)
        XCTAssertEqual(decoded.perPositionQuality.count, 2)
        XCTAssertEqual(decoded.perPositionQuality[0].position, 0)
        XCTAssertEqual(decoded.perPositionQuality[0].mean, 35.0, accuracy: 0.01)
        XCTAssertEqual(decoded.perPositionQuality[1].median, 35.0, accuracy: 0.01)
    }

    func testStatisticsEmptyCodable() throws {
        let stats = FASTQDatasetStatistics.empty

        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(FASTQDatasetStatistics.self, from: data)

        XCTAssertEqual(decoded.readCount, 0)
        XCTAssertEqual(decoded.baseCount, 0)
        XCTAssertTrue(decoded.readLengthHistogram.isEmpty)
        XCTAssertTrue(decoded.qualityScoreHistogram.isEmpty)
        XCTAssertTrue(decoded.perPositionQuality.isEmpty)
    }

    // MARK: - PositionQualitySummary

    func testPositionQualitySummaryEquatable() {
        let a = PositionQualitySummary(
            position: 0, mean: 35.0, median: 36.0,
            lowerQuartile: 32.0, upperQuartile: 38.0,
            percentile10: 28.0, percentile90: 40.0
        )
        let b = PositionQualitySummary(
            position: 0, mean: 35.0, median: 36.0,
            lowerQuartile: 32.0, upperQuartile: 38.0,
            percentile10: 28.0, percentile90: 40.0
        )
        XCTAssertEqual(a, b)
    }

    func testPositionQualitySummaryCodable() throws {
        let summary = PositionQualitySummary(
            position: 42, mean: 33.5, median: 34.0,
            lowerQuartile: 30.0, upperQuartile: 37.0,
            percentile10: 25.0, percentile90: 39.0
        )

        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(PositionQualitySummary.self, from: data)

        XCTAssertEqual(decoded.position, 42)
        XCTAssertEqual(decoded.mean, 33.5, accuracy: 0.01)
        XCTAssertEqual(decoded.lowerQuartile, 30.0, accuracy: 0.01)
        XCTAssertEqual(decoded.percentile90, 39.0, accuracy: 0.01)
    }

    // MARK: - ENAReadRecord Codable

    func testENAReadRecordCodableRoundTrip() throws {
        let ena = makeSampleENAReadRecord()

        let data = try JSONEncoder().encode(ena)
        let decoded = try JSONDecoder().decode(ENAReadRecord.self, from: data)

        XCTAssertEqual(decoded.runAccession, "ERR9876543")
        XCTAssertEqual(decoded.experimentAccession, "ERX1111111")
        XCTAssertEqual(decoded.sampleAccession, "ERS2222222")
        XCTAssertEqual(decoded.studyAccession, "ERP3333333")
        XCTAssertEqual(decoded.experimentTitle, "Whole genome sequencing of test sample")
        XCTAssertEqual(decoded.libraryLayout, "PAIRED")
        XCTAssertEqual(decoded.instrumentPlatform, "ILLUMINA")
        XCTAssertEqual(decoded.baseCount, 500_000_000)
        XCTAssertEqual(decoded.readCount, 3_333_333)
    }

    // MARK: - computeStatistics Integration

    func testComputeStatisticsWithTestFile() async throws {
        let url = Bundle.module.url(
            forResource: "test_reads", withExtension: "fastq", subdirectory: "Resources"
        )!

        let reader = FASTQReader()
        let (stats, samples) = try await reader.computeStatistics(from: url, sampleLimit: 100)

        // test_reads.fastq has 20 records with varying lengths
        XCTAssertEqual(stats.readCount, 20)
        XCTAssertGreaterThan(stats.baseCount, 0)
        XCTAssertGreaterThan(stats.meanReadLength, 0)
        XCTAssertGreaterThan(stats.minReadLength, 0)
        XCTAssertGreaterThanOrEqual(stats.maxReadLength, stats.minReadLength)
        XCTAssertGreaterThanOrEqual(stats.medianReadLength, stats.minReadLength)

        // Sample records should contain all 20 (less than limit of 100)
        XCTAssertEqual(samples.count, 20)
        XCTAssertEqual(samples[0].identifier, "SEQ_001")
    }

    func testComputeStatisticsSampleLimit() async throws {
        let url = Bundle.module.url(
            forResource: "test_reads", withExtension: "fastq", subdirectory: "Resources"
        )!

        let reader = FASTQReader()
        let (stats, samples) = try await reader.computeStatistics(from: url, sampleLimit: 5)

        // Stats should cover all 20 reads
        XCTAssertEqual(stats.readCount, 20)
        // But sample should be capped at 5
        XCTAssertEqual(samples.count, 5)
    }

    func testComputeStatisticsProgressCallback() async throws {
        let url = Bundle.module.url(
            forResource: "test_reads", withExtension: "fastq", subdirectory: "Resources"
        )!

        let lastProgress = OSAllocatedUnfairLock(initialState: 0)
        let reader = FASTQReader()
        let _ = try await reader.computeStatistics(from: url, sampleLimit: 100) { count in
            lastProgress.withLock { $0 = count }
        }

        // With 20 records, no 10K boundary is hit, but final progress call happens
        let finalValue = lastProgress.withLock { $0 }
        XCTAssertEqual(finalValue, 20, "Final progress callback should report 20")
    }

    func testComputeStatisticsGzipFile() async throws {
        let url = Bundle.module.url(
            forResource: "test_reads.fastq", withExtension: "gz", subdirectory: "Resources"
        )!

        let reader = FASTQReader()
        let (stats, samples) = try await reader.computeStatistics(from: url, sampleLimit: 100)

        XCTAssertEqual(stats.readCount, 20)
        XCTAssertEqual(samples.count, 20)
        XCTAssertGreaterThan(stats.meanReadLength, 0)
    }
}
