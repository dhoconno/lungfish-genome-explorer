import Foundation
import XCTest
@testable import LungfishIO

final class IQTreeReportParserTests: XCTestCase {
    private func fixtureReport() throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/Fixtures/phylogenetics/known-sarcopterygian/run.iqtree")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesModelFinderReportFromFixture() throws {
        let fields = IQTreeReportParser.parse(try fixtureReport())

        XCTAssertEqual(fields.bestFitModel, "TIM2+ASC")
        XCTAssertEqual(fields.modelSelectionCriterion, "BIC")
        XCTAssertEqual(fields.substitutionModel, "TIM2+F+ASC")
        XCTAssertEqual(try XCTUnwrap(fields.logLikelihood), -173.4941, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fields.logLikelihoodStandardError), 7.9018, accuracy: 1e-9)
        XCTAssertEqual(fields.freeParameters, 15)
    }

    func testFixedModelReportHasNoBestFitModel() {
        let report = """
        IQ-TREE 3.1.3 built Jul 26 2026

        SUBSTITUTION PROCESS
        --------------------

        Model of substitution: JC

        MAXIMUM LIKELIHOOD TREE
        -----------------------

        Log-likelihood of the tree: -245.3775 (s.e. 5.4734)
        Number of free parameters (#branches + #model parameters): 9
        """
        let fields = IQTreeReportParser.parse(report)

        XCTAssertNil(fields.bestFitModel)
        XCTAssertNil(fields.modelSelectionCriterion)
        XCTAssertEqual(fields.substitutionModel, "JC")
        XCTAssertEqual(try XCTUnwrap(fields.logLikelihood), -245.3775, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fields.logLikelihoodStandardError), 5.4734, accuracy: 1e-9)
        XCTAssertEqual(fields.freeParameters, 9)
    }

    func testEmptyTextGivesEmptyFields() {
        XCTAssertEqual(IQTreeReportParser.parse(""), IQTreeReportFields())
    }
}
