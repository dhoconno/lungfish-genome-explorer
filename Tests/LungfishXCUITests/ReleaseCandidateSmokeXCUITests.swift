import AppKit
import XCTest

/// Release smoke tasks for the classes of the Phase 2 Stable blockers (3.0 lane UIP). Each runs on the
/// exact candidate through `ReleaseAppSmokeRobot` with fixtures the test builds, and needs no managed tool.
final class ReleaseCandidateSmokeXCUITests: XCTestCase {
    /// obs-22. Selecting a `.lungfishtree` must not grow the window past the visible screen.
    @MainActor
    func testReleaseCandidateTreeWindowStaysOnScreen() throws {
        let robot = try ReleaseAppSmokeRobot()
        let cli = robot.candidateURL.appendingPathComponent("Contents/MacOS/lungfish-cli")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path), "The candidate embeds lungfish-cli")
        setenv("LUNGFISH_TEST_CLI", cli.path, 1)
        let project = try LungfishProjectFixtureBuilder.makeAlignmentTreeBundleProject(named: "ReleaseTree-\(UUID().uuidString)")
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        try robot.launch()
        robot.openProject(project)
        let browser = BundleBrowserRobot(app: robot.app)
        browser.openBundle(named: "MHC Tree.lungfishtree")
        browser.waitForPhylogeneticTreeViewer()
        XCTAssertTrue(browser.treeFitButton.waitForExistence(timeout: 10))
        let frame = robot.window(project).frame
        XCTAssertTrue(ReleaseSmokeScreen.fits(frame),
                      "The window \(frame) must stay inside a visible screen \(ReleaseSmokeScreen.visibleFrames())")
    }

    /// OBS-W6 class. The Inspector shows only the blocks of the result now on screen.
    @MainActor
    func testReleaseCandidateInspectorShowsOnlyTheCurrentResult() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try ReleaseSmokeFixtures.makeClassifierResultsProject(named: "ReleaseInspector-\(UUID().uuidString)")
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        try robot.launch()
        robot.openProject(project)
        let steps = [("kraken2", "Classification Result"), ("esviritu", "Viral Detection Result"),
                     ("taxtriage", "Comprehensive Triage Result")]
        var previous: String?
        for (folder, title) in steps {
            ReleaseSmokeFixtures.openSidebarItem(containing: folder, in: robot.app)
            let block = robot.app.staticTexts[title].firstMatch
            if !block.waitForExistence(timeout: 10) {
                robot.app.buttons["main-window-toggle-inspector"].firstMatch.click()
            }
            XCTAssertTrue(block.waitForExistence(timeout: 10), "The Inspector shows \(title) for the \(folder) result")
            if let previous {
                XCTAssertTrue(robot.app.staticTexts[previous].firstMatch.waitForNonExistence(timeout: 5),
                              "The Inspector still shows \(previous) after the \(folder) result opened")
            }
            previous = title
        }
    }

    /// OBS-W8. A ZIP dropped on the sidebar lands its bundle in the project and leaves no staging folder.
    @MainActor
    func testReleaseCandidateDroppedZipLandsItsBundle() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: "ReleaseZip-\(UUID().uuidString)")
        let archive = try ReleaseSmokeFixtures.makeBundleArchive(named: "DroppedGenome")
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
        }
        try robot.launch()
        robot.openProject(project)
        ReleaseSmokeFixtures.dragFromFinder(archive, onto: robot.window(project).outlines["sidebar-outline"])
        let landed = NSPredicate { _, _ in !ReleaseSmokeFixtures.paths(in: project, named: "DroppedGenome.lungfishref").isEmpty }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landed, object: nil)], timeout: 30), .completed,
                       "The dropped bundle lands in the project outside .tmp")
        XCTAssertEqual(ReleaseSmokeFixtures.paths(in: project, named: "sidebar-zip-import", includeStaging: true).count, 0,
                       "No staging folder is left behind")
    }

    /// OBS-W9. A ZIP holding a link out of the archive is refused with words that name it, and changes nothing.
    @MainActor
    func testReleaseCandidateRefusedZipShowsWords() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: "ReleaseRefusedZip-\(UUID().uuidString)")
        let archive = try ReleaseSmokeFixtures.makeEscapingLinkArchive()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
        }
        try robot.launch()
        robot.openProject(project)
        let before = ReleaseSmokeFixtures.listing(of: project)
        ReleaseSmokeFixtures.dragFromFinder(archive, onto: robot.window(project).outlines["sidebar-outline"])
        let words = robot.app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", archive.lastPathComponent)).firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 15), "The refusal names \(archive.lastPathComponent)")
        robot.app.buttons["OK"].firstMatch.click()
        XCTAssertEqual(ReleaseSmokeFixtures.listing(of: project), before, "A refused archive changes nothing in the project")
    }
}

