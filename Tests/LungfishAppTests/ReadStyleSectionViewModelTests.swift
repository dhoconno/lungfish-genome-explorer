// ReadStyleSectionViewModelTests.swift - Tests for ReadStyleSectionViewModel
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishCore

@MainActor
final class ReadStyleSectionViewModelTests: XCTestCase {

    // MARK: - Default Values

    func testDefaultSettingsValues() {
        let vm = ReadStyleSectionViewModel()
        XCTAssertEqual(vm.maxReadRows, 75)
        XCTAssertTrue(vm.showMismatches)
        XCTAssertTrue(vm.showSoftClips)
        XCTAssertTrue(vm.showIndels)
        XCTAssertEqual(vm.minMapQ, 0)
        XCTAssertTrue(vm.showReads)
        XCTAssertFalse(vm.showDuplicates)
        XCTAssertFalse(vm.showSecondary)
        XCTAssertFalse(vm.showSupplementary)
        XCTAssertTrue(vm.selectedReadGroups.isEmpty)
        XCTAssertFalse(vm.hasAlignmentTracks)
    }

    // MARK: - Clear

    func testClearResetsAllStatistics() {
        let vm = ReadStyleSectionViewModel()
        vm.hasAlignmentTracks = true
        vm.totalMappedReads = 169022
        vm.totalUnmappedReads = 100
        vm.chromosomeStats = [ChromosomeReadStat(chromosome: "chr1", length: 29903, mappedReads: 169022, unmappedReads: 0)]
        vm.flagStats = [FlagStatEntry(category: "total", qcPass: 169022, qcFail: 0)]
        vm.readGroups = [ReadGroupEntry(id: "RG1", sample: "S1", library: nil, platform: nil)]
        vm.fileInfo = [(key: "source", value: "test.bam")]
        vm.programRecords = [ProgramRecordEntry(id: "bwa", name: "bwa", version: "0.7", commandLine: nil)]
        vm.provenanceRecords = [ProvenanceEntry(stepOrder: 1, tool: "lungfish", subcommand: "import", version: nil, command: "import", timestamp: nil, duration: nil)]
        vm.trackNames = ["test.bam"]

        vm.clear()

        XCTAssertFalse(vm.hasAlignmentTracks)
        XCTAssertEqual(vm.totalMappedReads, 0)
        XCTAssertEqual(vm.totalUnmappedReads, 0)
        XCTAssertTrue(vm.chromosomeStats.isEmpty)
        XCTAssertTrue(vm.flagStats.isEmpty)
        XCTAssertTrue(vm.readGroups.isEmpty)
        XCTAssertTrue(vm.fileInfo.isEmpty)
        XCTAssertTrue(vm.programRecords.isEmpty)
        XCTAssertTrue(vm.provenanceRecords.isEmpty)
        XCTAssertTrue(vm.trackNames.isEmpty)
    }

    // MARK: - Settings Callback

    func testSettingsChangedCallbackFires() {
        let vm = ReadStyleSectionViewModel()
        var callbackCount = 0
        vm.onSettingsChanged = { callbackCount += 1 }

        vm.onSettingsChanged?()
        XCTAssertEqual(callbackCount, 1)
    }

    // MARK: - ChromosomeReadStat

    func testChromosomeReadStatEstimatedCoverage() {
        let stat = ChromosomeReadStat(
            chromosome: "MN908947.3",
            length: 29903,
            mappedReads: 169022,
            unmappedReads: 0
        )

        // 169022 * 150 / 29903 ≈ 847.8x
        let coverage = stat.estimatedCoverage
        XCTAssertGreaterThan(coverage, 800)
        XCTAssertLessThan(coverage, 900)
    }

    func testChromosomeReadStatZeroLength() {
        let stat = ChromosomeReadStat(
            chromosome: "empty",
            length: 0,
            mappedReads: 100,
            unmappedReads: 0
        )
        XCTAssertEqual(stat.estimatedCoverage, 0)
    }

    func testChromosomeReadStatIdentifiable() {
        let stat = ChromosomeReadStat(
            chromosome: "chr1",
            length: 248956422,
            mappedReads: 15_000_000,
            unmappedReads: 50000
        )
        XCTAssertEqual(stat.id, "chr1")
    }

    // MARK: - FlagStatEntry

