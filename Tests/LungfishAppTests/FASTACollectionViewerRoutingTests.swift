import XCTest
@testable import LungfishApp
@testable import LungfishCore

@MainActor
final class FASTACollectionViewerRoutingTests: XCTestCase {
    func testSuccessfulBlastIsPresentedInCollectionDrawer() async throws {
        let viewer = ViewerViewController()
        _ = viewer.view
        let result = makeBlastResult(label: "seq1", rid: "RID-RESULT")
        viewer.fastaBlastVerificationRunner = { _, progress in
            progress(0.5, "Waiting for BLAST results")
            return result
        }

        viewer.displayFASTACollection(
            sequences: [try Sequence(name: "seq1", alphabet: .dna, bases: "AACCGGTT")],
            annotations: [],
            sourceNames: [:]
        )
        let collection = try XCTUnwrap(viewer.children.compactMap { $0 as? FASTACollectionViewController }.first)

        collection.onBlastRequested?([try Sequence(name: "seq1", alphabet: .dna, bases: "AACCGGTT")])

        await waitUntil {
            guard case .results(let displayed)? = collection.testBlastDrawerTab?.displayState else { return false }
            return displayed.rid == "RID-RESULT"
        }
        XCTAssertTrue(collection.testBlastDrawerIsOpen)
    }

    func testOlderBlastCompletionCannotReplaceNewSelectionResults() async throws {
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.fastaBlastVerificationRunner = { request, _ in
            if request.taxonName == "seq1" {
                try? await Task.sleep(for: .milliseconds(120))
                return self.makeBlastResult(label: "seq1", rid: "RID-OLD")
            }
            return self.makeBlastResult(label: "seq2", rid: "RID-NEW")
        }
        let seq1 = try Sequence(name: "seq1", alphabet: .dna, bases: "AACCGGTT")
        let seq2 = try Sequence(name: "seq2", alphabet: .dna, bases: "ATATAT")
        viewer.displayFASTACollection(sequences: [seq1, seq2], annotations: [], sourceNames: [:])
        let collection = try XCTUnwrap(viewer.children.compactMap { $0 as? FASTACollectionViewController }.first)

        collection.onBlastRequested?([seq1])
        collection.onBlastRequested?([seq2])

        await waitUntil {
            guard case .results(let displayed)? = collection.testBlastDrawerTab?.displayState else { return false }
            return displayed.rid == "RID-NEW"
        }
        try? await Task.sleep(for: .milliseconds(180))
        guard case .results(let displayed)? = collection.testBlastDrawerTab?.displayState else {
            return XCTFail("Expected BLAST results")
        }
        XCTAssertEqual(displayed.rid, "RID-NEW")
    }

    func testMAFFTActionUsesAlignmentToolDirectly() throws {
        let viewer = ViewerViewController()
        _ = viewer.view
        var capturedCategory: FASTQOperationCategoryID?
        var capturedTool: FASTQOperationToolID?
        viewer.fastaOperationDialogPresenterForTesting = { _, _, category, tool in
            capturedCategory = category
            capturedTool = tool
        }
        let sequences = [
            try Sequence(name: "seq1", alphabet: .dna, bases: "AACCGGTT"),
            try Sequence(name: "seq2", alphabet: .dna, bases: "ATATAT")
        ]
        viewer.displayFASTACollection(sequences: sequences, annotations: [], sourceNames: [:])
        let collection = try XCTUnwrap(viewer.children.compactMap { $0 as? FASTACollectionViewController }.first)

        collection.onAlignWithMAFFTRequested?(sequences)

        XCTAssertEqual(capturedCategory, .alignment)
        XCTAssertEqual(capturedTool, .mafft)
    }

    func testGenericRunOperationKeepsDefaultRoute() throws {
        let viewer = ViewerViewController()
        _ = viewer.view
        var capturedCategory: FASTQOperationCategoryID?
        var capturedTool: FASTQOperationToolID?
        viewer.fastaOperationDialogPresenterForTesting = { _, _, category, tool in
            capturedCategory = category
            capturedTool = tool
        }
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "AACCGGTT")
        viewer.displayFASTACollection(sequences: [sequence], annotations: [], sourceNames: [:])
        let collection = try XCTUnwrap(viewer.children.compactMap { $0 as? FASTACollectionViewController }.first)

        collection.onRunOperationRequested?([sequence])

