import CryptoKit
import Foundation
import XCTest
@testable import LungfishWorkflow

/// Phase 2.14 lane W1T, BIO's pin. Viral Recon's Run stages the primer BED and FASTA before the run starts, and the
/// lane moves that staging off the main actor. The staged bytes of a bundled scheme must stay what the base
/// (`3cee435e3`) writes, so this test holds the SHA-256 of each staged file as the base wrote it.
///
/// The scheme is the ARTIC SARS-CoV-2 V5.3.2 bundle the app ships. No bundled scheme carries `primers.fasta`, so the
/// FASTA is derived from a fixed 29,903 base reference built from a seeded generator.
final class ViralReconPrimerStagingPinTests: XCTestCase {
    private static let expectedBEDDigest = "0d9d041004bae338fc046cb9c56ad0eb1d25575b25a3a0f0a4e29913ca8a7190"
    private static let expectedFASTADigest = "c5f460de15efc381a4eeb4d2a5d57bb3784f1be95ca1251a401d9d75bf88a169"

    func testStagedPrimerFilesEqualBase() throws {
        // Tests/LungfishWorkflowTests/ViralRecon/<this file>, four levels below the checkout root.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scheme = repoRoot.appendingPathComponent(
            "Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-SARS-CoV-2-V5.3.2.lungfishprimers",
            isDirectory: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: scheme.path), "the bundled scheme is at \(scheme.path)")

        let work = try ViralReconWorkflowTestFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let reference = work.appendingPathComponent("MN908947.3.fasta")
        try Self.seededReference().write(to: reference, atomically: true, encoding: .utf8)

        let staged = try ViralReconPrimerStager.stage(
            primerBundleURL: scheme,
            referenceFASTAURL: reference,
            referenceName: "MN908947.3",
            destinationDirectory: work.appendingPathComponent("stage-full", isDirectory: true)
        )
        let bedOnly = try ViralReconPrimerStager.stageBEDOnly(
            primerBundleURL: scheme,
            referenceName: "MN908947.3",
            destinationDirectory: work.appendingPathComponent("stage-bed-only", isDirectory: true)
        )

        let bedDigest = try Self.sha256(of: staged.bedURL)
        let fastaDigest = try Self.sha256(of: try XCTUnwrap(staged.fastaURL))
        XCTAssertEqual(bedDigest, Self.expectedBEDDigest, "staged primers.bed")
        XCTAssertEqual(fastaDigest, Self.expectedFASTADigest, "staged primers.fasta")

        // The launch path completes a BED-only selection later, so both routes must write the same BED.
        XCTAssertEqual(try Self.sha256(of: bedOnly.bedURL), bedDigest, "BED-only staging writes the same BED")
        XCTAssertNil(bedOnly.fastaURL)
        XCTAssertTrue(staged.derivedFasta)
        XCTAssertTrue(bedOnly.derivedFasta)
        XCTAssertEqual(staged.leftSuffix, "_LEFT")
        XCTAssertEqual(staged.rightSuffix, "_RIGHT")
        XCTAssertEqual(bedOnly.leftSuffix, staged.leftSuffix)
        XCTAssertEqual(bedOnly.rightSuffix, staged.rightSuffix)
    }

    private static func seededReference() -> String {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        let alphabet = Array("ACGT")
        var sequence = ""
        sequence.reserveCapacity(29_903)
        for _ in 0..<29_903 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            sequence.append(alphabet[Int((state >> 33) & 3)])
        }
        return ">MN908947.3\n\(sequence)\n"
    }

    private static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
}
