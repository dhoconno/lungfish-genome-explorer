import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ONTBAMImportMaterializerTests: XCTestCase {
    func testNonBAMPassesThroughWithoutConversion() async throws {
        let pair = SamplePair(
            sampleName: "sample",
            r1: URL(fileURLWithPath: "/tmp/sample.fastq.gz"),
            r2: nil
        )

        let result = try await ONTBAMImportMaterializer.materializeIfNeeded(
            pair: pair,
            platform: .ont,
            workspace: URL(fileURLWithPath: "/tmp")
        )

        XCTAssertEqual(result.processingPair.r1, pair.r1)
        XCTAssertTrue(result.provenanceSteps.isEmpty)
    }

    /// Only PacBio BAM is refused (owner ruling 4). A BAM given another
    /// platform used to be refused as "only for Oxford Nanopore".
    func testOnlyPacBioBAMIsRefused() async {
        let pair = SamplePair(sampleName: "sample", r1: URL(fileURLWithPath: "/tmp/sample.bam"), r2: nil)
        do {
            _ = try await ONTBAMImportMaterializer.materializeIfNeeded(
                pair: pair,
                platform: IngestionPlatform.pacbio,
                workspace: URL(fileURLWithPath: "/tmp")
            )
            XCTFail("Expected a PacBio BAM import to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("PacBio BAM import is not supported"))
        }
        XCTAssertNoThrow(try ONTBAMImportMaterializer.checkPlatform(.illumina, for: pair))
    }

    func testBAMCannotBeUsedAsOneHalfOfAPair() async {
        let pair = SamplePair(
            sampleName: "mixed",
            r1: URL(fileURLWithPath: "/tmp/mixed_R1.fastq.gz"),
            r2: URL(fileURLWithPath: "/tmp/mixed_R2.bam")
        )

        do {
            _ = try await ONTBAMImportMaterializer.materializeIfNeeded(
                pair: pair,
                platform: .ont,
                workspace: URL(fileURLWithPath: "/tmp")
            )
            XCTFail("Expected the mixed FASTQ/BAM pair to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("must be a single file"))
        }
    }

    func testBAMMaterializesCompressedFASTQAndRecordsBothTools() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ONTBAMImportMaterializerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let bamURL = root.appendingPathComponent("reads.bam")
        try Data([0x42, 0x41, 0x4d]).write(to: bamURL)

        let samtools = root.appendingPathComponent(".lungfish/conda/envs/samtools/bin/samtools")
        let pigz = root.appendingPathComponent(".lungfish/conda/envs/pigz/bin/pigz")
        try installScript(at: samtools, body: """
        if [ "${1:-}" = "--version" ]; then echo "samtools 1.23"; exit 0; fi
        printf '@read1\\nACGT\\n+\\nIIII\\n'
        """)
        try installScript(at: pigz, body: """
        if [ "${1:-}" = "--version" ]; then echo "pigz 2.8"; exit 0; fi
        for argument in "$@"; do input="$argument"; done
        /usr/bin/gzip -c "$input"
        """)

        let result = try await ONTBAMImportMaterializer.materializeIfNeeded(
            pair: SamplePair(sampleName: "reads", r1: bamURL, r2: nil),
            platform: .ont,
            workspace: workspace,
            threads: 3,
            runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: root, appIdentity: .preview)
        )

        XCTAssertEqual(result.processingPair.r1.lastPathComponent, "reads-from-bam.fastq.gz")
        XCTAssertGreaterThan(try fileSize(result.processingPair.r1), 0)
        XCTAssertEqual(result.provenanceSteps.map(\.toolName), ["samtools", "pigz"])
        XCTAssertEqual(result.provenanceSteps[0].inputs.first?.format, .bam)
        XCTAssertTrue(result.provenanceSteps[0].command.contains(String(ONTBAMImportMaterializer.primaryReadFlagFilter)))
        XCTAssertTrue(result.provenanceSteps[1].command.contains("3"))
        XCTAssertEqual(result.provenanceSteps[0].durableReplayArgv?.first, "/bin/sh")
        XCTAssertTrue(result.provenanceSteps[0].durableReplayArgv?.last?.contains(" > ") == true)
    }

    // MARK: - Mates of a BAM that is not grouped by name

    /// Five pairs sorted by coordinate, so no record sits next to its mate,
    /// plus a supplementary record. One pair has its read 2 first.
    private static let coordinateSortedPairs: [BamFixtureBuilder.Read] = {
        func read(_ fragment: Int, _ flag: Int, _ position: Int) -> BamFixtureBuilder.Read {
            BamFixtureBuilder.Read(
                qname: "A00488:61:HMLGNDSXX:4:1101:1000:\(fragment)", flag: flag, rname: "chr1",
                pos: position, mapq: 60, cigar: "8M", seq: "ACGTTGCA", qual: "IIIIIIII"
            )
        }
        return [
            read(1, 99, 100), read(1, 147, 300),
            read(2, 99, 150), read(2, 147, 350),
            read(3, 83, 400), read(3, 163, 50),
            read(4, 99, 500), read(4, 147, 700),
            read(5, 99, 600), read(5, 147, 800),
            read(1, 2145, 900),
        ]
    }()

    private func managedSamtools() async throws -> URL {
        guard await NativeToolRunner.shared.isToolAvailable(.samtools),
              await NativeToolRunner.shared.isToolAvailable(.pigz) else {
            throw XCTSkip("The managed samtools and pigz are required")
        }
        return try await NativeToolRunner.shared.findTool(.samtools)
    }

    private func gunzipped(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }

    private func samtoolsFASTQ(_ samtools: URL, bam: URL) throws -> Data {
        let process = Process()
        process.executableURL = samtools
        process.arguments = ["fastq", "-F", String(ONTBAMImportMaterializer.primaryReadFlagFilter), bam.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }

    /// A paired BAM sorted by coordinate keeps the mates of each fragment
    /// apart. It is collated first, so its mates reach the importer adjacent
    /// and are recorded as interleaved. Before the fix the ten records
    /// imported as ten single reads.
    func testACoordinateSortedPairedBAMImportsItsMatesAsPairs() async throws {
        let samtools = try await managedSamtools()
        let root = try TestTempDirectory.make(prefix: "bam-collate")
        defer { TestTempDirectory.cleanup(root) }
        let bam = root.appendingPathComponent("aligned.bam")
        try BamFixtureBuilder.makeBAM(
            at: bam, references: [.init(name: "chr1", length: 1_000)],
            reads: Self.coordinateSortedPairs, samtoolsPath: samtools
        )
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let result = try await ONTBAMImportMaterializer.materializeIfNeeded(
            pair: SamplePair(sampleName: "aligned", r1: bam, r2: nil),
            platform: LungfishIO.SequencingPlatform.illumina,
            workspace: workspace,
            threads: 2
        )

        let layout = FASTQReadLayoutClassifier.classify(inputURL: result.processingPair.r1)
        XCTAssertEqual(layout.matePairs, 5, layout.reason)
        XCTAssertEqual(layout.unpairedRecords, 0, layout.reason)
        XCTAssertEqual(
            FASTQBatchImporter.recordedPairing(pairing: .auto, r1: result.processingPair.r1, hasR2: false).mode,
            .interleaved
        )
        XCTAssertEqual(result.provenanceSteps.map(\.toolName), ["samtools", "samtools", "pigz"])
        XCTAssertTrue(result.provenanceSteps.first?.command.contains("collate") == true)
        XCTAssertEqual(result.provenanceSteps.first?.inputs.first?.path, bam.path)
        XCTAssertEqual(result.provenanceSteps[1].dependsOn, [result.provenanceSteps[0].id])
        // The collated BAM and the scratch files of samtools collate are gone.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: workspace.path).sorted(),
            ["aligned-from-bam.fastq", "aligned-from-bam.fastq.gz"]
        )
    }

    /// The nf-core SARS-CoV-2 BAM: 100 Illumina pairs aligned by minimap2 and
    /// sorted by coordinate. Converted as before, 60 pairs stayed adjacent
    /// and 80 mates became single reads. Collated, all 100 pairs import.
    func testTheSortedSARSCoV2BAMImportsAllItsPairs() async throws {
        _ = try await managedSamtools()
        let root = try TestTempDirectory.make(prefix: "bam-collate-sarscov2")
        defer { TestTempDirectory.cleanup(root) }
        let bam = PlatformHeaderFixtures.directory.deletingLastPathComponent()
            .appendingPathComponent("sarscov2/test.paired_end.sorted.bam")
        XCTAssertTrue(ONTBAMImportMaterializer.needsCollation(bamURL: bam))

        let result = try await ONTBAMImportMaterializer.materializeIfNeeded(
            pair: SamplePair(sampleName: "sarscov2", r1: bam, r2: nil),
            platform: LungfishIO.SequencingPlatform.illumina,
            workspace: root
        )

        let layout = FASTQReadLayoutClassifier.classify(inputURL: result.processingPair.r1)
        XCTAssertEqual(layout.scannedRecords, 200)
        XCTAssertEqual(layout.matePairs, 100, layout.reason)
        XCTAssertEqual(layout.layout, .strictlyInterleaved)
    }

    /// Only a header that groups records by read name skips collation. A
    /// missing `SO` is unsorted, as the SAM specification says.
    func testOnlyAHeaderGroupedByReadNameSkipsCollation() {
        let grouped = ONTBAMImportMaterializer.isGroupedByReadName
        XCTAssertTrue(grouped("@HD\tVN:1.6\tSO:queryname\n@SQ\tSN:chr1\tLN:10\n"))
        XCTAssertTrue(grouped("@HD\tVN:1.6\tSO:unsorted\tGO:query\n"))
        XCTAssertTrue(grouped("@HD\tVN:1.6\tSO:queryname\r\n"))
        XCTAssertFalse(grouped("@HD\tVN:1.6\tSO:coordinate\n"))
        XCTAssertFalse(grouped("@HD\tVN:1.6\tSO:unsorted\n"))
        XCTAssertFalse(grouped("@HD\tVN:1.6\tSO:unknown\n"))
        XCTAssertFalse(grouped("@HD\tVN:1.6\n"))
        XCTAssertFalse(grouped("@SQ\tSN:chr1\tLN:10\n@CO\tSO:queryname\n"))

        // Paired fixtures of no recorded order are collated. Unpaired ones,
        // and anything that is not a BAM, are not.
        XCTAssertTrue(ONTBAMImportMaterializer.needsCollation(bamURL: PlatformHeaderFixtures.url("illumina-paired.bam")))
        XCTAssertFalse(ONTBAMImportMaterializer.needsCollation(bamURL: PlatformHeaderFixtures.url("ont-dorado.bam")))
        XCTAssertFalse(ONTBAMImportMaterializer.needsCollation(bamURL: PlatformHeaderFixtures.url("unlabelled.bam")))
        XCTAssertFalse(ONTBAMImportMaterializer.needsCollation(bamURL: PlatformHeaderFixtures.url("illumina-novaseq6000.fastq")))
        XCTAssertNil(ONTBAMImportMaterializer.needsCollation(decodedBAMPrefix: Data([0x42, 0x41, 0x4D, 0x01, 0x40, 0, 0, 0])))
    }

    /// A paired BAM grouped by read name already holds each pair together,
    /// so it converts as before, with no collate step.
    func testAPairedBAMGroupedByReadNameIsNotCollated() async throws {
        let samtools = try await managedSamtools()
        let root = try TestTempDirectory.make(prefix: "bam-queryname")
        defer { TestTempDirectory.cleanup(root) }
        let sam = root.appendingPathComponent("grouped.sam")
        let records = (1...3).flatMap { fragment in
            [77, 141].map { flag in "frag\(fragment)\t\(flag)\t*\t0\t0\t*\t*\t0\t0\tACGTTGCA\tIIIIIIII" }
        }
        try (["@HD\tVN:1.6\tSO:queryname"] + records).joined(separator: "\n").appending("\n")
            .write(to: sam, atomically: true, encoding: .utf8)
        let bam = root.appendingPathComponent("grouped.bam")
        let process = Process()
        process.executableURL = samtools
        process.arguments = ["view", "-b", "-o", bam.path, sam.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(ONTBAMImportMaterializer.needsCollation(bamURL: bam))

        let result = try await ONTBAMImportMaterializer.materializeIfNeeded(
            pair: SamplePair(sampleName: "grouped", r1: bam, r2: nil),
            platform: LungfishIO.SequencingPlatform.illumina,
            workspace: root
        )
        XCTAssertEqual(result.provenanceSteps.map(\.toolName), ["samtools", "pigz"])
        XCTAssertEqual(result.provenanceSteps.first?.command.last, bam.path)
        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: result.processingPair.r1).matePairs, 3)
    }

    /// A BAM with no paired record is never collated, so it converts byte for
    /// byte as before: dorado ONT reads with no sort order, unlabelled reads,
    /// and single-end reads sorted by coordinate.
    func testAnUnpairedBAMConvertsAsBeforeWithoutCollation() async throws {
        let samtools = try await managedSamtools()
        let root = try TestTempDirectory.make(prefix: "bam-unpaired")
        defer { TestTempDirectory.cleanup(root) }
        let singleEnd = root.appendingPathComponent("single-end.bam")
        try BamFixtureBuilder.makeBAM(
            at: singleEnd, references: [.init(name: "chr1", length: 1_000)],
            reads: [(900, 0), (100, 16), (500, 0), (300, 0)].enumerated().map { index, read in
                BamFixtureBuilder.Read(
                    qname: "read\(index)", flag: read.1, rname: "chr1", pos: read.0,
                    mapq: 60, cigar: "8M", seq: "ACGTTGCA", qual: "IIIIIIII"
                )
            },
            samtoolsPath: samtools
        )

        for bam in [PlatformHeaderFixtures.url("ont-dorado.bam"), PlatformHeaderFixtures.url("unlabelled.bam"), singleEnd] {
            let label = bam.lastPathComponent
            let workspace = root.appendingPathComponent("workspace-\(label)", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let result = try await ONTBAMImportMaterializer.materializeIfNeeded(
                pair: SamplePair(sampleName: "reads", r1: bam, r2: nil),
                platform: LungfishIO.SequencingPlatform.unknown,
                workspace: workspace
            )
            XCTAssertEqual(result.provenanceSteps.map(\.toolName), ["samtools", "pigz"], label)
            XCTAssertEqual(result.provenanceSteps.first?.command.last, bam.path, label)
            XCTAssertEqual(try gunzipped(result.processingPair.r1), try samtoolsFASTQ(samtools, bam: bam), label)
        }
    }

    private func installScript(at url: URL, body: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\nset -eu\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
