import XCTest
@testable import LungfishApp
import LungfishKit

@MainActor
final class FASTASequenceActionMenuBuilderTests: XCTestCase {
    func testBuilderCreatesCommonAssemblyAndFastaActions() {
        let menu = FASTASequenceActionMenuBuilder.buildMenu(
            selectionCount: 1,
            handlers: FASTASequenceActionHandlers(
                onExtractSequence: {},
                onBlast: {},
                onCopy: {},
                onExport: {},
                onCreateBundle: {},
                onRunOperation: {}
            )
        )

        XCTAssertEqual(
            menu.items.map { $0.title }.filter { !$0.isEmpty },
            ["Extract Sequence…", "Verify with BLAST…", "Copy FASTA", "Export FASTA…", "Create Bundle…", "Run Operation…"]
        )
    }

    func testBuilderAllowsAssemblySpecificBlastLabelOverrides() {
        let menu = FASTASequenceActionMenuBuilder.buildMenu(
            selectionCount: 1,
            handlers: FASTASequenceActionHandlers(
                onExtractSequence: {},
                blastMenuTitle: "BLAST Contig…",
                onBlast: {},
                onCopy: {},
                onExport: {},
                onCreateBundle: {},
                onRunOperation: {}
            )
        )

        XCTAssertEqual(
            menu.items.map { $0.title }.filter { !$0.isEmpty },
            ["Extract Sequence…", "BLAST Contig…", "Copy FASTA", "Export FASTA…", "Create Bundle…", "Run Operation…"]
        )
    }

    func testBuilderOmitsUnavailableActions() {
        let menu = FASTASequenceActionMenuBuilder.buildMenu(
            selectionCount: 1,
            handlers: FASTASequenceActionHandlers(
                onExtractSequence: {},
                onBlast: nil,
                onCopy: {},
                onExport: nil,
                onCreateBundle: nil,
                onRunOperation: {}
            )
        )

        XCTAssertEqual(
            menu.items.map { $0.title }.filter { !$0.isEmpty },
            ["Extract Sequence…", "Copy FASTA", "Run Operation…"]
        )
    }
}
