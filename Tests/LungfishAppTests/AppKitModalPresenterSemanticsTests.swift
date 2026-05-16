import AppKit
import XCTest
@testable import LungfishApp

@MainActor
final class AppKitModalPresenterSemanticsTests: XCTestCase {
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

    func testAssemblyRuntimePreflightClassifiesSheetAndLegacyFallbackPresentationModes() {
        XCTAssertEqual(
            AssemblyRuntimePreflight.presentationModeForTest(hasWindow: true),
            .sheet
        )
        XCTAssertEqual(
            AssemblyRuntimePreflight.presentationModeForTest(hasWindow: false),
            .legacySynchronousFallback
        )
    }

    func testWorkflowNamePromptAcceptsTrimmedNonEmptyFirstButtonOnly() {
        XCTAssertEqual(
            WorkflowBuilderViewController.workflowNamePromptResultForTest(
                response: .alertFirstButtonReturn,
                rawName: "  Assembly QC  "
            ),
            "Assembly QC"
        )
        XCTAssertNil(
            WorkflowBuilderViewController.workflowNamePromptResultForTest(
                response: .alertFirstButtonReturn,
                rawName: "   "
            )
        )
        XCTAssertNil(
            WorkflowBuilderViewController.workflowNamePromptResultForTest(
                response: .alertSecondButtonReturn,
                rawName: "Assembly QC"
            )
        )
    }
}
