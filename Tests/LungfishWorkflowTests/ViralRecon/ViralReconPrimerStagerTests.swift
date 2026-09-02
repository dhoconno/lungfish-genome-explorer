import Foundation
import XCTest
@testable import LungfishWorkflow

final class ViralReconPrimerStagerTests: XCTestCase {
    /// References arrive as `.bgz` and `.gzip` as well as `.gz`.
    func testPrimerStagerDerivesPrimerFastaFromAlternateGzipExtensions() throws {
        for ext in ["gz", "bgz", "gzip"] {
            let tempDirectory = try ViralReconWorkflowTestFixtures.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            let referenceFASTA = try ViralReconWorkflowTestFixtures.writeGzippedReferenceFASTA(
                in: tempDirectory,
                named: "sequence.fa.\(ext)",
                contents: """
                >MN908947.3
                AAAACCCCGGGGTTTT
                """
            )
            let primerBundle = try ViralReconWorkflowTestFixtures.writePrimerBundleWithoutFasta(
                in: tempDirectory,
                bed: """
                MN908947.3\t4\t8\tamplicon_1_LEFT\t1\t+
                MN908947.3\t8\t12\tamplicon_1_RIGHT\t1\t-
                """
            )

            let staged = try ViralReconPrimerStager.stage(
                primerBundleURL: primerBundle,
                referenceFASTAURL: referenceFASTA,
                referenceName: "MN908947.3",
                destinationDirectory: tempDirectory
            )

            let fasta = try String(contentsOf: XCTUnwrap(staged.fastaURL), encoding: .utf8)
            XCTAssertTrue(fasta.contains(">amplicon_1_LEFT\nCCCC"), "extension .\(ext): \(fasta)")
        }
    }

    /// The atoplex scheme names primers `200BP-nCoV000-F` / `-R`.
    func testPrimerStagerInfersDashForwardReverseSuffixes() throws {
        let tempDirectory = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let referenceFASTA = try ViralReconWorkflowTestFixtures.writeReferenceFASTA(in: tempDirectory)
        let primerBundle = try ViralReconWorkflowTestFixtures.writePrimerBundleWithoutFasta(
            in: tempDirectory,
            bed: """
            MN908947.3\t0\t8\t200BP-nCoV001-F\t1\t+
            MN908947.3\t12\t20\t200BP-nCoV001-R\t1\t-
            """
        )

        let staged = try ViralReconPrimerStager.stage(
            primerBundleURL: primerBundle,
            referenceFASTAURL: referenceFASTA,
            referenceName: "MN908947.3",
            destinationDirectory: tempDirectory
        )

        XCTAssertEqual(staged.leftSuffix, "-F")
        XCTAssertEqual(staged.rightSuffix, "-R")
    }

    /// ARTIC V5.3.2 names primers `SARS-CoV-2_400_1_LEFT_1`, with a trailing
    /// alt-primer index after the orientation token.
    func testPrimerStagerInfersSuffixesForArticV5NamesWithAltIndex() throws {
        let tempDirectory = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let referenceFASTA = try ViralReconWorkflowTestFixtures.writeReferenceFASTA(in: tempDirectory)
        let primerBundle = try ViralReconWorkflowTestFixtures.writePrimerBundleWithoutFasta(
            in: tempDirectory,
            bed: """
            MN908947.3\t0\t8\tSARS-CoV-2_400_1_LEFT_1\t1\t+
            MN908947.3\t12\t20\tSARS-CoV-2_400_1_RIGHT_0\t1\t-
            """
        )

        let staged = try ViralReconPrimerStager.stage(
            primerBundleURL: primerBundle,
            referenceFASTAURL: referenceFASTA,
            referenceName: "MN908947.3",
            destinationDirectory: tempDirectory
        )

        XCTAssertEqual(staged.leftSuffix, "_LEFT")
        XCTAssertEqual(staged.rightSuffix, "_RIGHT")
    }

    func testPrimerStagerDerivesPrimerFastaFromGzippedReference() throws {
        let tempDirectory = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let referenceFASTA = try ViralReconWorkflowTestFixtures.writeGzippedReferenceFASTA(
            in: tempDirectory,
            contents: """
            >MN908947.3
            AAAACCCCGGGGTTTT
            """
        )
        let primerBundle = try ViralReconWorkflowTestFixtures.writePrimerBundleWithoutFasta(
            in: tempDirectory,
            bed: """
            MN908947.3\t4\t8\tamplicon_1_LEFT\t1\t+
            MN908947.3\t8\t12\tamplicon_1_RIGHT\t1\t-
            """
        )

        let staged = try ViralReconPrimerStager.stage(
            primerBundleURL: primerBundle,
            referenceFASTAURL: referenceFASTA,
            referenceName: "MN908947.3",
            destinationDirectory: tempDirectory
        )

        XCTAssertTrue(staged.derivedFasta)
        let fasta = try String(contentsOf: XCTUnwrap(staged.fastaURL), encoding: .utf8)
        XCTAssertTrue(fasta.contains(">amplicon_1_LEFT\nCCCC"), fasta)
        XCTAssertTrue(fasta.contains(">amplicon_1_RIGHT\nCCCC"), fasta)
    }

