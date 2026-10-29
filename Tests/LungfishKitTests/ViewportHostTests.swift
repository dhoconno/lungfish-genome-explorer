// ViewportHostTests.swift - The host installs one child and refuses a commit from an old token
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishIO
@testable import LungfishKit

@MainActor
final class ViewportHostTests: XCTestCase {
    private let twelveS = SurfaceKind.bundle(.twelveSResult)
    private let kraken2 = SurfaceKind.analysis(AnalysisToolID(rawValue: "kraken2"))

    private var parent: StubSurfaceController!
    private var stubs: StubSurfaceFactory!
    private var host: ViewportHost!

    override func setUp() async throws {
        let registry = SurfaceRegistry()
        parent = StubSurfaceController()
        stubs = StubSurfaceFactory()
        stubs.register([twelveS, kraken2], in: registry)
        host = ViewportHost(registry: registry, containerView: parent.view, parentController: parent)
    }

    override func tearDown() async throws {
        host = nil
        stubs = nil
        parent = nil
    }

    // MARK: - Refusal of an old token

    /// Two shows of the same kind share an identity, so only the generation tells
    /// the older load from the newer one. The older load ends last and is refused.
    func testACommitFromAnOldTokenIsRefused() async {
        stubs.holdsLoad = true
        let older = host.show(kind: twelveS, input: "older")
        stubs.holdsLoad = false
        let newer = host.show(kind: twelveS, input: "newer")

        let newerOutcome = await newer.value
        let olderStub = stubs.made[0]
        let newerStub = stubs.made[1]
        olderStub.releaseLoad()
        let olderOutcome = await older.value

        XCTAssertEqual(label(newerOutcome), "committed")
        XCTAssertEqual(label(olderOutcome), "refused")
        XCTAssertEqual(olderStub.loadedInputs, ["older"])
        XCTAssertFalse(host.isCurrent(olderStub.receivedTokens[0]))
        XCTAssertTrue(host.isCurrent(newerStub.receivedTokens[0]))
        XCTAssertNil(olderStub.viewController.parent)
        XCTAssertNil(olderStub.viewController.view.superview)
        XCTAssertEqual(olderStub.deactivationCount, 0, "a refused surface was never installed")
        XCTAssertTrue(host.activeViewport === newerStub)
        XCTAssertEqual(parent.children, [newerStub.viewController])
        XCTAssertEqual(parent.view.subviews, [newerStub.viewController.view])
    }

    func testALoadThatEndsAfterAClearIsRefused() async {
        stubs.holdsLoad = true
        let task = host.show(kind: kraken2, input: "cleared")
        host.clear()
        stubs.made[0].releaseLoad()
        let outcome = await task.value

        XCTAssertEqual(label(outcome), "refused")
        XCTAssertNil(host.activeViewport)
        XCTAssertNil(host.requestedKind)
        XCTAssertNil(host.loadTask)
        XCTAssertTrue(parent.children.isEmpty)
        XCTAssertTrue(parent.view.subviews.isEmpty)
    }

    // MARK: - One child

    func testExactlyOneChildIsInstalledAfterEachShow() async {
        let kinds = [twelveS, kraken2, twelveS]
        for (index, kind) in kinds.enumerated() {
            let outcome = await host.show(kind: kind, input: "item \(index)").value

            XCTAssertEqual(label(outcome), "committed", "show \(index)")
            let installed = stubs.made[index]
            XCTAssertTrue(host.activeViewport === installed, "show \(index)")
            XCTAssertEqual(host.requestedKind, kind, "show \(index)")
            XCTAssertEqual(parent.children, [installed.viewController], "show \(index)")
            XCTAssertEqual(parent.view.subviews, [installed.viewController.view], "show \(index)")
            parent.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(installed.viewController.view.frame, parent.view.bounds, "show \(index)")
        }
        XCTAssertEqual(stubs.made.map(\.deactivationCount), [1, 1, 0])

        host.clear()

        XCTAssertNil(host.activeViewport)
        XCTAssertNil(host.requestedKind)
        XCTAssertTrue(parent.children.isEmpty)
        XCTAssertTrue(parent.view.subviews.isEmpty)
        XCTAssertEqual(stubs.made.map(\.deactivationCount), [1, 1, 1])
    }

