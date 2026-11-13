// WindowEventPosterScopeTests.swift - Every poster of a window event attaches its scope (R9)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import ViewInspector
@testable import LungfishApp
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishTaxonomyUI

/// One behavioural test per family of window-event posters that lane 1f
/// changed. Each test triggers the real post and checks that the window's
/// scope rides along while the rest of the payload stays as it was.
@MainActor
final class WindowEventPosterScopeTests: XCTestCase {

    // MARK: - Viewers a container embeds without a scope

    func testEmbeddedViewerPostsWithTheScopeOfTheWindowThatShowsIt() throws {
        let window = ScopeOwningWindowController()
        let viewer = ViewerViewController()
        window.host(viewer.view)
        let recorder = PostedEventRecorder(.annotationSelected)
        defer { recorder.stop() }
        let annotation = SequenceAnnotation(type: .gene, name: "gag", chromosome: "chr1", start: 0, end: 30)

        viewer.viewerView.postAnnotationSelectedNotification(annotation, postVariantSelection: false)

        let posted = try XCTUnwrap(recorder.last)
        XCTAssertEqual(posted.windowScope, window.windowStateScope)
        XCTAssertEqual((posted.userInfo?[NotificationUserInfoKey.annotation] as? SequenceAnnotation)?.name, "gag")
        XCTAssertEqual(posted.userInfo?.count, 2)
    }

    func testAnAssignedViewerScopeWinsOverTheHostingWindow() throws {
        let window = ScopeOwningWindowController()
        let viewer = ViewerViewController()
        let assigned = WindowStateScope()
        viewer.windowStateScope = assigned
        window.host(viewer.view)
        let recorder = PostedEventRecorder(.activeSequenceChanged)
        defer { recorder.stop() }

        viewer.setActiveSequence(index: 0)

        let posted = try XCTUnwrap(recorder.last)
        XCTAssertEqual(posted.windowScope, assigned)
        XCTAssertEqual(posted.userInfo?["activeSequenceIndex"] as? Int, 0)
    }

    func testEmbeddedAnnotationDrawerPostsWithTheScopeOfTheWindowThatShowsIt() throws {
        let window = ScopeOwningWindowController()
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        window.host(drawer)
        let recorder = PostedEventRecorder(.sampleDisplayStateChanged)
        defer { recorder.stop() }

        drawer.postSampleDisplayStateChange()

        let posted = try XCTUnwrap(recorder.last)
        XCTAssertEqual(posted.windowScope, window.windowStateScope)
        XCTAssertNotNil(posted.userInfo?[NotificationUserInfoKey.sampleDisplayState] as? SampleDisplayState)
    }

    func testChromosomeNavigatorShowInInspectorCarriesTheWindowScope() throws {
        let window = ScopeOwningWindowController()
        let navigator = ChromosomeNavigatorView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        navigator.chromosomes = [ChromosomeInfo(name: "seg1", length: 1741, offset: 0, lineBases: 60, lineWidth: 61)]
        window.host(navigator)
        navigator.testingSelectRows([0])
        let recorder = PostedEventRecorder(.chromosomeInspectorRequested)
        defer { recorder.stop() }

        navigator.showSelectedRowInInspector(nil)

        let posted = try XCTUnwrap(recorder.last)
        XCTAssertEqual(posted.windowScope, window.windowStateScope)
        XCTAssertEqual((posted.userInfo?[NotificationUserInfoKey.chromosome] as? ChromosomeInfo)?.name, "seg1")
        XCTAssertEqual(posted.userInfo?[NotificationUserInfoKey.switchInspectorTab] as? Bool, true)
    }

    // MARK: - Sidebar drops

    func testSidebarFileDropCarriesTheSidebarsWindowScope() throws {
        let sidebar = SidebarViewController()
        let scope = WindowStateScope()
        sidebar.windowStateScope = scope
        let recorder = PostedEventRecorder(.sidebarFileDropped)
        defer { recorder.stop() }
        let url = URL(fileURLWithPath: "/tmp/dropped.fasta")

        sidebar.postFileDrop([url], destination: NSNull())

        let posted = try XCTUnwrap(recorder.last)
        XCTAssertEqual(posted.windowScope, scope)
        XCTAssertEqual(posted.userInfo?["urls"] as? [URL], [url])
        XCTAssertTrue(posted.userInfo?["destination"] is NSNull)
        XCTAssertTrue((posted.object as? SidebarViewController) === sidebar)
    }

    // MARK: - Inspector sections that post on their own