        XCTAssertEqual(capturedCategory, .searchSubsetting)
        XCTAssertNil(capturedTool)
    }

    func testBlastFailureIsPresentedInCollectionDrawer() async throws {
        struct ExpectedFailure: LocalizedError {
            var errorDescription: String? { "BLAST service unavailable" }
        }
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.fastaBlastVerificationRunner = { _, _ in throw ExpectedFailure() }
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "AACCGGTT")
        viewer.displayFASTACollection(sequences: [sequence], annotations: [], sourceNames: [:])
        let collection = try XCTUnwrap(viewer.children.compactMap { $0 as? FASTACollectionViewController }.first)
        collection.testSelectRows([0])

        collection.onBlastRequested?([sequence])

        await waitUntil {
            guard case .empty? = collection.testBlastDrawerTab?.displayState else { return false }
            return collection.testBlastDrawerIsOpen
        }
    }

    func testBlastCancelAndRerunUseTheCurrentAndLastRequests() async throws {
        let viewer = ViewerViewController()
        _ = viewer.view
        var starts = 0
        var cancellations = 0
        viewer.fastaBlastVerificationRunner = { _, _ in
            starts += 1
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                cancellations += 1
                throw error
            }
            return self.makeBlastResult(label: "seq1", rid: "unused")
        }
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "AACCGGTT")
        viewer.displayFASTACollection(sequences: [sequence], annotations: [], sourceNames: [:])
        let collection = try XCTUnwrap(viewer.children.compactMap { $0 as? FASTACollectionViewController }.first)
        collection.testSelectRows([0])

        collection.onBlastRequested?([sequence])
        await waitUntil { starts == 1 }
        collection.testBlastDrawerTab?.onCancelBlast?()
        await waitUntil { cancellations == 1 }
        XCTAssertFalse(collection.testBlastDrawerIsOpen)
        XCTAssertFalse(collection.testDetailIsCollapsed)
        XCTAssertEqual(collection.testDetailText, ">seq1\nAACCGGTT\n")

        collection.onBlastRerunRequested?()
        await waitUntil { starts == 2 }
        collection.testBlastDrawerTab?.onCancelBlast?()
        await waitUntil { cancellations == 2 }
    }

    func testMultiSequenceDocumentCapturesItsOwnDurableSourceInsteadOfPriorViewerState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fasta-collection-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let priorURL = root.appendingPathComponent("prior.fasta")
        let collectionURL = root.appendingPathComponent("savont-clusters.fasta")
        try ">prior\nAAAA\n".write(to: priorURL, atomically: true, encoding: .utf8)
        try ">cluster1\nAACCGGTT\n>cluster2\nATATAT\n".write(
            to: collectionURL,
            atomically: true,
            encoding: .utf8
        )

        let prior = LoadedDocument(url: priorURL, type: .fasta)
        prior.sequences = [try Sequence(name: "prior", alphabet: .dna, bases: "AAAA")]
        let collectionDocument = LoadedDocument(url: collectionURL, type: .fasta)
        collectionDocument.sequences = [
            try Sequence(name: "cluster1", alphabet: .dna, bases: "AACCGGTT"),
            try Sequence(name: "cluster2", alphabet: .dna, bases: "ATATAT"),
        ]

        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.displayDocument(prior)
        viewer.displayDocument(collectionDocument)

        XCTAssertEqual(
            viewer.fastaCollectionSourceURLsForTesting,
            [collectionURL.standardizedFileURL]
        )
    }

    func testMultiDocumentDurableSourcesSurviveSequenceDetailAndBackNavigation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fasta-collection-back-sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root.appendingPathComponent("first.fasta")
        let secondURL = root.appendingPathComponent("second.fasta")
        try ">first\nAAAA\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try ">second\nCCCC\n".write(to: secondURL, atomically: true, encoding: .utf8)
        let first = try Sequence(name: "first", alphabet: .dna, bases: "AAAA")
        let second = try Sequence(name: "second", alphabet: .dna, bases: "CCCC")

        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.displayFASTACollection(
            sequences: [first, second],
            annotations: [],
            sourceNames: [first.id: firstURL.lastPathComponent, second.id: secondURL.lastPathComponent],
            durableSourceURLs: [firstURL, secondURL]
        )
        let collection = try XCTUnwrap(
            viewer.children.compactMap { $0 as? FASTACollectionViewController }.first
        )

        collection.onOpenSequence?(first, [])
        viewer.testTapCollectionBackNavigation()

        XCTAssertEqual(
            viewer.fastaCollectionSourceURLsForTesting,
            [firstURL.standardizedFileURL, secondURL.standardizedFileURL]
        )
        XCTAssertNotNil(viewer.children.compactMap { $0 as? FASTACollectionViewController }.first)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition")
    }

    private func makeBlastResult(label: String, rid: String) -> BlastVerificationResult {
        BlastVerificationResult(
            taxonName: label,
            taxId: 0,
            readResults: [BlastReadResult(
                id: label,
                verdict: .verified,
                topHitOrganism: "Macaca mulatta",
                topHitAccession: "AB123456",
                percentIdentity: 99.5,
                eValue: 0,
                matchesQueriedTaxon: true
            )],
            submittedAt: Date(),
            completedAt: Date(),
            rid: rid,
            blastProgram: "megablast",
            database: "core_nt"
        )
    }
}
