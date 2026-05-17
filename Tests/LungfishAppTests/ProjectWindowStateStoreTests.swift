import XCTest
@testable import LungfishApp

@MainActor
final class ProjectWindowStateStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var stateURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectWindowStateStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        stateURL = tempRoot.appendingPathComponent("window-state.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    func testSaveAndLoadRoundTripPreservesDuplicateProjectWindows() throws {
        let projectURL = tempRoot.appendingPathComponent("Shared.lungfish", isDirectory: true)
        let first = ProjectWindowSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            projectURL: projectURL,
            windowOrdinal: 1,
            windowOrder: 0,
            windowTitleSuffix: "[1]",
            frame: CodableWindowFrame(x: 10, y: 20, width: 900, height: 700),
            isFullScreen: false,
            selectedSidebarURL: projectURL.appendingPathComponent("Analyses/run-a.lungfishrun", isDirectory: true),
            expandedSidebarURLs: [projectURL.appendingPathComponent("Analyses", isDirectory: true)],
            sidebarSearchText: "variants",
            activeContent: RestorableContentState(
                kind: "mapping",
                url: projectURL.appendingPathComponent("Analyses/run-a.lungfishrun", isDirectory: true),
                payload: ["contig": "NC_045512.2"]
            ),
            inspectorTab: "document",
            sidebarCollapsed: false,
            inspectorCollapsed: false,
            sidebarWidth: 280,
            inspectorWidth: 340,
            operationsPanelFilter: "currentWindow",
            operationsPanelVisible: true
        )
        let second = ProjectWindowSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            projectURL: projectURL,
            windowOrdinal: 2,
            windowOrder: 1,
            windowTitleSuffix: "[2]",
            frame: CodableWindowFrame(x: 80, y: 90, width: 1000, height: 760),
            isFullScreen: false,
            selectedSidebarURL: projectURL.appendingPathComponent("Imports/sample.lungfishfastq", isDirectory: true),
            expandedSidebarURLs: [projectURL.appendingPathComponent("Imports", isDirectory: true)],
            sidebarSearchText: nil,
            activeContent: RestorableContentState(
                kind: "fastq",
                url: projectURL.appendingPathComponent("Imports/sample.lungfishfastq", isDirectory: true),
                payload: ["drawer": "metadata"]
            ),
            inspectorTab: "selection",
            sidebarCollapsed: false,
            inspectorCollapsed: true,
            sidebarWidth: 240,
            inspectorWidth: 300,
            operationsPanelFilter: "currentProject",
            operationsPanelVisible: false
        )
        let store = ProjectWindowStateStore(stateURL: stateURL)

        try store.save(ProjectWindowStateEnvelope(windows: [first, second]))
        let loaded = try store.load()

        XCTAssertEqual(loaded.windows.count, 2)
        XCTAssertEqual(loaded.windows.map(\.windowOrdinal), [1, 2])
        XCTAssertEqual(loaded.windows.map(\.windowTitleSuffix), ["[1]", "[2]"])
        XCTAssertEqual(loaded.windows[0].projectURL.standardizedFileURL, projectURL.standardizedFileURL)
        XCTAssertEqual(loaded.windows[1].activeContent?.kind, "fastq")
        XCTAssertEqual(loaded.windows[0].operationsPanelFilter, "currentWindow")
    }

    func testLoadMissingFileReturnsEmptyEnvelope() throws {
        let store = ProjectWindowStateStore(stateURL: stateURL)
        let loaded = try store.load()
        XCTAssertTrue(loaded.windows.isEmpty)
    }
}
