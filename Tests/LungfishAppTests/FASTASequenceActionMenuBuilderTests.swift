import XCTest
@testable import LungfishApp

@MainActor
final class FASTASequenceActionMenuBuilderTests: XCTestCase {
    func testBuilderCreatesCommonAssemblyAndFastaActions() {
        let menu = FASTASequenceActionMenuBuilder.buildMenu(
            selectionCount: 1,
            handlers: .noop
        )

        XCTAssertEqual(
            menu.items.map(\.title).filter { !$0.isEmpty },
            ["Verify with BLAST…", "Copy FASTA", "Export FASTA…", "Create Bundle…", "Run Operation…"]
        )
    }

    func testBuilderOmitsUnavailableActions() {
        let menu = FASTASequenceActionMenuBuilder.buildMenu(
            selectionCount: 1,
            handlers: FASTASequenceActionHandlers(
                onBlast: nil,
                onCopy: {},
                onExport: nil,
                onCreateBundle: nil,
                onRunOperation: {}
            )
        )

        XCTAssertEqual(
            menu.items.map(\.title).filter { !$0.isEmpty },
            ["Copy FASTA", "Run Operation…"]
        )
    }
}
