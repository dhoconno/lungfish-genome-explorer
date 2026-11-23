// ReadTimeWriteTests+Reference.swift - A change in the reference and mapping viewers writes nothing into the project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view-state phase, lane VS-REF (the revisit of 2.6 S11). The reference viewer keeps its display settings and
// locus in the view memory store on this Mac. A person's change in a reference (k08) or a mapping result (k22) writes
// nothing into the project, whether the project is writable, held by another writer or holds a read-only bundle. An
// older bundle's own `.viewstate.json` gives only its presentation fields as a starting view, and nothing writes or
// deletes it.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

extension ReadTimeWriteTests {

    // MARK: - No write into the project

    func testAUserChangeInAReferenceAndAMappingResultWritesNothingIntoAWritableProject() async throws {
        let fixture = try makeReferenceProject()
        try await assertUserChangesWriteNothing(into: fixture, "a writable project")
    }

    func testAUserChangeWritesNothingIntoAProjectThatAnotherWriterHolds() async throws {
        let fixture = try makeReferenceProject()
        let other = ProjectLockRecord.current(
            projectURL: fixture.project, mode: "write", toolName: "invented other writer", appVersion: "test")
        try JSONEncoder().encode(other).write(to: ProjectLockManager.lockURL(for: fixture.project), options: .atomic)
        XCTAssertTrue(ProjectOpenWarningState.evaluate(projectURL: fixture.project).isReadOnlyRecommended)
        try await assertUserChangesWriteNothing(into: fixture, "a project another writer holds")
    }

