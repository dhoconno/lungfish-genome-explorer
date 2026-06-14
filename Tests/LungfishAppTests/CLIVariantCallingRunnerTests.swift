import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class CLIVariantCallingRunnerTests: XCTestCase {
    func testRunnerParsesRunCompleteEvent() throws {
        let json = """
        {"event":"runComplete","message":"done","variantTrackID":"vc-1","variantTrackName":"Sample 1 • LoFreq","databasePath":"/tmp/variants.db","vcfPath":"/tmp/variants.vcf.gz","tbiPath":"/tmp/variants.vcf.gz.tbi"}
        """

        let event = try XCTUnwrap(CLIVariantCallingRunner.parseEvent(from: json))
        guard case let .runComplete(trackID, trackName, databasePath, vcfPath, tbiPath) = event else {
            return XCTFail("Expected runComplete, got \(event)")
        }

        XCTAssertEqual(trackID, "vc-1")
        XCTAssertEqual(trackName, "Sample 1 • LoFreq")
        XCTAssertEqual(databasePath, "/tmp/variants.db")
        XCTAssertEqual(vcfPath, "/tmp/variants.vcf.gz")
        XCTAssertEqual(tbiPath, "/tmp/variants.vcf.gz.tbi")
    }

    func testRunnerParsesRunFailedEvent() throws {
        let json = """
        {"event":"runFailed","message":"Medaka requires ONT model metadata"}
        """

        let event = try XCTUnwrap(CLIVariantCallingRunner.parseEvent(from: json))
        guard case let .runFailed(message) = event else {
            return XCTFail("Expected runFailed, got \(event)")
        }

        XCTAssertEqual(message, "Medaka requires ONT model metadata")
    }

    func testBuildCLIArgumentsIncludesExtraArgsAsSingleValue() {
        let request = BundleVariantCallingRequest(
            bundleURL: URL(fileURLWithPath: "/tmp/Test Bundle.lungfishref"),
            alignmentTrackID: "aln-1",
            caller: .lofreq,
            outputTrackName: "Sample 1 • LoFreq",
            threads: 4,
            advancedArguments: ["--call-indels", "--tag", "sample 1"]
        )

        let arguments = CLIVariantCallingRunner.buildCLIArguments(request: request)
        let index = arguments.firstIndex(of: "--extra-args")

        XCTAssertNotNil(index)
        XCTAssertEqual(arguments[index! + 1], "--call-indels --tag 'sample 1'")
        XCTAssertFalse(arguments.contains("--advanced-options"))
    }

    func testBuildCLIArgumentsIncludesIvarSpecificOptions() {
        let request = BundleVariantCallingRequest(
            bundleURL: URL(fileURLWithPath: "/tmp/Test Bundle.lungfishref"),
            alignmentTrackID: "aln-1",
            caller: .ivar,
            outputTrackName: "Sample 1 • iVar",
            minimumAlleleFrequency: 0.07,
            minimumDepth: 12,
            ivarPrimerTrimConfirmed: true,
            ivarConsensusAF: 0.8,
            ivarMergeAFThreshold: 0.2,
            ivarBadQualityThreshold: 25,
            ivarIgnoreStrandBias: false
        )

        let arguments = CLIVariantCallingRunner.buildCLIArguments(request: request)

        XCTAssertTrue(arguments.containsSequence(["--ivar-consensus-af", "0.8"]))
        XCTAssertTrue(arguments.containsSequence(["--ivar-merge-af-threshold", "0.2"]))
        XCTAssertTrue(arguments.containsSequence(["--ivar-bad-quality-threshold", "25"]))
        XCTAssertTrue(arguments.contains("--ivar-no-ignore-strand-bias"))
    }
}

private extension Array where Element == String {
    func containsSequence(_ sequence: [String]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= count else { return false }
        return indices.contains { index in
            let end = self.index(index, offsetBy: sequence.count, limitedBy: endIndex)
            guard let end else { return false }
            return Array(self[index..<end]) == sequence
        }
    }
}