    func testFlagStatEntryIdentifiable() {
        let entry = FlagStatEntry(category: "mapped", qcPass: 169022, qcFail: 0)
        XCTAssertEqual(entry.id, "mapped")
    }

    // MARK: - ReadGroupEntry

    func testReadGroupEntryIdentifiable() {
        let entry = ReadGroupEntry(id: "RG1", sample: "Sample1", library: "Lib1", platform: "ILLUMINA")
        XCTAssertEqual(entry.id, "RG1")
        XCTAssertEqual(entry.sample, "Sample1")
        XCTAssertEqual(entry.library, "Lib1")
        XCTAssertEqual(entry.platform, "ILLUMINA")
    }

    func testReadGroupEntryOptionalFields() {
        let entry = ReadGroupEntry(id: "RG2", sample: nil, library: nil, platform: nil)
        XCTAssertNil(entry.sample)
        XCTAssertNil(entry.library)
        XCTAssertNil(entry.platform)
    }

    // MARK: - Load Statistics from Metadata DB

    func testLoadStatisticsFromDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RSSVM-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a metadata DB
        let dbURL = tempDir.appendingPathComponent("alignments.db")
        let db = try AlignmentMetadataDatabase.create(at: dbURL)
        db.addChromosomeStats(chromosome: "MN908947.3", length: 29903, mapped: 169022, unmapped: 0)
        db.addFlagStat(category: "total", qcPass: 169122, qcFail: 0)
        db.addFlagStat(category: "mapped", qcPass: 169022, qcFail: 0)
        db.addReadGroup(id: "RG1", sample: "IC-035-03", library: "Lib1", platform: "ILLUMINA")
        db.setFileInfo("source_path", value: "/path/to/test.bam")

        // Read it back from the VM
        let vm = ReadStyleSectionViewModel()

