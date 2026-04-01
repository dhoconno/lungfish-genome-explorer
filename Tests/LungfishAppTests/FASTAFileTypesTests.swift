import XCTest
@testable import LungfishApp

final class FASTAFileTypesTests: XCTestCase {
    func testReadableExtensionsIncludeCommonFASTAAliases() {
        XCTAssertEqual(
            FASTAFileTypes.readableExtensions,
            ["fa", "fasta", "fna", "fsa", "fas", "faa", "ffn", "frn", "gb", "gbk", "gbff", "genbank", "embl"]
        )
    }

    func testReadableContentTypesMatchExtensions() {
        // Content types include readable extensions + .gzip + compression wrapper types
        XCTAssertGreaterThan(
            FASTAFileTypes.readableContentTypes.count,
            FASTAFileTypes.readableExtensions.count
        )
    }
}
