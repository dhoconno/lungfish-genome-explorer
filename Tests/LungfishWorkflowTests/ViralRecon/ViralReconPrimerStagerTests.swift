import XCTest
@testable import LungfishWorkflow

final class ViralReconPrimerStagerTests: XCTestCase {
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.fastaURL.path))
        XCTAssertTrue(try String(contentsOf: staged.fastaURL, encoding: .utf8).contains(">"))
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

        let fasta = try String(contentsOf: staged.fastaURL, encoding: .utf8)
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
