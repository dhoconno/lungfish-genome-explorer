import Foundation
import XCTest
@testable import LungfishIO

final class HaplotypeDefinitionLibraryProjectScopeTests: XCTestCase {
    func testRecordsReturnsOnlyProjectBundleRecords() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaploLib-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: projectRoot) }
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        let library = HaplotypeDefinitionLibrary(projectRoot: projectRoot)
        XCTAssertTrue(library.records().isEmpty)
        for record in library.records() {
            XCTAssertEqual(record.scope, .project)
            XCTAssertNotNil(record.referenceFASTAURL)
        }
    }

    func testHaplotypeDefinitionScopeHasOnlyProjectCase() {
        XCTAssertEqual(HaplotypeDefinitionScope.allCases, [.project])
    }
}
