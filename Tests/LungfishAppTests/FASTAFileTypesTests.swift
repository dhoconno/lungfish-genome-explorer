import XCTest
@testable import LungfishApp

final class FASTAFileTypesTests: XCTestCase {
    func testReadableExtensionsIncludeCommonFASTAAliases() {
        XCTAssertEqual(
            FASTAFileTypes.readableExtensions,
            ["fa", "fasta", "fna", "fsa"]
        )
    }

    func testReadableContentTypesMatchExtensions() {
        XCTAssertEqual(
            FASTAFileTypes.readableContentTypes.count,
            FASTAFileTypes.readableExtensions.count
        )
    }
}