    func testAUserChangeWritesNothingIntoAReadOnlyBundle() async throws {
        let fixture = try makeReferenceProject()
        for bundle in [fixture.reference, fixture.viewerBundle] {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundle.path)
            addTeardownBlock {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.path)
            }
        }
        try await assertUserChangesWriteNothing(into: fixture, "a project whose bundles are 0o555")
    }

    // MARK: - An older bundle's own file

    /// The old file's count filters and locus are not restored, only its presentation fields as a starting view.
    func testAnOlderBundleFileGivesOnlyItsPresentationFieldsAsTheStartingView() async throws {
        let (first, _) = try makeTwoReferences()
        try writeOlderViewStateFile(into: first)
        let olderBytes = try Data(contentsOf: first.url.appendingPathComponent(BundleViewState.filename))
        let store = makeViewMemoryStore()
        let viewer = makeViewer(store: store)
        try await displayRemembered(first, in: viewer)

        XCTAssertEqual(viewer.viewerView.annotationHeight, 31, "The old file's row height is the starting view.")
        XCTAssertEqual(viewer.viewerView.translationColorScheme, .hydrophobicity, "The old file's colour scheme shows.")
        XCTAssertEqual(viewer.annotationFilterText, "", "The old file's annotation filter text was restored.")
        XCTAssertEqual(viewer.viewerView.variantFilterText, "", "The old file's variant filter text was restored.")
        XCTAssertNil(viewer.visibleAnnotationTypes, "The old file's visible types were restored.")
        XCTAssertEqual(viewer.viewerView.hiddenVariantTrackIDs, [], "The old file's hidden tracks were restored.")
        let frame = try XCTUnwrap(viewer.referenceFrame)
        XCTAssertEqual(frame.start, 0, "The old file's locus was restored.")
        XCTAssertEqual(frame.end, Double(frame.sequenceLength), "The old file's locus was restored.")

        viewer.clearBundleDisplay()
        let key = try XCTUnwrap(store.key(for: ViewMemoryItem.read(at: first.url)))
        XCTAssertFalse(
            store.hasRecord(for: key), "Showing an older bundle's look and leaving made an entry, which retires its file (VS S3).")
        XCTAssertEqual(
            try Data(contentsOf: first.url.appendingPathComponent(BundleViewState.filename)), olderBytes,
            "Showing and leaving the bundle changed its old file.")
    }

    /// Reset View leaves a retire mark in the store, so the old file is not read at the next open and the reset is
    /// not undone. Nothing deletes or rewrites the old file.
    func testResetViewLeavesARetireMarkSoTheOlderFileIsNotReadAgain() async throws {
        let (first, second) = try makeTwoReferences()
        try writeOlderViewStateFile(into: first)
        let olderURL = first.url.appendingPathComponent(BundleViewState.filename)
        let olderBytes = try Data(contentsOf: olderURL)
        let store = makeViewMemoryStore()
        let viewer = makeViewer(store: store)
        try await displayRemembered(first, in: viewer)
        XCTAssertEqual(viewer.viewerView.annotationHeight, 31, "The old file's row height is the starting view.")

        viewer.resetBundleViewToDefaults()
        let defaultHeight = CGFloat(AppSettings.shared.defaultAnnotationHeight)
        XCTAssertEqual(viewer.viewerView.annotationHeight, defaultHeight, "Reset View returned the default height.")
        XCTAssertEqual(try? Data(contentsOf: olderURL), olderBytes, "Reset View changed or deleted the old file.")

        try await displayRemembered(second, in: viewer)
        try await displayRemembered(first, in: viewer)
        XCTAssertEqual(viewer.viewerView.annotationHeight, defaultHeight, "The next open read the old file again.")
        XCTAssertEqual(try? Data(contentsOf: olderURL), olderBytes, "The reopen changed or deleted the old file.")
    }

    /// BIO's condition for the revisit: an item's first entry in the store ends the reading of the older file.
    func testTheFirstStoreEntryEndsTheReadingOfTheOlderFile() async throws {
        let (first, _) = try makeTwoReferences()
        try writeOlderViewStateFile(into: first)
        let store = makeViewMemoryStore()
        let viewer = makeViewer(store: store)
        try await displayRemembered(first, in: viewer)
        let request = ReferenceViewerMemoryRequest(input: nil, bundleURL: first.url)
        XCTAssertNotNil(
            ReferenceViewerMemoryRead.read(request, bundleURL: first.url, store: store).olderFile,
            "With no entry the older file is the starting view.")

        viewer.zoomIn() // a person's change
        viewer.clearBundleDisplay()
        XCTAssertNotNil(keptReferenceView(of: first.url, in: store), "The change was not kept.")
        XCTAssertNil(
            ReferenceViewerMemoryRead.read(request, bundleURL: first.url, store: store).olderFile,
            "An item with an entry read the older file again.")
    }

    // MARK: - Helpers

    /// A view memory store under the scratch folder, never the account's.
    func makeViewMemoryStore() -> ViewMemoryStore {
        ViewMemoryStore(root: scratch.appendingPathComponent("view-memory-\(UUID().uuidString)", isDirectory: true))
    }

    /// Shows `fixture` the way the reference route does and waits for the restore.
    func displayRemembered(_ fixture: ReferenceFixture, in viewer: ViewerViewController) async throws {
        try viewer.displayRememberedBundle(
            at: fixture.url, sequenceName: fixture.firstSequence,
            memory: ReferenceViewerMemoryRequest(input: nil, bundleURL: fixture.url), bundle: nil)
        let settled = await waitUntil(budget: .lookup) { viewer.viewMemoryIsSettled }
        XCTAssertTrue(settled, "The restore of \(fixture.url.lastPathComponent) did not run.")
    }

    /// The reference view the store keeps for the item at `url`, read as the next open reads it.
    func keptReferenceView(of url: URL, in store: ViewMemoryStore) -> ReferenceViewerMemory? {
        let item = ViewMemoryItem.read(at: url)
        if let root = item.projectRoot { store.loadProject(at: root) } else { store.loadLoose() }
        guard let key = store.key(for: item),
              case .view(let view, _, _) = store.restorable(ReferenceViewerMemory.self, for: key, folder: item.folder)
        else { return nil }
        return view
    }

    /// What an older build wrote: presentation fields, count filters and a locus.
    private func writeOlderViewStateFile(into fixture: ReferenceFixture) throws {
        let older = BundleViewState(
            annotationHeight: 31, annotationSpacing: 5, visibleAnnotationTypes: [.gene], annotationFilterText: "gene-x",
            variantFilterText: "QUAL > 30", hiddenVariantTrackIDs: ["track-1"], translationColorScheme: .hydrophobicity,
            lastChromosome: fixture.firstSequence, lastOrigin: 100, lastScale: 0.5)
        let data = try JSONEncoder().encode(older)
        try data.write(to: fixture.url.appendingPathComponent(BundleViewState.filename))
    }

    private struct ReferenceProject {
        let project: URL
        let reference: URL
        let resultDirectory: URL
        let viewerBundle: URL
    }

    /// A project with a reference bundle and a mapping result whose viewer bundle sits in the result's folder.
    private func makeReferenceProject() throws -> ReferenceProject {
        let project = scratch.appendingPathComponent("Reference.lungfish", isDirectory: true)
        _ = try ProjectFile.create(at: project, name: "Reference")
        let reference = try MappingRoutingFixture.makeReferenceBundle(
            name: "Kept", chromosomes: [.init(name: "chr1", length: 5_000), .init(name: "chr2", length: 3_000)],
            in: project.appendingPathComponent("Reference Sequences", isDirectory: true))
        let result = project.appendingPathComponent("Analyses/minimap2-kept", isDirectory: true)
        let viewerBundle = try MappingRoutingFixture.makeReferenceBundle(
            name: "Viewer", chromosomes: [.init(name: "chr1", length: 5_000), .init(name: "chr2", length: 3_000)],
            in: result)
        return ReferenceProject(project: project, reference: reference, resultDirectory: result, viewerBundle: viewerBundle)
    }

    /// Opens the reference and the mapping result in turn, makes a person's change in each and leaves, then requires
    /// the project's digest unchanged and each item's view in the store.
    private func assertUserChangesWriteNothing(into fixture: ReferenceProject, _ label: String) async throws {
        let store = makeViewMemoryStore()
        store.loadProject(at: fixture.project)
        let before = try ProjectDigest(of: fixture.project)
        let contigs = [("chr1", 5_000, 90), ("chr2", 3_000, 40)].map { name, length, reads in
            MappingContigSummary(
                contigName: name, contigLength: length, mappedReads: reads, mappedReadPercent: Double(reads),
                meanDepth: 2, coverageBreadth: 0.5, medianMAPQ: 60, meanIdentity: 0.99)
        }
        for item in [fixture.reference, fixture.resultDirectory] {
            let viewport = ReferenceBundleViewportController()
            _ = viewport.view
            let viewer = viewport.testEmbeddedViewerController
            viewer.viewMemoryStore = store
            if item == fixture.reference {
                try viewport.configureForTesting(
                    input: .directBundle(bundleURL: item, manifest: try BundleManifest.load(from: item)))
            } else {
                viewport.configureForTesting(
                    result: MappingRoutingFixture.makeMappingResult(
                        resultDirectory: item, viewerBundleURL: fixture.viewerBundle, contigs: contigs),
                    resultDirectoryURL: item)
            }
            let shown = await waitUntil(budget: .lookup) { viewer.currentBundleURL != nil && viewer.viewMemoryIsSettled }
            XCTAssertTrue(shown, "\(item.lastPathComponent) was not shown in \(label).")
            viewer.zoomIn() // a person's change
            viewer.clearBundleDisplay()
            XCTAssertNotNil(keptReferenceView(of: item, in: store), "\(item.lastPathComponent) kept no view in \(label).")
        }
        store.flushSynchronously()
        XCTAssertEqual(
            try ProjectDigest(of: fixture.project).differences(from: before).map(\.summary), [],
            "A person's change wrote into \(label).")
    }
}