    /// The App shows a result it has already read and wires the Inspector to the
    /// installed controller in the same turn, so a load that does not suspend is
    /// installed before show returns.
    func testALoadThatDoesNotSuspendIsInstalledBeforeShowReturns() {
        host.show(kind: twelveS, input: "read already")

        XCTAssertTrue(host.activeViewport === stubs.made[0])
        XCTAssertEqual(parent.children, [stubs.made[0].viewController])
        guard case .committed = host.lastOutcome else {
            return XCTFail("expected committed, got \(String(describing: host.lastOutcome))")
        }

        stubs.holdsLoad = true
        host.show(kind: kraken2, input: "held")

        XCTAssertNil(host.activeViewport)
        XCTAssertNil(host.lastOutcome, "a held load has no outcome yet")
        stubs.made[1].releaseLoad()
        host.clear()
        XCTAssertNil(host.lastOutcome)
    }

    // MARK: - Failures leave no child and carry words

    func testAShowOfAnUnregisteredKindFailsWithWordsAndRemovesTheOldChild() async {
        _ = await host.show(kind: twelveS, input: "shown").value
        let tree = SurfaceKind.bundle(.phylogeneticTree)

        let outcome = await host.show(kind: tree, input: "tree").value

        guard case .failed(let error) = outcome else {
            return XCTFail("expected a failure, got \(label(outcome))")
        }
        XCTAssertEqual(error as? SurfaceError, .notRegistered(tree))
        XCTAssertTrue(error.localizedDescription.contains("no viewer"), error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains("bundle:phylogenetic-tree"), error.localizedDescription)
        XCTAssertNotNil((error as? LocalizedError)?.recoverySuggestion)
        XCTAssertNil(host.activeViewport)
        XCTAssertEqual(host.requestedKind, tree)
        XCTAssertTrue(parent.children.isEmpty)
        XCTAssertEqual(stubs.made[0].deactivationCount, 1)
    }

    func testALoadThatThrowsLeavesNoChildAndReturnsItsError() async {
        stubs.loadError = CocoaError(.fileReadCorruptFile)

        let outcome = await host.show(kind: kraken2, input: "corrupt").value

        guard case .failed(let error) = outcome else {
            return XCTFail("expected a failure, got \(label(outcome))")
        }
        XCTAssertEqual((error as? CocoaError)?.code, .fileReadCorruptFile)
        XCTAssertNil(host.activeViewport)
        XCTAssertTrue(parent.children.isEmpty)
        XCTAssertTrue(parent.view.subviews.isEmpty)
    }

    func testAnInputOfAnotherTypeFailsWithWords() async {
        let outcome = await host.show(kind: twelveS, input: 12).value

        guard case .failed(let error) = outcome else {
            return XCTFail("expected a failure, got \(label(outcome))")
        }
        XCTAssertEqual(error as? SurfaceError, .unexpectedInput(kind: twelveS, expected: "String"))
        XCTAssertTrue(error.localizedDescription.contains("bundle:12s-result"), error.localizedDescription)
        XCTAssertTrue(parent.children.isEmpty)
    }

    // MARK: - Registry

    func testRegisteringAKindAgainReplacesItsFactory() throws {
        let registry = SurfaceRegistry()
        registry.register(twelveS) { StubResultViewport(kind: .bundle(.fastq)) }
        registry.register(twelveS) { StubResultViewport(kind: .bundle(.twelveSResult)) }

        XCTAssertEqual(try registry.make(twelveS).surfaceKind, twelveS)
        XCTAssertEqual(registry.registeredKinds, [twelveS])
        XCTAssertTrue(registry.isRegistered(twelveS))
        XCTAssertFalse(registry.isRegistered(kraken2))
        XCTAssertEqual(kraken2.description, "analysis:kraken2")
    }

    private func label(_ outcome: SurfaceShowOutcome) -> String {
        switch outcome {
        case .committed: "committed"
        case .refused: "refused"
        case .failed(let error): "failed: \(error.localizedDescription)"
        }
    }
}
