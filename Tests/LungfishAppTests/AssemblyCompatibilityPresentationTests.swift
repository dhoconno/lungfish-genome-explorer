import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class AssemblyCompatibilityPresentationTests: XCTestCase {
    /// A tool the read class does not suit used to be blocked. It is now a
    /// warning and the run uses the tool as chosen.
    func testMismatchedCombinationWarnsWithAttentionStyling() {
        let presentation = AssemblyCompatibilityPresentation(
            tool: .flye,
            readType: .illuminaShortReads,
            packReady: true,
            toolReady: true,
            blockingMessage: nil
        )

        XCTAssertEqual(presentation.state, .ready)
        XCTAssertEqual(presentation.fillStyle, .attention)
        XCTAssertEqual(
            presentation.message,
            "Flye is ready. Flye is designed for other reads than Illumina short reads. The run uses Flye as chosen."
        )
    }

    func testMixedReadBlockUsesAttentionStyling() {
        let presentation = AssemblyCompatibilityPresentation(
            tool: .spades,
            readType: .illuminaShortReads,
            packReady: true,
            toolReady: true,
            blockingMessage: AssemblyCompatibility.hybridAssemblyUnsupportedMessage
        )

        XCTAssertEqual(presentation.state, .blocked)
        XCTAssertEqual(presentation.fillStyle, .attention)
        XCTAssertEqual(
            presentation.message,
            "The inputs mix read classes. Hybrid assembly is not supported in v1, so choose the read class to assemble every input as."
        )
    }

    func testCompatibleReadyToolUsesSuccessStyling() {
        let presentation = AssemblyCompatibilityPresentation(
            tool: .megahit,
            readType: .illuminaShortReads,
            packReady: true,
            toolReady: true,
            blockingMessage: nil
        )

        XCTAssertEqual(presentation.state, .ready)
        XCTAssertEqual(presentation.fillStyle, .success)
        XCTAssertEqual(
            presentation.message,
            "MEGAHIT is ready for Illumina short reads."
        )
    }

    func testMissingManagedToolReportsInstallReadiness() {
        let presentation = AssemblyCompatibilityPresentation(
            tool: .hifiasm,
            readType: .pacBioHiFi,
            packReady: false,
            toolReady: false,
            blockingMessage: nil
        )

        XCTAssertEqual(presentation.state, .installationRequired)
        XCTAssertEqual(presentation.fillStyle, .attention)
        XCTAssertEqual(
            presentation.message,
            "Install the Genome Assembly pack to enable Hifiasm."
        )
    }
}
