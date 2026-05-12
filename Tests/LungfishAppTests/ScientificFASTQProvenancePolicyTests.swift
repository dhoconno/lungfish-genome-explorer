import XCTest
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

    func testRefreshQCSummaryIsReadOnlyForProvenancePolicy() {
        XCTAssertFalse(FASTQOperationToolID.refreshQCSummary.createsOrModifiesScientificData)
        XCTAssertFalse(FASTQOperationToolID.refreshQCSummary.requiresProvenance)
    }
}
