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
            ["Extract Sequence…", "Verify with BLAST…", "Copy FASTA", "Export FASTA…", "Extract to New Bundle…", "Run Operation…"]
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
            ["Extract Sequence…", "BLAST Contig…", "Copy FASTA", "Export FASTA…", "Extract to New Bundle…", "Run Operation…"]
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

    func testActionEligibilityDependsOnSelectionCount() {
        let handlers = FASTASequenceActionHandlers(
            onExtractSequence: {},
            onBlast: {},
            onCopy: {},
            onExport: {},
            onCreateBundle: {},
            onAlignWithMAFFT: {},
            onRunOperation: {}
        )

        let expectations: [(count: Int, enabled: [String: Bool])] = [
            (0, [
                "Extract Sequence…": false, "Verify with BLAST…": false,
                "Copy FASTA": false, "Export FASTA…": false, "Extract to New Bundle…": false,
                "Align with MAFFT…": false, "Run Operation…": false,
            ]),
            (1, [
                "Extract Sequence…": true, "Verify with BLAST…": true,
                "Copy FASTA": true, "Export FASTA…": true, "Extract to New Bundle…": true,
                "Align with MAFFT…": false, "Run Operation…": true,
            ]),
            (2, [
                "Extract Sequence…": true, "Verify with BLAST…": true,
                "Copy FASTA": true, "Export FASTA…": true, "Extract to New Bundle…": true,
                "Align with MAFFT…": true, "Run Operation…": true,
            ]),
            (51, [
                "Extract Sequence…": true, "Verify with BLAST…": false,
                "Copy FASTA": true, "Export FASTA…": true, "Extract to New Bundle…": true,
                "Align with MAFFT…": true, "Run Operation…": true,
            ]),
        ]

        for expectation in expectations {
            let menu = FASTASequenceActionMenuBuilder.buildMenu(
                selectionCount: expectation.count,
                handlers: handlers
            )
            for (title, isEnabled) in expectation.enabled {
                XCTAssertEqual(menu.items.first { $0.title == title }?.isEnabled, isEnabled, "count: \(expectation.count), action: \(title)")
            }
        }

        let blastItem = FASTASequenceActionMenuBuilder.buildMenu(
            selectionCount: 51,
            handlers: handlers
        ).items.first { $0.title == "Verify with BLAST…" }
        XCTAssertTrue(blastItem?.toolTip?.contains("50") == true)
    }
}