    func testInspectorSectionFallbackPostsCarryTheInspectorScope() throws {
        let inspector = InspectorViewController()
        _ = inspector.view
        let scope = WindowStateScope()
        inspector.testingWindowStateScope = scope
        let annotations = inspector.viewModel.annotationSectionViewModel
        annotations.onSettingsChanged = nil
        annotations.onFilterChanged = nil
        annotations.onVariantFilterChanged = nil
        let samples = inspector.viewModel.sampleSectionViewModel
        samples.onDisplayStateChanged = nil
        let settings = PostedEventRecorder(.annotationSettingsChanged)
        let filters = PostedEventRecorder(.annotationFilterChanged)
        let variants = PostedEventRecorder(.variantFilterChanged)
        let display = PostedEventRecorder(.sampleDisplayStateChanged)
        defer { [settings, filters, variants, display].forEach { $0.stop() } }

        annotations.notifySettingsChanged()
        annotations.notifyFilterChanged()
        annotations.notifyVariantFilterChanged()
        samples.resetToDefaults()

        XCTAssertEqual(try XCTUnwrap(settings.last).windowScope, scope)
        XCTAssertEqual(try XCTUnwrap(settings.last).userInfo?.count, 4)
        XCTAssertEqual(try XCTUnwrap(filters.last).windowScope, scope)
        XCTAssertEqual(try XCTUnwrap(filters.last).userInfo?.count, 3)
        XCTAssertEqual(try XCTUnwrap(variants.last).windowScope, scope)
        XCTAssertEqual(try XCTUnwrap(variants.last).userInfo?.count, 5)
        XCTAssertEqual(try XCTUnwrap(display.last).windowScope, scope)
        XCTAssertNotNil(try XCTUnwrap(display.last).userInfo?[NotificationUserInfoKey.sampleDisplayState])
    }

    func testGenotypeEditCallsButtonCarriesTheInspectorScope() throws {
        let inspector = InspectorViewController()
        _ = inspector.view
        let scope = WindowStateScope()
        inspector.testingWindowStateScope = scope
        let selection = inspector.viewModel.selectionSectionViewModel
        selection.select(genotypeResultSelection: .init(
            title: "Animal A",
            subtitle: "Selected sample",
            detailRows: [("Identity", "Animal-A")],
            animalId: "AnimalA"
        ))
        let recorder = PostedEventRecorder(.genotypeResultRequestSampleDetailSheet)
        defer { recorder.stop() }

        try SelectionSection(viewModel: selection).inspect().find(button: "Edit calls…").tap()

        let posted = try XCTUnwrap(recorder.last)
        XCTAssertEqual(posted.windowScope, scope)
        XCTAssertEqual(posted.userInfo?["sample"] as? String, "AnimalA")
    }

    func testGenotypeDocumentControlsCarryTheDocumentScope() throws {
        let scope = WindowStateScope()
        let document = DocumentSectionViewModel()
        document.updateGenotypeResultDocument(GenotypeResultDocumentState(
            title: "Genotypes",
            sampleIds: ["AnimalA"],
            windowStateScope: scope,
            summaryRows: [],
            qcRows: [],
            artifactRows: []
        ))
        let viewModes = PostedEventRecorder(.genotypeResultViewModeChanged)
        let ancillary = PostedEventRecorder(.genotypeResultShowsAncillaryLociChanged)
        defer { viewModes.stop(); ancillary.stop() }

        let section = try DocumentSection(viewModel: document)
            .inspect()
            .find(GenotypeResultDocumentSection.self)
            .actualView()
        section.onViewModeChange?(.matrix)
        section.onShowsAncillaryLociChange?(true)

        XCTAssertEqual(try XCTUnwrap(viewModes.last).windowScope, scope)
        XCTAssertEqual(try XCTUnwrap(viewModes.last).userInfo?["mode"] as? String, GenotypeSummaryViewMode.matrix.rawValue)
        XCTAssertEqual(try XCTUnwrap(ancillary.last).windowScope, scope)
        XCTAssertEqual(try XCTUnwrap(ancillary.last).userInfo?["showsAncillaryLoci"] as? Bool, true)
    }

    // MARK: - Split view and app delegate

    func testBatchSampleFilterCarriesTheSplitViewScope() throws {
        let split = MainSplitViewController()
        _ = split.view
        _ = try split.viewerController.showSurface(
            .analysis(.kraken2), input: TaxonomyViewController(), as: Kraken2Surface.self
        )
        let recorder = PostedEventRecorder(.metagenomicsSampleSelectionChanged)
        defer { recorder.stop() }

        split.filterBatchViewToSingleSample(sampleId: "S1")

        let posted = try XCTUnwrap(recorder.last)
        XCTAssertEqual(posted.windowScope, split.windowStateScope)
        XCTAssertEqual(posted.userInfo?.count, 1)
    }

