import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

final class AssemblyCompatibilityPresentationTests: XCTestCase {
    func testBlockedCombinationUsesAttentionStyling() {
        let presentation = AssemblyCompatibilityPresentation(
            tool: .flye,
            readType: .illuminaShortReads,
            packReady: true,
            toolReady: true,
            blockingMessage: nil
        )

        XCTAssertEqual(presentation.state, .blocked)
        XCTAssertEqual(presentation.fillStyle, .attention)
        XCTAssertEqual(
            presentation.message,
            "Flye is not available for Illumina short reads in v1."
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
            "Hybrid assembly is not supported in v1. Select one read class per run."
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
