import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class AppKitModalPresenterSemanticsTests: XCTestCase {
    func testDetachedPersistenceInformationRetainsAlertAndOKDismissesWithoutModalSession() throws {
        _ = NSApplication.shared
        let appDelegate = AppDelegate()
        let alert = NSAlert()
        alert.addButton(withTitle: "OK")
        appDelegate.retainDetachedPersistenceInformationAlert(alert)
        XCTAssertTrue(appDelegate.persistenceInformationAlert === alert)
        XCTAssertTrue(alert.buttons.first?.target === appDelegate)
        XCTAssertFalse(alert.window.isVisible, "Preparing presentation must not launch GUI in this test")
        alert.buttons.first?.performClick(nil)
        XCTAssertNil(appDelegate.persistenceInformationAlert)
        XCTAssertFalse(alert.window.isVisible)
    }

    /// Capture on 9.64: the Import Annotation Track alert drew its Reference,
    /// Track Name, and Track ID rows over its message and past its right edge,
    /// because the accessory view had no frame for NSAlert to size around.
    func testAnnotationImportAccessoryHasAFrameThatHoldsItsRows() throws {
        let accessory = ReferenceBundleAnnotationImportConfigurationPresenter.makeAccessory(
            choices: [(title: "Reference Sequences/GRCh38.chr20.10.0-10.5Mb", url: URL(fileURLWithPath: "/tmp/p/ref.lungfishref"))],
            preferredBundleURL: nil,
            sourceURL: URL(fileURLWithPath: "/tmp/regions-of-interest.bed")
        )
        let view = accessory.view
        XCTAssertGreaterThanOrEqual(view.frame.width, 92 + 8 + 360, "the accessory must be as wide as a label plus its control")
        XCTAssertGreaterThanOrEqual(view.frame.height, 3 * 24, "the accessory must be tall enough for three rows")

        let alert = NSAlert()
        alert.messageText = "Import Annotation Track"
        alert.informativeText = "Choose the reference bundle and annotation track identity."
        alert.accessoryView = view
        alert.layout()
        for control in [accessory.popup, accessory.trackNameField, accessory.trackIDField] as [NSView] {
            let frame = control.convert(control.bounds, to: view)
            XCTAssertTrue(view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                "\(type(of: control)) at \(frame) lies outside the accessory \(view.bounds)")
        }
    }

    func testReferenceAnnotationPresenterBuildsConfigurationOnlyForImportResponse() {
        let bundleURL = URL(fileURLWithPath: "/tmp/project/ref.lungfishref")

        XCTAssertEqual(
            ReferenceBundleAnnotationImportConfigurationPresenter.configurationForTest(
                response: .alertFirstButtonReturn,
                selectedBundleURL: bundleURL,
                trackID: "  gene_track  ",
                trackName: "  Genes  "
            ),
            ReferenceBundleAnnotationImportConfiguration(
                bundleURL: bundleURL,
                trackID: "gene_track",
                trackName: "Genes"
            )
        )
        XCTAssertEqual(
            ReferenceBundleAnnotationImportConfigurationPresenter.configurationForTest(
                response: .alertFirstButtonReturn,
                selectedBundleURL: bundleURL,
                trackID: "   ",
                trackName: "   "
            ),
            ReferenceBundleAnnotationImportConfiguration(
                bundleURL: bundleURL,
                trackID: nil,
                trackName: nil
            )
        )
        XCTAssertNil(
            ReferenceBundleAnnotationImportConfigurationPresenter.configurationForTest(
                response: .alertSecondButtonReturn,
                selectedBundleURL: bundleURL,
                trackID: "ignored",
                trackName: "ignored"
            )
        )
        XCTAssertNil(
            ReferenceBundleAnnotationImportConfigurationPresenter.configurationForTest(
                response: .alertFirstButtonReturn,
                selectedBundleURL: nil,
                trackID: "gene_track",
                trackName: "Genes"
            )
        )
    }

    func testReferenceAnnotationPresenterCompletesNilOnceForMissingPresentationWindowResponse() {
        let bundleURL = URL(fileURLWithPath: "/tmp/project/ref.lungfishref")
        var observedConfigurations: [ReferenceBundleAnnotationImportConfiguration?] = []

        ReferenceBundleAnnotationImportConfigurationPresenter.completeForTest(
            response: ReferenceBundleAnnotationImportConfigurationPresenter.missingPresentationWindowResponseForTest(),
            selectedBundleURL: bundleURL,
            trackID: "gene_track",
            trackName: "Genes"
        ) { configuration in
            observedConfigurations.append(configuration)
        }

        XCTAssertEqual(observedConfigurations.count, 1)
        XCTAssertNil(observedConfigurations[0])
    }

    func testAssemblyRuntimePreflightClassifiesSheetAndApplicationErrorPresentationModes() {
        XCTAssertEqual(
            AssemblyRuntimePreflight.presentationModeForTest(hasWindow: true),
            .sheet
        )
        XCTAssertEqual(
            AssemblyRuntimePreflight.presentationModeForTest(hasWindow: false),
            .applicationErrorPresentation
        )
    }
}
