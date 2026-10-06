import Foundation
import LungfishIO
@testable import LungfishWorkflow
import XCTest

/// The ambiguity-resolution policy is a choice that changes 12S counts, so
/// the replay command and the recorded options must name it, with the CLI's
/// own spelling (`strict`, `conservative`), whichever path built the
/// configuration (Phase 2.1 lane L4, GUI and CLI parity).
final class TwelveSAmbiguityResolutionProvenanceTests: XCTestCase {

    private var root: URL!
    private var referenceURL: URL!
    private var fastqURL: URL!
    private var outputDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSResolutionProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        referenceURL = root.appendingPathComponent("reference.fa")
        fastqURL = root.appendingPathComponent("sampleA.fastq")
        outputDirectory = root.appendingPathComponent("outputs", isDirectory: true)
        try """
        >human (Homo sapiens)|locus=12S|len=8
        ACGTACGT

        """.write(to: referenceURL, atomically: true, encoding: .utf8)
        try """
        @read1
        TTACGTACGTGG
        +
        IIIIIIIIIIII

        """.write(to: fastqURL, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func provenance(
        policy: TwelveSAbundanceReassigner.ResolutionPolicy,
        outputName: String
    ) async throws -> ProvenanceEnvelope {
        let result = try await TwelveSAmpliconMatchingWorkflow(chimeraReviewer: TwelveSNoOpChimeraReviewer()).run(
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: [fastqURL],
                referenceFASTA: referenceURL,
                outputDirectory: outputDirectory,
                outputName: outputName,
                minimumSoftClipBases: 2,
                maximumIndelBases: 2,
                runChimeraReview: false,
                ambiguityResolution: policy
            )
        )
        return try XCTUnwrap(ProvenanceEnvelopeReader.load(from: result.bundleURL))
    }

    /// The value that follows `option` in `argv`, or nil when it is absent.
    private func value(after option: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: option), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }

    func testConservativeResolutionIsNamedInTheReplayArgvAndTheOptions() async throws {
        let envelope = try await provenance(
            policy: .conservative(minFoldRatio: 2.0, absoluteFloor: 10),
            outputName: "conservative-12s"
        )

        XCTAssertEqual(value(after: "--ambiguity-resolution", in: envelope.argv), "conservative")
        XCTAssertEqual(envelope.argv.filter { $0 == "--ambiguity-resolution" }.count, 1)
        XCTAssertEqual(envelope.options.explicit["ambiguityResolution"], .string("conservative"))
        XCTAssertEqual(envelope.options.resolvedDefaults["ambiguityResolution"], .string("conservative"))
        XCTAssertEqual(envelope.options.defaults["ambiguityResolution"], .string("strict"))
        XCTAssertEqual(envelope.reproducibleCommand.contains("--ambiguity-resolution conservative"), true)
    }

    func testStrictResolutionIsTheDefaultAndStillRecorded() async throws {
        let envelope = try await provenance(policy: .anyNonzeroLead, outputName: "strict-12s")

        XCTAssertNil(value(after: "--ambiguity-resolution", in: envelope.argv), "the default is not spelled out")
        XCTAssertEqual(envelope.options.explicit["ambiguityResolution"], .string("strict"))
        XCTAssertEqual(envelope.options.resolvedDefaults["ambiguityResolution"], .string("strict"))
        XCTAssertEqual(envelope.options.defaults["ambiguityResolution"], .string("strict"))
    }
}