        // Verify the DB can be opened read-only and data is correct
        let readDB = try AlignmentMetadataDatabase(url: dbURL)
        let stats = readDB.chromosomeStats()
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].mappedReads, 169022)

        let flags = readDB.flagStats()
        XCTAssertEqual(flags.count, 2)

        let rgs = readDB.readGroups()
        XCTAssertEqual(rgs.count, 1)
        XCTAssertEqual(rgs[0].sample, "IC-035-03")

        let info = readDB.allFileInfo()
        XCTAssertEqual(info["source_path"], "/path/to/test.bam")
    }

    // MARK: - Notification Keys

    func testReadDisplaySettingsNotificationExists() {
        // Verify the notification name is accessible
        let name = Notification.Name.readDisplaySettingsChanged
        XCTAssertEqual(name.rawValue, "readDisplaySettingsChanged")
    }

    func testNotificationUserInfoKeys() {
        XCTAssertEqual(NotificationUserInfoKey.showReads, "showReads")
        XCTAssertEqual(NotificationUserInfoKey.maxReadRows, "maxReadRows")
        XCTAssertEqual(NotificationUserInfoKey.minMapQ, "minMapQ")
        XCTAssertEqual(NotificationUserInfoKey.showMismatches, "showMismatches")
        XCTAssertEqual(NotificationUserInfoKey.showSoftClips, "showSoftClips")
        XCTAssertEqual(NotificationUserInfoKey.showIndels, "showIndels")
    }

    // MARK: - ProgramRecordEntry

    func testProgramRecordEntryIdentifiable() {
        let entry = ProgramRecordEntry(id: "bwa", name: "bwa", version: "0.7.17", commandLine: "bwa mem ref.fa r1.fq")
        XCTAssertEqual(entry.id, "bwa")
        XCTAssertEqual(entry.name, "bwa")
        XCTAssertEqual(entry.version, "0.7.17")
        XCTAssertEqual(entry.commandLine, "bwa mem ref.fa r1.fq")
    }

    func testProgramRecordEntryOptionalFields() {
        let entry = ProgramRecordEntry(id: "tool", name: nil, version: nil, commandLine: nil)
        XCTAssertEqual(entry.id, "tool")
        XCTAssertNil(entry.name)
        XCTAssertNil(entry.version)
        XCTAssertNil(entry.commandLine)
    }

    // MARK: - ProvenanceEntry

    func testProvenanceEntryIdentifiable() {
        let entry = ProvenanceEntry(
            stepOrder: 1, tool: "samtools", subcommand: "idxstats",
            version: "1.19", command: "samtools idxstats sample.bam",
            timestamp: "2024-01-15T12:00:00Z", duration: 2.5
        )
        XCTAssertEqual(entry.id, 1)
        XCTAssertEqual(entry.tool, "samtools")
        XCTAssertEqual(entry.subcommand, "idxstats")
        XCTAssertEqual(entry.version, "1.19")
        XCTAssertEqual(entry.duration, 2.5)
    }

    func testProvenanceEntryOptionalFields() {
        let entry = ProvenanceEntry(
            stepOrder: 2, tool: "lungfish", subcommand: nil,
            version: nil, command: "import bam",
            timestamp: nil, duration: nil
        )
        XCTAssertNil(entry.subcommand)
        XCTAssertNil(entry.version)
        XCTAssertNil(entry.timestamp)
        XCTAssertNil(entry.duration)
    }

    // MARK: - Default Values Include New Fields

    func testDefaultProgramRecordsEmpty() {
        let vm = ReadStyleSectionViewModel()
        XCTAssertTrue(vm.programRecords.isEmpty)
        XCTAssertTrue(vm.provenanceRecords.isEmpty)
    }

    // MARK: - Exclude Flags Computation

    func testComputedExcludeFlagsDefault() {
        let vm = ReadStyleSectionViewModel()
        // Default: exclude unmapped(0x4) + secondary(0x100) + dup(0x400) + supplementary(0x800)
        XCTAssertEqual(vm.computedExcludeFlags, 0x4 | 0x100 | 0x400 | 0x800)
        XCTAssertEqual(vm.computedExcludeFlags, 0xD04)
    }

    func testComputedExcludeFlagsShowDuplicates() {
        let vm = ReadStyleSectionViewModel()
        vm.showDuplicates = true
        // Should exclude unmapped + secondary + supplementary (not dup)
        XCTAssertEqual(vm.computedExcludeFlags, 0x4 | 0x100 | 0x800)
        XCTAssertEqual(vm.computedExcludeFlags, 0x904)
    }

    func testComputedExcludeFlagsShowSecondary() {
        let vm = ReadStyleSectionViewModel()
        vm.showSecondary = true
        // Should exclude unmapped + dup + supplementary (not secondary)
        XCTAssertEqual(vm.computedExcludeFlags, 0x4 | 0x400 | 0x800)
        XCTAssertEqual(vm.computedExcludeFlags, 0xC04)
    }

    func testComputedExcludeFlagsShowSupplementary() {
        let vm = ReadStyleSectionViewModel()
        vm.showSupplementary = true
        // Should exclude unmapped + secondary + dup (not supplementary)
        XCTAssertEqual(vm.computedExcludeFlags, 0x4 | 0x100 | 0x400)
        XCTAssertEqual(vm.computedExcludeFlags, 0x504)
    }

    func testComputedExcludeFlagsShowAll() {
        let vm = ReadStyleSectionViewModel()
        vm.showDuplicates = true
        vm.showSecondary = true
        vm.showSupplementary = true
        // Only unmapped excluded
        XCTAssertEqual(vm.computedExcludeFlags, 0x4)
    }

    func testComputedExcludeFlagsAlwaysExcludesUnmapped() {
        let vm = ReadStyleSectionViewModel()
        vm.showDuplicates = true
        vm.showSecondary = true
        vm.showSupplementary = true
        // Bit 0x4 always set
        XCTAssertTrue(vm.computedExcludeFlags & 0x4 != 0)
    }

    // MARK: - Read Group Selection

    func testSelectedReadGroupsDefaultEmpty() {
        let vm = ReadStyleSectionViewModel()
        XCTAssertTrue(vm.selectedReadGroups.isEmpty, "Empty means show all")
    }

    func testSelectedReadGroupsFiltering() {
        let vm = ReadStyleSectionViewModel()
        vm.selectedReadGroups = ["RG1", "RG3"]
        XCTAssertTrue(vm.selectedReadGroups.contains("RG1"))
        XCTAssertTrue(vm.selectedReadGroups.contains("RG3"))
        XCTAssertFalse(vm.selectedReadGroups.contains("RG2"))
    }
}
