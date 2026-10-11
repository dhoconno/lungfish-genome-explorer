// ClassifyOutputStemAgreementTests.swift - Every classifier tool maps to a descriptor that holds its stem
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// FASTQOperationToolID.classifyOutputStem reads the output stem from the descriptor of the classifier
// that classifierAnalysisToolID names (S14). A classifier left out of that mapping still compiles and
// quietly takes its lowercased title as the stem, which is the name S14 retires. The planner then
// returns the same three strings, so BuildDatabaseTokenPinTests cannot see the gap. This suite ties
// the mapping to the classification category and to the descriptors that carry a stem.

import LungfishIO
import XCTest
@testable import LungfishApp

final class ClassifyOutputStemAgreementTests: XCTestCase {
    private var classificationTools: [FASTQOperationToolID] {
        FASTQOperationToolID.allCases.filter { $0.categoryID == .classification }
    }

    /// Each classifier maps to a descriptor, and the stem that descriptor holds is the stem the
    /// planner uses and the analysis id that names the classifier's folders.
    func testEveryClassificationToolMapsToADescriptorStemThatIsItsAnalysisID() {
        XCTAssertFalse(classificationTools.isEmpty, "no tool is in the classification category")
        for tool in classificationTools {
            let id = tool.classifierAnalysisToolID
            XCTAssertNotNil(id, "\(tool.title) is a classifier with no analysis id")
            guard let id else { continue }
            let stem = AnalysisToolRegistry.descriptor(for: id)?.outputStem
            XCTAssertNotNil(stem, "\(id.rawValue) has no output stem on its descriptor")
            XCTAssertEqual(tool.classifyOutputStem, stem, "planner stem of \(tool.title)")
            XCTAssertEqual(stem, id.rawValue, "descriptor stem and analysis id of \(tool.title)")
        }
    }

    /// The ids the mapping yields are the registry kinds that hold a stem, no more and no fewer.
    func testMappedIDsAreTheRegistryKindsThatHoldAStem() {
        let mapped = Set(FASTQOperationToolID.allCases.compactMap(\.classifierAnalysisToolID))
        let withStem = Set(AnalysisToolRegistry.all.filter { $0.outputStem != nil }.map(\.id))
        XCTAssertEqual(mapped, withStem)
    }
}
