import XCTest
@testable import LungfishApp
import LungfishWorkflow

@MainActor
final class AssemblyWizardSheetDefaultsTests: XCTestCase {
    func testShortReadAssemblersDefaultToUnfilteredMinContigLength() {
        XCTAssertEqual(AssemblyWizardSheet.defaultMinContigLength(for: .spades), 0)
        XCTAssertEqual(AssemblyWizardSheet.defaultMinContigLength(for: .megahit), 0)
        XCTAssertEqual(AssemblyWizardSheet.defaultMinContigLength(for: .skesa), 0)
    }
}
