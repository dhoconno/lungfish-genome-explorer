import XCTest
@testable import LungfishWorkflow
@testable import LungfishCore
@testable import LungfishIO

final class BundleVariantTrackAttachmentServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleVariantTrackAttachmentServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAttachPromotesArtifactsWritesProvenanceAndRenamesChromosomesToBundleNames() async throws {
        let bundleURL = try createBundle()
        let staging = try createStagedArtifacts(vcfChromosome: "1")
        let service = BundleVariantTrackAttachmentService(
            dateProvider: { Date(timeIntervalSince1970: 1_713_549_600) }
        )

        let result = try await service.attach(
            request: BundleVariantTrackAttachmentRequest(
                bundleURL: bundleURL,
                alignmentTrackID: "aln-1",
                caller: .lofreq,
                outputTrackID: "variant-track-1",
                outputTrackName: "Sample BAM • LoFreq",
                stagedVCFGZURL: staging.vcfGZURL,
                stagedTabixURL: staging.tbiURL,
                stagedDatabaseURL: staging.dbURL,
                variantCount: 99,
                variantCallerVersion: "2.1.5",
                variantCallerParametersJSON: #"{"min_af":0.05}"#,
                referenceStagedFASTASHA256: "ref-sha-256"
            )
        )

        XCTAssertEqual(result.trackInfo.id, "variant-track-1")
        XCTAssertEqual(result.trackInfo.path, "variants/variant-track-1.vcf.gz")
        XCTAssertEqual(result.trackInfo.indexPath, "variants/variant-track-1.vcf.gz.tbi")
        XCTAssertEqual(result.trackInfo.databasePath, "variants/variant-track-1.db")
        XCTAssertEqual(result.trackInfo.variantCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(result.trackInfo.path).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(result.trackInfo.indexPath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(try XCTUnwrap(result.trackInfo.databasePath)).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.vcfGZURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.tbiURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.dbURL.path))

        let manifest = try BundleManifest.load(from: bundleURL)
        let track = try XCTUnwrap(manifest.variants.first(where: { $0.id == "variant-track-1" }))
        XCTAssertEqual(track.path, "variants/variant-track-1.vcf.gz")
        XCTAssertEqual(track.indexPath, "variants/variant-track-1.vcf.gz.tbi")
        XCTAssertEqual(track.databasePath, "variants/variant-track-1.db")
        XCTAssertEqual(track.variantCount, 2)

