// WindowProjectSwitchResetTests.swift - The viewport resets when a window changes project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO

/// Opening a different project into an existing window must not leave the
/// previous project's viewport on screen (2026.9.41: a reference bundle's
/// alignment viewport, contig table and coverage survived a project switch
/// even though the new project had no such item and nothing was selected).
@MainActor
final class WindowProjectSwitchResetTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowProjectSwitch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func makeProject(named name: String, sequences: [String] = []) throws -> URL {
        let url = root.appendingPathComponent("\(name).lungfish", isDirectory: true)
        let project = try ProjectFile.create(at: url, name: name)
        for sequenceName in sequences {
            _ = try project.addSequence(Sequence(name: sequenceName, alphabet: .dna, bases: "ACGTACGT"))
        }
        try project.save()
        return url
    }

    private func makeReferenceBundle(in projectURL: URL) throws -> URL {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "chr20", chromosomes: [.init(name: "chr20", length: 120)]
        )
        try MappingRoutingFixture.addSingleSampleAlignment(to: bundleURL, sampleID: "S1")
        let destination = projectURL.appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: bundleURL, to: destination)
        try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent())
        return destination
    }

    private func spinRunLoop(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func showReferenceBundle(_ bundleURL: URL, in split: MainSplitViewController) throws {
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)
        spinRunLoop { split.viewerController.referenceBundleViewportController != nil }
        XCTAssertNotNil(split.viewerController.referenceBundleViewportController)
        XCTAssertEqual(split.viewerController.contentMode, .mapping)
    }

    private func assertViewportIsEmpty(_ split: MainSplitViewController, file: StaticString = #filePath, line: UInt = #line) {
        let viewer = split.viewerController!
        XCTAssertNil(viewer.referenceBundleViewportController,
            "The previous project's reference bundle viewport must be torn down", file: file, line: line)
        XCTAssertNil(viewer.mappingResultController, file: file, line: line)
        XCTAssertEqual(viewer.contentMode, .empty, file: file, line: line)
        XCTAssertNil(viewer.currentBundleURL, file: file, line: line)
        XCTAssertNil(viewer.currentDocument, file: file, line: line)
        XCTAssertNil(viewer.restorableContentState(), file: file, line: line)
        XCTAssertFalse(viewer.isAnnotationDrawerOpen, file: file, line: line)
        XCTAssertFalse(viewer.statusBar.isHidden, file: file, line: line)
        XCTAssertEqual(viewer.statusBar.positionLabel.stringValue, "No sequence selected", file: file, line: line)
        XCTAssertNil(split.activeContentSelectionIdentity, file: file, line: line)
        XCTAssertTrue(split.sidebarController.selectedItems().isEmpty, file: file, line: line)
        XCTAssertNil(split.bamMetadataPresentationContext, file: file, line: line)
        XCTAssertFalse(split.inspectorController.viewModel.documentSectionViewModel.hasAnyContent, file: file, line: line)
    }

    func testSwitchingProjectsClearsTheViewportWhenTheNewProjectHasNoDocuments() throws {
        let demo = try makeProject(named: "Demo")
        let williams = try makeProject(named: "Williams")
        let bundleURL = try makeReferenceBundle(in: demo)

        let session = ProjectSession()
        try session.openProject(at: demo)
        let split = MainSplitViewController(projectSession: session)
        _ = split.view
        split.applyProjectSessionState()
        try showReferenceBundle(bundleURL, in: split)

        try session.openProject(at: williams)
        split.applyProjectSessionState()

        assertViewportIsEmpty(split)
    }

    func testSwitchingProjectsClearsTheViewportBeforeTheNewProjectHydrates() throws {
        let demo = try makeProject(named: "Demo")
        let williams = try makeProject(named: "Williams", sequences: ["first"])
        let bundleURL = try makeReferenceBundle(in: demo)

        let session = ProjectSession()
        try session.openProject(at: demo)
        let split = MainSplitViewController(projectSession: session)
        _ = split.view
        split.applyProjectSessionState()
        try showReferenceBundle(bundleURL, in: split)

        // The new project's first document hydrates slowly; the old viewport
        // must already be gone while the load is pending.
        session.hydrationLoader = { _, _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        }
        try session.openProject(at: williams)
        split.applyProjectSessionState()
        defer { split.invalidateDisplayRequest() }

        XCTAssertNotNil(split.externalDocumentLoadTask, "Williams' first document should be loading")
        XCTAssertNil(split.viewerController.referenceBundleViewportController)
        XCTAssertEqual(split.viewerController.contentMode, .empty)
        XCTAssertNil(split.viewerController.currentBundleURL)
        XCTAssertNil(split.bamMetadataPresentationContext)
    }

    func testInFlightReferenceBundleLoadForTheOldProjectDoesNotInstallAfterTheSwitch() throws {
        let demo = try makeProject(named: "Demo")
        let williams = try makeProject(named: "Williams")
        let bundleURL = try makeReferenceBundle(in: demo)

        let session = ProjectSession()
        try session.openProject(at: demo)
        let split = MainSplitViewController(projectSession: session)
        _ = split.view
        split.applyProjectSessionState()

        // The reference bundle route defers its install to the next runloop turn.
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)
        XCTAssertNil(split.viewerController.referenceBundleViewportController)

        try session.openProject(at: williams)
        split.applyProjectSessionState()
        spinRunLoop(until: { false }, timeout: 0.5)

        assertViewportIsEmpty(split)
    }

    func testInFlightProjectSequenceHydrationForTheOldProjectDoesNotInstallAfterTheSwitch() async throws {
        let demo = try makeProject(named: "Demo", sequences: ["old"])
        let williams = try makeProject(named: "Williams")

        let session = ProjectSession()
        let hydrationStarted = expectation(description: "old project hydration started")
        let release = ReleaseGate()
        session.hydrationLoader = { _, sequenceID in
            hydrationStarted.fulfill()
            await release.wait()
            let sequence = try Sequence(id: sequenceID, name: "old", alphabet: .dna, bases: "ACGTACGT")
            return ProjectHydrationSnapshot(sequence: sequence, annotations: [])
        }
        try session.openProject(at: demo)
        let split = MainSplitViewController(projectSession: session)
        _ = split.view
        split.applyProjectSessionState()
        let hydration = try XCTUnwrap(split.externalDocumentLoadTask)
        await fulfillment(of: [hydrationStarted], timeout: 5)

        session.hydrationLoader = nil
        try session.openProject(at: williams)
        split.applyProjectSessionState()
        release.open()
        await hydration.value

        assertViewportIsEmpty(split)
    }
}

private actor ReleaseGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    nonisolated func open() {
        Task { await self.release() }
    }

    private func release() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
