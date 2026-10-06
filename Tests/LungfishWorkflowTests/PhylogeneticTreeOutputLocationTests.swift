import XCTest
@testable import LungfishWorkflow

final class PhylogeneticTreeOutputLocationTests: XCTestCase {
    func testDefaultDirectoryIsUnderAnalyses() {
        let project = URL(fileURLWithPath: "/tmp/P.lungfish", isDirectory: true)
        XCTAssertEqual(
            PhylogeneticTreeOutputLocation.defaultDirectory(projectURL: project).path,
            "/tmp/P.lungfish/Analyses/Phylogenetic Trees"
        )
    }
}
