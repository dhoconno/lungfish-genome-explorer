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

    /// OBS-W6. The Inspector shows only the blocks of the result now on screen. A NAO-MGS result's block, titled
    /// "NAO-MGS Result", stayed at the top of the Inspector for the next Kraken2 and TaxTriage result, so the
    /// task opens the NAO-MGS result first and wants that block gone at every later step.
    @MainActor
    func testReleaseCandidateInspectorShowsOnlyTheCurrentResult() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try ReleaseSmokeFixtures.makeClassifierResultsProject(named: "ReleaseInspector-\(UUID().uuidString)")
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        try robot.launch()
        robot.openProject(project)
        let naoMgsBlock = "NAO-MGS Result"
        let steps = [("naomgs", naoMgsBlock), ("kraken2", "Classification Result"), ("taxtriage", "Comprehensive Triage Result")]
        var previous: String?
        for (folder, title) in steps {
            ReleaseSmokeFixtures.openSidebarItem(containing: folder, in: robot.app)
            if folder == "naomgs" { ReleaseSmokeFixtures.closeMissingDatabaseSheet(in: robot.app) }
            let block = robot.app.staticTexts[title].firstMatch
            if !block.waitForExistence(timeout: 10) {
                robot.app.buttons["main-window-toggle-inspector"].firstMatch.click()
            }
            XCTAssertTrue(block.waitForExistence(timeout: 10), "The Inspector shows \(title) for the \(folder) result")
            if let previous {
                XCTAssertTrue(robot.app.staticTexts[naoMgsBlock].firstMatch.waitForNonExistence(timeout: 5),
                              "The NAO-MGS block stays in the Inspector after the \(folder) result opened")
                if previous != naoMgsBlock {
                    XCTAssertTrue(robot.app.staticTexts[previous].firstMatch.waitForNonExistence(timeout: 5),
                                  "The Inspector still shows \(previous) after the \(folder) result opened")
                }
            }
            previous = title
        }
    }

    /// OBS-W4. Extract from a Kraken2 result renamed in the sidebar reads and writes the result's own folder, not the
    /// folder its sidecar names. Before the fix, Extract handed over the stored folder and the command refused it with
    /// "Classification result not found". The task waits for `extracted-*` in the renamed folder, which the command
    /// makes before it runs any tool, so the fresh home needs no seqkit, and a run that then stops on a missing tool
    /// still passes.
    @MainActor
    func testReleaseCandidateExtractFromARenamedResultUsesTheLoadedFolder() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try ReleaseSmokeFixtures.makeKraken2ResultProject(named: "ReleaseExtract-\(UUID().uuidString)")
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        let renamed = project.appendingPathComponent("Analyses/kraken2-renamed-smoke", isDirectory: true)
        try robot.launch()
        robot.openProject(project)
        ReleaseSmokeFixtures.renameSidebarItem(containing: ReleaseSmokeFixtures.kraken2Folder, to: renamed.lastPathComponent,
                                               in: robot.app)
        let moved = NSPredicate { _, _ in FileManager.default.fileExists(atPath: renamed.path) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 30), .completed,
                       "The sidebar renames the result's folder")
        ReleaseSmokeFixtures.openSidebarItem(containing: renamed.lastPathComponent, in: robot.app)
        let drawer = robot.app.buttons.matching(NSPredicate(format: "label == %@ OR title == %@",
                                                            "Toggle Taxa Collections Drawer", "Collections")).firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 15), "The Kraken2 result shows its Collections button")
        drawer.click()
        let extract = robot.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Extract ticked taxa in")).firstMatch
        XCTAssertTrue(extract.waitForExistence(timeout: 10), "The collections drawer offers Extract")
        extract.click()
        let landed = NSPredicate { _, _ in !ReleaseSmokeFixtures.paths(in: renamed, named: "extracted-").isEmpty }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landed, object: nil)], timeout: 30), .completed,
                       "Extract writes extracted-* inside the renamed result's own folder")
        let refusal = "Classification result not found"
        XCTAssertFalse(robot.app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                                                  refusal, refusal)).firstMatch.exists,
                       "Extract refuses the renamed result as not found")
        XCTAssertEqual(ReleaseSmokeFixtures.paths(in: project, named: ReleaseSmokeFixtures.kraken2Folder).count, 0,
                       "No folder of the old result name appears in the project")
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
    /// A project holding the Kraken2, EsViritu and TaxTriage results of `Tests/Fixtures/analyses` and a NAO-MGS result.
    static func makeClassifierResultsProject(named name: String) throws -> URL {
        let project = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: name)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let results = [("kraken2-2026-01-15T11-00-00", "kraken2"), ("esviritu-2026-01-15T10-00-00", "esviritu"),
                       ("taxtriage-2026-01-15T12-00-00", "taxtriage")]
        for (folder, tool) in results {
            let destination = analyses.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.copyItem(at: LungfishFixtureCatalog.analyses.appendingPathComponent(folder), to: destination)
            try writeAnalysisMetadata(tool: tool, in: destination)
        }
        try writeNaoMgsResult(in: analyses.appendingPathComponent("naomgs-2026-01-15T09-00-00", isDirectory: true))
        return project
    }

    /// A NAO-MGS result holding its `manifest.json` with one cached taxon row. The app shows the cached row and the
    /// result's Inspector block from the manifest alone, then says in a sheet that `hits.sqlite` is missing. The
    /// database needs the app's own NAO-MGS code or an NCBI Taxonomy install to build, and the runner has neither.
    static func writeNaoMgsResult(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let row: [String: Any] = ["sample": "S1", "taxId": 28875, "name": "Fixture virus alpha", "hitCount": 3,
                                  "uniqueReadCount": 3, "avgIdentity": 99.1, "avgBitScore": 226.0, "avgEditDistance": 1.0,
                                  "pcrDuplicateCount": 0, "accessionCount": 1, "topAccessions": ["KU048583.1"]]
        let manifest: [String: Any] = ["formatVersion": "1.0", "sampleName": "S1", "importDate": "2026-01-15T09:00:00Z",
                                       "sourceFilePath": "virus_hits_final.tsv.gz", "hitCount": 3, "taxonCount": 1,
                                       "topTaxon": "Fixture virus alpha", "topTaxonId": 28875,
                                       "fetchedAccessions": [String](), "cachedTaxonRows": [row]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("manifest.json"))
        try writeAnalysisMetadata(tool: "naomgs", in: folder)
    }

    /// Writes the `analysis-metadata.json` that files one result of `tool` under Analyses.
    static func writeAnalysisMetadata(tool: String, in folder: URL) throws {
        let metadata: [String: Any] = ["created": ISO8601DateFormatter().string(from: Date()), "isBatch": false, "tool": tool]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("analysis-metadata.json"))
    }

    /// Closes the sheet that says the NAO-MGS result has no `hits.sqlite`, so the sidebar takes clicks again.
    static func closeMissingDatabaseSheet(in app: XCUIApplication) {
        let ok = app.sheets.buttons["OK"].firstMatch
        if ok.waitForExistence(timeout: 10) { ok.click() }
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

    /// The folder of the Kraken2 result `makeKraken2ResultProject` writes, before the task renames it.
    static let kraken2Folder = "kraken2-2026-01-15T16-00-00"

    /// A project holding the Kraken2 result of `Tests/Fixtures/kraken2-mini/SRR35517702` with its reads, whose sidecar
    /// names the result's folder by absolute path, as a real run writes it.
    static func makeKraken2ResultProject(named name: String) throws -> URL {
        let project = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: name)
        let result = project.appendingPathComponent("Analyses/\(kraken2Folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: LungfishFixtureCatalog.kraken2Mini.appendingPathComponent("SRR35517702"), to: result)
        let sidecar = result.appendingPathComponent("classification-result.json")
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        var config = try XCTUnwrap(stored["config"] as? [String: Any])
        config["outputDirectory"] = result.absoluteString
        stored["config"] = config
        try JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted, .sortedKeys]).write(to: sidecar)
        try writeAnalysisMetadata(tool: "kraken2", in: result)
        return project
    }

    /// The first sidebar row whose words contain `text`, opening the Analyses group when needed.
    static func sidebarRow(containing text: String, in app: XCUIApplication) -> XCUIElement {
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
        return item
    }

    /// Clicks the first sidebar row whose words contain `text`.
    static func openSidebarItem(containing text: String, in app: XCUIApplication) {
        sidebarRow(containing: text, in: app).click()
    }

    /// Renames the first sidebar row whose words contain `text` to `name` through its Rename… menu item.
    static func renameSidebarItem(containing text: String, to name: String, in app: XCUIApplication) {
        let row = sidebarRow(containing: text, in: app)
        row.click()
        row.rightClick()
        let rename = app.menuItems["Rename\u{2026}"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "The sidebar row offers Rename\u{2026}")
        rename.click()
        let field = app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The Rename sheet shows the name")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        app.sheets.buttons["Rename"].firstMatch.click()
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
