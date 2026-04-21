import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class FASTACollectionViewControllerTests: XCTestCase {
    func testContextMenuUsesSharedFastaActionSetWhenCallbacksPresent() throws {
        let vc = FASTACollectionViewController()
        vc.onBlastRequested = { _ in }
        vc.onExportRequested = { _ in }
        vc.onCreateBundleRequested = { _ in }
        vc.onRunOperationRequested = { _ in }
        _ = vc.view

        vc.configure(
            sequences: [try makeSequence(name: "seq1", bases: "AACCGGTT")],
            annotations: [],
            sourceNames: [:]
        )
        vc.testSelectRows([0])

        XCTAssertEqual(
            vc.testContextMenuTitles.filter { !$0.isEmpty },
            ["Verify with BLAST…", "Copy FASTA", "Export FASTA…", "Create Bundle…", "Run Operation…"]
        )
    }

    func testRunOperationContextActionUsesSelectedSequences() throws {
        let vc = FASTACollectionViewController()
        var capturedNames: [String] = []
        vc.onRunOperationRequested = { sequences in
            capturedNames = sequences.map(\.name)
        }
        _ = vc.view

        vc.configure(
            sequences: [
                try makeSequence(name: "seq1", bases: "AACCGGTT"),
                try makeSequence(name: "seq2", bases: "ATATAT")
            ],
            annotations: [],
            sourceNames: [:]
        )
        vc.testSelectRows([1])
        vc.testInvokeContextMenuItem(titled: "Run Operation…")

        XCTAssertEqual(capturedNames, ["seq2"])
    }

    private func makeSequence(name: String, bases: String) throws -> Sequence {
        try Sequence(name: name, alphabet: .dna, bases: bases)
    }
}
