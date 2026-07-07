import XCTest
import AppKit
@testable import LungfishAlignmentUI
@testable import LungfishWorkflow
import LungfishKit

final class AlignmentResultViewControllerTests: XCTestCase {
    @MainActor
    func testViewControllerInstantiates() {
        let vc = AlignmentResultViewController()
        XCTAssertNotNil(vc.view)  // forces viewDidLoad; proves the leaf links + lays out
    }

    @MainActor
    func testConfiguredViewDescribesSummarySurfaceWithoutComingSoonCopy() {
        let vc = AlignmentResultViewController()
        vc.loadViewIfNeeded()

        vc.configure(result: Minimap2Result(
            bamURL: URL(fileURLWithPath: "/tmp/Sample.bam"),
            baiURL: URL(fileURLWithPath: "/tmp/Sample.bam.bai"),
            totalReads: 100,
            mappedReads: 75,
            unmappedReads: 25,
            wallClockSeconds: 1.2
        ))

        let text = textFields(in: vc.view)
            .map(\.stringValue)
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("Alignment summary only"))
        XCTAssertTrue(text.contains("75 / 100 reads mapped"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("coming soon"))
    }

    @MainActor
    private func textFields(in view: NSView) -> [NSTextField] {
        var fields = view.subviews.compactMap { $0 as? NSTextField }
        for subview in view.subviews {
            fields.append(contentsOf: textFields(in: subview))
        }
        return fields
    }
}
