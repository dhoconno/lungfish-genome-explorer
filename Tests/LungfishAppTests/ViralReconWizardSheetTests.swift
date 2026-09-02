import XCTest
@testable import LungfishApp

final class ViralReconWizardSheetTests: XCTestCase {
    func testFourVisibleControlsWhenPlatformDetected() {
        let controls = ViralReconWizardSheet.visibleControls(platformDetected: true)
        XCTAssertEqual(controls, [.inputs, .primerScheme, .minimumMappedReads, .readiness])
    }

    func testPlatformControlAppearsOnlyWhenDetectionFails() {
        let controls = ViralReconWizardSheet.visibleControls(platformDetected: false)
        XCTAssertTrue(controls.contains(.platform))
        XCTAssertEqual(controls.first, .inputs)
    }

    func testNoReferenceOrExecutorControlIsOffered() {
        for detected in [true, false] {
            let controls = ViralReconWizardSheet.visibleControls(platformDetected: detected)
            XCTAssertFalse(controls.contains(.reference))
            XCTAssertFalse(controls.contains(.executor))
        }
    }
}