    func testPrimerStagerDerivesPrimerFastaWhenBundleHasOnlyBed() throws {
        let tempDirectory = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        let fixtureReferenceFASTA = try ViralReconWorkflowTestFixtures.writeReferenceFASTA(in: tempDirectory)
        let fixturePrimerBundleWithoutFasta = try ViralReconWorkflowTestFixtures.writePrimerBundleWithoutFasta(in: tempDirectory)

        let staged = try ViralReconPrimerStager.stage(
            primerBundleURL: fixturePrimerBundleWithoutFasta,
            referenceFASTAURL: fixtureReferenceFASTA,
            referenceName: "MN908947.3",
            destinationDirectory: tempDirectory
        )

        XCTAssertTrue(staged.derivedFasta)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(staged.fastaURL).path))
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(staged.fastaURL), encoding: .utf8).contains(">"))
    }

    func testPrimerStagerReadsGzippedReference() throws {
        let tempDirectory = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let plainReference = try ViralReconWorkflowTestFixtures.writeReferenceFASTA(in: tempDirectory)
        let compressedReference = tempDirectory.appendingPathComponent("sequence.fa.gz")
        try ViralReconWorkflowTestFixtures.gzip(plainReference, to: compressedReference)
        let primerBundle = try ViralReconWorkflowTestFixtures.writePrimerBundleWithoutFasta(in: tempDirectory)

        let staged = try ViralReconPrimerStager.stage(
            primerBundleURL: primerBundle,
            referenceFASTAURL: compressedReference,
            referenceName: "MN908947.3",
            destinationDirectory: tempDirectory
        )

        XCTAssertTrue(staged.derivedFasta)
        let fasta = try String(contentsOf: XCTUnwrap(staged.fastaURL), encoding: .utf8)
        XCTAssertTrue(fasta.contains(">amplicon_1_LEFT\nACGTACGT"))
    }

    func testPrimerStagerDerivesPrimerFastaFromBedContigColumn() throws {
        let tempDirectory = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let referenceFASTA = try ViralReconWorkflowTestFixtures.writeReferenceFASTA(
            in: tempDirectory,
            contents: """
            >contigA
            AAAACCCCGGGGTTTT
            >contigB
            TTTTGGGGCCCCAAAA
            """
        )
        let primerBundle = try ViralReconWorkflowTestFixtures.writePrimerBundleWithoutFasta(
            in: tempDirectory,
            bed: """
            contigA\t4\t8\tamplicon_1_LEFT\t1\t+
            contigB\t4\t8\tamplicon_1_RIGHT\t1\t+
            """
        )

        let staged = try ViralReconPrimerStager.stage(
            primerBundleURL: primerBundle,
            referenceFASTAURL: referenceFASTA,
            referenceName: "MN908947.3",
            destinationDirectory: tempDirectory
        )

        let fasta = try String(contentsOf: XCTUnwrap(staged.fastaURL), encoding: .utf8)
        XCTAssertTrue(fasta.contains(">amplicon_1_LEFT\nCCCC"))
        XCTAssertTrue(fasta.contains(">amplicon_1_RIGHT\nGGGG"))
    }

    func testPrimerStagerInfersShortForwardReverseSuffixes() throws {
        let tempDirectory = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let referenceFASTA = try ViralReconWorkflowTestFixtures.writeReferenceFASTA(in: tempDirectory)
        let primerBundle = try ViralReconWorkflowTestFixtures.writePrimerBundleWithoutFasta(
            in: tempDirectory,
            bed: """
            MN908947.3\t0\t8\tamplicon_1_F\t1\t+
            MN908947.3\t12\t20\tamplicon_1_R\t1\t-
            """
        )

        let staged = try ViralReconPrimerStager.stage(
            primerBundleURL: primerBundle,
            referenceFASTAURL: referenceFASTA,
            referenceName: "MN908947.3",
            destinationDirectory: tempDirectory
        )

        XCTAssertEqual(staged.leftSuffix, "_F")
        XCTAssertEqual(staged.rightSuffix, "_R")
    }
}
