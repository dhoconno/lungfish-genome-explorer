import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class ScientificFASTQProvenancePolicyTests: XCTestCase {
    func testFASTQOperationToolsThatChangeDataRequireProvenance() {
        let missing = FASTQOperationToolID.allCases.filter { tool in
            tool.createsOrModifiesScientificData && !tool.requiresProvenance
        }

        XCTAssertTrue(
            missing.isEmpty,
            "FASTQ tools missing provenance: \(missing.map(\.rawValue).joined(separator: ", "))"
        )
    }

    func testRefreshQCSummaryRequiresProvenanceBecauseItMutatesBundleQCState() {
        XCTAssertTrue(FASTQOperationToolID.refreshQCSummary.createsOrModifiesScientificData)
        XCTAssertTrue(FASTQOperationToolID.refreshQCSummary.requiresProvenance)
    }
}
