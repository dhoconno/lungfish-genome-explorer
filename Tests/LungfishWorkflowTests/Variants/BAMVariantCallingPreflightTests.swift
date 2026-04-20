import XCTest
@testable import LungfishWorkflow
@testable import LungfishCore
@testable import LungfishIO

final class BAMVariantCallingPreflightTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMVariantCallingPreflightTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPreflightRejectsBamReferenceLengthMismatch() async throws {
        let bundleURL = try createBundle(genomeMD5Checksum: nil)
        let preflight = BAMVariantCallingPreflight(
            bamReferenceReader: { _ in
                [SAMParser.ReferenceSequence(name: "chr1", length: 19, md5: nil, assembly: nil, uri: nil, species: nil)]
            }
        )

        do {
            _ = try await preflight.validate(
                BundleVariantCallingRequest(
                    bundleURL: bundleURL,
                    alignmentTrackID: "aln-1",
                    caller: .lofreq,
                    outputTrackName: "Sample BAM • LoFreq"
                )
            )
            XCTFail("Expected preflight to reject mismatched contig lengths")
        } catch let error as BAMVariantCallingPreflightError {
            guard case .referenceLengthMismatch(let bamName, let bundleName, let expectedLength, let observedLength) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(bamName, "chr1")
            XCTAssertEqual(bundleName, "chr1")
            XCTAssertEqual(expectedLength, 20)
            XCTAssertEqual(observedLength, 19)
        }
    }

    func testPreflightRejectsMissingAlignmentFile() async throws {
        let bundleURL = try createBundle(genomeMD5Checksum: nil, includeAlignmentFile: false)
        let preflight = BAMVariantCallingPreflight(
            bamReferenceReader: { _ in
                XCTFail("Preflight should fail before attempting to read the BAM header")
                return []
            }
        )

        do {
            _ = try await preflight.validate(
                BundleVariantCallingRequest(
                    bundleURL: bundleURL,
                    alignmentTrackID: "aln-1",
                    caller: .lofreq,
                    outputTrackName: "Sample BAM • LoFreq"
                )
            )
            XCTFail("Expected preflight to reject a missing BAM artifact")
        } catch let error as BAMVariantCallingPreflightError {
            guard case .missingAlignmentFile(let path) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(path.hasSuffix("alignments/sample.sorted.bam"))
        }
    }

    func testPreflightAcceptsAliasMatchedContigs() async throws {
        let bundleURL = try createBundle(genomeMD5Checksum: nil)
        let preflight = BAMVariantCallingPreflight(
            bamReferenceReader: { _ in
                [SAMParser.ReferenceSequence(name: "1", length: 20, md5: nil, assembly: nil, uri: nil, species: nil)]
            }
        )

        let result = try await preflight.validate(
            BundleVariantCallingRequest(
                bundleURL: bundleURL,
                alignmentTrackID: "aln-1",
                caller: .lofreq,
                outputTrackName: "Sample BAM • LoFreq"
            )
        )

        XCTAssertEqual(result.contigValidation, .matchedByAlias)
        XCTAssertEqual(result.referenceNameMap["1"], "chr1")
        XCTAssertEqual(result.alignmentTrack.id, "aln-1")
    }

    func testPreflightRejectsM5ChecksumMismatchWhenPresent() async throws {
        let bundleURL = try createBundle(genomeMD5Checksum: "bundle-md5")
        let preflight = BAMVariantCallingPreflight(
            bamReferenceReader: { _ in
                [SAMParser.ReferenceSequence(name: "chr1", length: 20, md5: "bam-md5", assembly: nil, uri: nil, species: nil)]
            }
        )

        do {
            _ = try await preflight.validate(
                BundleVariantCallingRequest(
                    bundleURL: bundleURL,
                    alignmentTrackID: "aln-1",
                    caller: .lofreq,
                    outputTrackName: "Sample BAM • LoFreq"
                )
            )
            XCTFail("Expected preflight to reject mismatched M5 checksum")
        } catch let error as BAMVariantCallingPreflightError {
            guard case .referenceMD5Mismatch(let expected, let observed) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, "bundle-md5")
            XCTAssertEqual(observed, "bam-md5")
        }
    }

    func testPreflightBlocksIVarWithoutPrimerTrimConfirmation() async throws {
        let bundleURL = try createBundle(genomeMD5Checksum: nil)
        let preflight = BAMVariantCallingPreflight(
            bamReferenceReader: { _ in
                [SAMParser.ReferenceSequence(name: "chr1", length: 20, md5: nil, assembly: nil, uri: nil, species: nil)]
            }
        )

        do {
            _ = try await preflight.validate(
                BundleVariantCallingRequest(
                    bundleURL: bundleURL,
                    alignmentTrackID: "aln-1",
                    caller: .ivar,
                    outputTrackName: "Sample BAM • iVar"
                )
            )
            XCTFail("Expected iVar preflight to require primer-trim confirmation")
        } catch let error as BAMVariantCallingPreflightError {
            XCTAssertEqual(error, .ivarRequiresPrimerTrimConfirmation)
        }
    }

    func testPreflightBlocksMedakaWithoutOntModelMetadata() async throws {
        let bundleURL = try createBundle(genomeMD5Checksum: nil)
        let preflight = BAMVariantCallingPreflight(
            bamReferenceReader: { _ in
                [SAMParser.ReferenceSequence(name: "chr1", length: 20, md5: nil, assembly: nil, uri: nil, species: nil)]
            }
        )

        do {
            _ = try await preflight.validate(
                BundleVariantCallingRequest(
                    bundleURL: bundleURL,
                    alignmentTrackID: "aln-1",
                    caller: .medaka,
                    outputTrackName: "Sample BAM • Medaka"
                )
            )
            XCTFail("Expected Medaka preflight to require model metadata")
        } catch let error as BAMVariantCallingPreflightError {
            XCTAssertEqual(error, .medakaRequiresModelMetadata)
        }
    }

    func testPreflightRejectsMedakaWhenBamHeaderDoesNotProveOntPlatformOrModel() async throws {
        let bundleURL = try createBundle(genomeMD5Checksum: nil)
        let preflight = BAMVariantCallingPreflight(
            bamReferenceReader: { _ in
                [SAMParser.ReferenceSequence(name: "chr1", length: 20, md5: nil, assembly: nil, uri: nil, species: nil)]
            },
            bamHeaderReader: { _ in
                """
                @HD\tVN:1.6\tSO:coordinate
                @SQ\tSN:chr1\tLN:20
                @RG\tID:rg1\tPL:ILLUMINA
                """
            }
        )

        do {
            _ = try await preflight.validate(
                BundleVariantCallingRequest(
                    bundleURL: bundleURL,
                    alignmentTrackID: "aln-1",
                    caller: .medaka,
                    outputTrackName: "Sample BAM • Medaka",
                    medakaModel: "r1041_e82_400bps_sup_v5.0.0"
                )
            )
            XCTFail("Expected Medaka preflight to reject BAMs without verifiable ONT metadata")
        } catch let error as BAMVariantCallingPreflightError {
            XCTAssertEqual(error, .medakaCouldNotVerifyONTMetadata)
        }
    }

    func testPreflightAcceptsMedakaWhenBamHeaderProvesOntPlatformAndModel() async throws {
        let bundleURL = try createBundle(genomeMD5Checksum: nil)
        let model = "r1041_e82_400bps_sup_v5.0.0"
        let preflight = BAMVariantCallingPreflight(
            bamReferenceReader: { _ in
                [SAMParser.ReferenceSequence(name: "chr1", length: 20, md5: nil, assembly: nil, uri: nil, species: nil)]
            },
            bamHeaderReader: { _ in
                """
                @HD\tVN:1.6\tSO:coordinate
                @SQ\tSN:chr1\tLN:20
                @RG\tID:rg1\tPL:ONT\tDS:basecall_model=\(model)
                """
            }
        )

        let result = try await preflight.validate(
            BundleVariantCallingRequest(
                bundleURL: bundleURL,
                alignmentTrackID: "aln-1",
                caller: .medaka,
                outputTrackName: "Sample BAM • Medaka",
                medakaModel: model
            )
        )

        XCTAssertEqual(result.contigValidation, .exactMatch)
        XCTAssertEqual(result.referenceNameMap["chr1"], "chr1")
    }

    private func createBundle(
        genomeMD5Checksum: String?,
        includeAlignmentFile: Bool = true
    ) throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("test.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let alignmentsDir = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)

        try """
        >chr1
        ACGTACGTACGTACGTACGT
        """.write(to: genomeDir.appendingPathComponent("sequence.fa.gz"), atomically: true, encoding: .utf8)
        try "chr1\t20\t6\t20\t21\n".write(
            to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"),
            atomically: true,
            encoding: .utf8
        )

        if includeAlignmentFile {
            try Data("bam".utf8).write(to: alignmentsDir.appendingPathComponent("sample.sorted.bam"))
        }
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
                ],
                md5Checksum: genomeMD5Checksum
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
}