    func testAIAssistantSwitchesOnlyItsOwnWindowToTheAITab() throws {
        let originalAISetting = AppSettings.shared.aiSearchEnabled
        AppSettings.shared.aiSearchEnabled = true
        defer { AppSettings.shared.aiSearchEnabled = originalAISetting }
        let delegate = makeAppDelegateWithTemporaryState()
        let controller = MainWindowController(projectSession: ProjectSession())
        defer { controller.close() }
        delegate.mainWindowController = controller
        let recorder = PostedEventRecorder(.showInspectorRequested)
        defer { recorder.stop() }

        delegate.handleShowAIAssistant(Notification(name: .showAIAssistantRequested))

        let posted = try XCTUnwrap(recorder.last)
        XCTAssertEqual(posted.windowScope, controller.projectSession.windowStateScope)
        XCTAssertEqual(posted.userInfo?[NotificationUserInfoKey.inspectorTab] as? String, "ai")
    }

    // MARK: - Affected results notice

    /// The Inspector tells the viewers of its window which rows of the affected-results table matched. The notice is a
    /// window event, so it carries the scope of the window that shows the Inspector.
    func testTheAffectedResultsNoticeCarriesTheScopeOfTheInspectorsWindow() throws {
        let inspector = InspectorViewController()
        _ = inspector.view
        let scope = WindowStateScope()
        inspector.windowStateScope = scope
        let recorder = PostedEventRecorder(.affectedResultsDidChange)
        defer { recorder.stop() }
        let item = ProvenanceInspectableItem(
            url: URL(fileURLWithPath: "/tmp/affected-results-test"), sidebarType: .taxTriageResult,
            contentMode: .metagenomics, displayName: "result"
        )

        inspector.provenanceSectionViewModel.applyAffectedResults(item: item)

        let posted = try XCTUnwrap(recorder.last)
        XCTAssertEqual(posted.windowScope, scope)
    }

    /// A strip takes the notice of its own window's Inspector and ignores the notice of every other window and a
    /// notice with no scope. An empty notice takes the strip away, so a strip that stays shows a dropped notice.
    func testTheAffectedResultsNoticeReachesOnlyTheViewerOfItsOwnWindow() throws {
        let own = WindowStateScope()
        let viewer = ViewerViewController()
        viewer.windowStateScope = own
        _ = viewer.view
        _ = try viewer.showSurface(.analysis(.kraken2), input: TaxonomyViewController(), as: Kraken2Surface.self)
        let surfaceView = try XCTUnwrap(viewer.installedSurface?.viewController.view)
        XCTAssertTrue(surfaceView.superview === viewer.view, "the strip sits in the viewer's own view")
        AffectedResultsStrip.place(words: "An earlier build made this result wrong.", above: surfaceView, in: viewer.view)
        XCTAssertNotNil(AffectedResultsStrip.strip(in: viewer.view))

        func postNotice(scope: WindowStateScope?) {
            NotificationCenter.default.post(
                name: .affectedResultsDidChange, object: ProvenanceInspectorViewModel(),
                userInfo: ScopedEventFilter.scopedUserInfo(scope: scope)
            )
        }

        postNotice(scope: WindowStateScope())
        XCTAssertNotNil(AffectedResultsStrip.strip(in: viewer.view), "the notice of another window leaves this strip")
        postNotice(scope: nil)
        XCTAssertNotNil(AffectedResultsStrip.strip(in: viewer.view), "a window event with no scope is dropped")
        postNotice(scope: own)
        XCTAssertNil(AffectedResultsStrip.strip(in: viewer.view), "the notice of this window takes the strip away")
    }

    // MARK: - Window-owned project session

    func testMirroredProjectOpenCarriesTheSessionWindowScope() throws {
        let directory = try TestTempDirectory.make(prefix: "ScopedProjectOpen")
        defer { TestTempDirectory.cleanup(directory) }
        let project = try ProjectFile.create(at: directory.appendingPathComponent("Scoped.lungfish"), name: "Scoped")
        let session = ProjectSession()
        DocumentManager.shared.mirrorProjectSession(session)
        defer {
            DocumentManager.shared.closeActiveProject()
            session.closeProject()
        }
        let recorder = PostedEventRecorder(DocumentManager.projectOpenedNotification)
        defer { recorder.stop() }

        _ = try DocumentManager.shared.openProject(at: project.url)

        let posted = try XCTUnwrap(recorder.last)
        XCTAssertEqual(posted.windowScope, session.windowStateScope)
        XCTAssertEqual(posted.userInfo?["sessionID"] as? UUID, session.id)
    }
}

/// Records every post of one notification name on the default center. Posts
/// in these tests happen on the main thread, so delivery is synchronous.
private final class PostedEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var notifications: [Notification] = []
    private var token: NSObjectProtocol?

    init(_ name: Notification.Name) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
            self?.record(notification)
        }
    }

    var last: Notification? {
        lock.lock()
        defer { lock.unlock() }
        return notifications.last
    }

    func stop() {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        token = nil
    }

    private func record(_ notification: Notification) {
        lock.lock()
        notifications.append(notification)
        lock.unlock()
    }
}

private extension Notification {
    var windowScope: WindowStateScope? {
        userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope
    }
}