@MainActor
enum ReleaseSmokeScreen {
    /// Visible frames in XCUI's coordinates, which start at the top left of the primary screen.
    static func visibleFrames() -> [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { screen in
            let visible = screen.visibleFrame
            return CGRect(x: visible.minX, y: primary.frame.height - visible.maxY, width: visible.width, height: visible.height)
        }
    }

    static func fits(_ frame: CGRect) -> Bool {
        visibleFrames().contains { $0.insetBy(dx: -2, dy: -2).contains(frame) }
    }
}

@MainActor
enum ReleaseSmokeFixtures {
    /// A project holding the Kraken2, EsViritu and TaxTriage results of `Tests/Fixtures/analyses`.
    static func makeClassifierResultsProject(named name: String) throws -> URL {
        let project = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: name)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let results = [("kraken2-2026-01-15T11-00-00", "kraken2"), ("esviritu-2026-01-15T10-00-00", "esviritu"),
                       ("taxtriage-2026-01-15T12-00-00", "taxtriage")]
        for (folder, tool) in results {
            let destination = analyses.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.copyItem(at: LungfishFixtureCatalog.analyses.appendingPathComponent(folder), to: destination)
            let metadata: [String: Any] = ["created": ISO8601DateFormatter().string(from: Date()), "isBatch": false, "tool": tool]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: destination.appendingPathComponent("analysis-metadata.json"))
        }
        return project
    }

    /// A ZIP holding one reference bundle named `name`, in a folder of its own.
    static func makeBundleArchive(named name: String) throws -> URL {
        let source = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: "ZipSource")
        let folder = source.deletingLastPathComponent()
        let bundle = folder.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.moveItem(at: source.appendingPathComponent("TestGenome.lungfishref"), to: bundle)
        try FileManager.default.removeItem(at: source)
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", bundle.lastPathComponent, "\(name).zip"], in: folder)
        try FileManager.default.removeItem(at: bundle)
        return folder.appendingPathComponent("\(name).zip")
    }

    /// A ZIP whose only entry is a link to a file outside the archive.
    static func makeEscapingLinkArchive() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-xcui-zip-\(UUID().uuidString)", isDirectory: true)
        let inside = folder.appendingPathComponent("EscapingLink", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: inside.appendingPathComponent("hosts").path, withDestinationPath: "/etc/hosts")
        try run("/usr/bin/zip", ["-q", "-r", "-y", "EscapingLink.zip", "EscapingLink"], in: folder)
        try FileManager.default.removeItem(at: inside)
        return folder.appendingPathComponent("EscapingLink.zip")
    }

    /// Clicks the first sidebar row whose words contain `text`, opening the Analyses group when needed.
    static func openSidebarItem(containing text: String, in app: XCUIApplication) {
        let outline = app.outlines["sidebar-outline"].firstMatch
        let matching = NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        let item = outline.staticTexts.matching(matching).firstMatch
        if !item.waitForExistence(timeout: 5) {
            let group = app.descendants(matching: .any)["sidebar-group-analyses"].firstMatch
            XCTAssertTrue(group.waitForExistence(timeout: 5))
            group.click()
            app.typeKey(.rightArrow, modifierFlags: [.option])
        }
        XCTAssertTrue(item.waitForExistence(timeout: 10), "The sidebar shows a row for \(text)")
        item.click()
    }

    /// Shows `file` in a Finder window and drags it onto `target`, then closes that window.
    static func dragFromFinder(_ file: URL, onto target: XCUIElement) {
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        NSWorkspace.shared.activateFileViewerSelecting([file])
        let names = [file.lastPathComponent, file.deletingPathExtension().lastPathComponent]
        let item = finder.windows.firstMatch.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@ OR value IN %@", names, names)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "Finder shows \(file.lastPathComponent)")
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        item.press(forDuration: 1.0, thenDragTo: target)
        let window = finder.windows.firstMatch
        if window.exists { window.buttons[XCUIIdentifierCloseWindow].firstMatch.click() }
    }

    /// Paths under `project` whose last component starts with `prefix`, skipping `.tmp` unless asked.
    nonisolated static func paths(in project: URL, named prefix: String, includeStaging: Bool = false) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil) else { return [] }
        var found: [URL] = []
        for case let url as URL in walk {
            if url.lastPathComponent == ".tmp" && !includeStaging { walk.skipDescendants(); continue }
            if url.lastPathComponent.hasPrefix(prefix) { found.append(url) }
        }
        return found
    }

    /// Every path under `project`, relative and sorted.
    nonisolated static func listing(of project: URL) -> [String] {
        let root = project.standardizedFileURL.path
        let walk = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil)
        return (walk?.allObjects as? [URL] ?? []).map { String($0.standardizedFileURL.path.dropFirst(root.count)) }.sorted()
    }

    private static func run(_ executable: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ReleaseSmokeFixtures", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")) failed"])
        }
    }
}
