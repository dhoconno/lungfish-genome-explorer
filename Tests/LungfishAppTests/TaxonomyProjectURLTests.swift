import XCTest
@testable import LungfishApp

/// The taxonomy view resolves sample names from bundles in the run's project.
/// It must find that project, never the folder above it.
final class TaxonomyProjectURLTests: XCTestCase {
    private let base = URL(fileURLWithPath: "/private/tmp/lge-taxonomy-project-url", isDirectory: true)

    func testAnalysesRunResolvesToItsProjectNotTheFolderAboveIt() {
        let project = base.appendingPathComponent("Documents/Study.lungfish", isDirectory: true)
        let output = project.appendingPathComponent("Analyses/kraken2-2026-10-08T22-25-44", isDirectory: true)
        XCTAssertEqual(TaxonomyViewController.projectURL(forClassificationOutput: output), project.standardizedFileURL)
    }

    func testLegacyDerivativesRunResolvesToItsProject() {
        let project = base.appendingPathComponent("Study.lungfish", isDirectory: true)
        let output = project.appendingPathComponent("Imports/sample.lungfishfastq/derivatives/kraken2-1", isDirectory: true)
        XCTAssertEqual(TaxonomyViewController.projectURL(forClassificationOutput: output), project.standardizedFileURL)
    }

    func testOutputOutsideAProjectHasNoProject() {
        let output = base.appendingPathComponent("loose/kraken2-1", isDirectory: true)
        XCTAssertNil(TaxonomyViewController.projectURL(forClassificationOutput: output))
    }
}
