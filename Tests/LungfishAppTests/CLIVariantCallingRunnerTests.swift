import XCTest
@testable import LungfishApp

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
}