        let dbURL = bundleURL.appendingPathComponent("variants/variant-track-1.db")
        let db = try VariantDatabase(url: dbURL)
        XCTAssertEqual(db.query(chromosome: "chr1", start: 0, end: 1_000).count, 2)
        XCTAssertEqual(db.query(chromosome: "1", start: 0, end: 1_000).count, 0)
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "variant_caller"), "lofreq")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "variant_caller_version"), "2.1.5")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "variant_caller_parameters_json"), #"{"min_af":0.05}"#)
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "source_alignment_track_id"), "aln-1")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "source_alignment_track_name"), "Sample BAM")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "source_alignment_relative_path"), "alignments/sample.sorted.bam")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "source_alignment_checksum_sha256"), "bam-sha-256")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "reference_bundle_id"), "test.bundle")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "reference_bundle_name"), "Test Bundle")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "reference_staged_fasta_sha256"), "ref-sha-256")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "artifact_vcf_path"), "variants/variant-track-1.vcf.gz")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "artifact_tbi_path"), "variants/variant-track-1.vcf.gz.tbi")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "call_semantics"), "viral_frequency")
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "created_at"), "2024-04-19T18:00:00Z")
    }

    func testAttachRollsBackPromotedArtifactsWhenManifestSaveFails() async throws {
        let bundleURL = try createBundle()
        let staging = try createStagedArtifacts(vcfChromosome: "chr1")
        let service = BundleVariantTrackAttachmentService(
            manifestSaver: { _, bundleURL in
                try Data("not json".utf8).write(
                    to: bundleURL.appendingPathComponent(BundleManifest.filename),
                    options: .atomic
                )
                struct ExpectedFailure: Error {}
                throw ExpectedFailure()
            }
        )

        await XCTAssertThrowsErrorAsync(
            try await service.attach(
                request: BundleVariantTrackAttachmentRequest(
                    bundleURL: bundleURL,
                    alignmentTrackID: "aln-1",
                    caller: .ivar,
                    outputTrackID: "variant-track-rollback",
                    outputTrackName: "Sample BAM • iVar",
                    stagedVCFGZURL: staging.vcfGZURL,
                    stagedTabixURL: staging.tbiURL,
                    stagedDatabaseURL: staging.dbURL,
                    variantCount: 2,
                    variantCallerVersion: "1.4.4",
                    variantCallerParametersJSON: #"{"min_depth":10}"#,
                    referenceStagedFASTASHA256: "ref-sha-256"
                )
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("variants/variant-track-rollback.vcf.gz").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("variants/variant-track-rollback.vcf.gz.tbi").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("variants/variant-track-rollback.db").path))

        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertFalse(manifest.variants.contains(where: { $0.id == "variant-track-rollback" }))
    }

    func testAttachMergesAliasAndCanonicalContigLengthsWithoutTrapping() async throws {
        let bundleURL = try createBundle()
        let staging = try createMixedAliasStagedArtifacts()
        let service = BundleVariantTrackAttachmentService()

        let result = try await service.attach(
            request: BundleVariantTrackAttachmentRequest(
                bundleURL: bundleURL,
                alignmentTrackID: "aln-1",
                caller: .lofreq,
                outputTrackID: "variant-track-mixed",
                outputTrackName: "Sample BAM • LoFreq Mixed",
                stagedVCFGZURL: staging.vcfGZURL,
                stagedTabixURL: staging.tbiURL,
                stagedDatabaseURL: staging.dbURL,
                variantCount: nil,
                variantCallerVersion: "2.1.5",
                variantCallerParametersJSON: #"{"min_af":0.05}"#,
                referenceStagedFASTASHA256: "ref-sha-256"
            )
        )

        let dbURL = bundleURL.appendingPathComponent(result.trackInfo.databasePath!)
        let db = try VariantDatabase(url: dbURL)
        XCTAssertEqual(db.query(chromosome: "chr1", start: 0, end: 1_000).count, 2)
        XCTAssertEqual(db.query(chromosome: "1", start: 0, end: 1_000).count, 0)
        XCTAssertEqual(VariantDatabase.metadataValue(at: dbURL, key: "contig_lengths"), #"{"chr1":20}"#)
    }

    private func createBundle() throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("test.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let alignmentsDir = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        let variantsDir = bundleURL.appendingPathComponent("variants", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)

        try """
        >chr1
        ACGTACGTACGTACGTACGT
        """.write(to: genomeDir.appendingPathComponent("sequence.fa.gz"), atomically: true, encoding: .utf8)
        try "chr1\t20\t6\t20\t21\n".write(
            to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"),
            atomically: true,
            encoding: .utf8
        )

        try Data("bam".utf8).write(to: alignmentsDir.appendingPathComponent("sample.sorted.bam"))
        try Data("bai".utf8).write(to: alignmentsDir.appendingPathComponent("sample.sorted.bam.bai"))

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test Bundle",
            identifier: "test.bundle",
            source: SourceInfo(organism: "Test virus", assembly: "TestAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 20,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 20, offset: 6, lineBases: 20, lineWidth: 21, aliases: ["1"])
                ]
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Sample BAM",
                    format: .bam,
                    sourcePath: "alignments/sample.sorted.bam",
                    indexPath: "alignments/sample.sorted.bam.bai",
                    checksumSHA256: "bam-sha-256"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private func createStagedArtifacts(vcfChromosome: String) throws -> (vcfGZURL: URL, tbiURL: URL, dbURL: URL) {
        let stagingDir = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let vcfContent = """
        ##fileformat=VCFv4.3
        ##contig=<ID=\(vcfChromosome),length=20>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        \(vcfChromosome)\t2\tvar1\tA\tG\t50\tPASS\tAF=0.5
        \(vcfChromosome)\t5\tvar2\tC\tT\t45\tPASS\tAF=0.4
        """

        let vcfURL = stagingDir.appendingPathComponent("staged.vcf")
        let vcfGZURL = stagingDir.appendingPathComponent("staged.vcf.gz")
        let tbiURL = stagingDir.appendingPathComponent("staged.vcf.gz.tbi")
        let dbURL = stagingDir.appendingPathComponent("staged.db")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)
        try Data("fake-vcfgz".utf8).write(to: vcfGZURL)
        try Data("fake-tabix".utf8).write(to: tbiURL)
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: dbURL,
            importSemantics: .viralFrequency
        )
        return (vcfGZURL, tbiURL, dbURL)
    }

    private func createMixedAliasStagedArtifacts() throws -> (vcfGZURL: URL, tbiURL: URL, dbURL: URL) {
        let stagingDir = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let vcfContent = """
        ##fileformat=VCFv4.3
        ##contig=<ID=1,length=20>
        ##contig=<ID=chr1,length=20>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        1\t2\tvar1\tA\tG\t50\tPASS\tAF=0.5
        chr1\t5\tvar2\tC\tT\t45\tPASS\tAF=0.4
        """

        let vcfURL = stagingDir.appendingPathComponent("staged-mixed.vcf")
        let vcfGZURL = stagingDir.appendingPathComponent("staged-mixed.vcf.gz")
        let tbiURL = stagingDir.appendingPathComponent("staged-mixed.vcf.gz.tbi")
        let dbURL = stagingDir.appendingPathComponent("staged-mixed.db")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)
        try Data("fake-vcfgz".utf8).write(to: vcfGZURL)
        try Data("fake-tabix".utf8).write(to: tbiURL)
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: dbURL,
            importSemantics: .viralFrequency
        )
        return (vcfGZURL, tbiURL, dbURL)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
    }
}
