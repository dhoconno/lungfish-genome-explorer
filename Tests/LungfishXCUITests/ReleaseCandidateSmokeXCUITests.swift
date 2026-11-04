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
        guard browser.treeNodeTable.waitForExistence(timeout: 15) else {
            robot.failShowingScreen("The tree bundle shows no phylogenetic-tree-node-table")
            return
        }
        browser.waitForPhylogeneticTreeViewer()
        XCTAssertTrue(browser.treeFitButton.waitForExistence(timeout: 10))
        let frame = robot.window(project).frame
        XCTAssertTrue(ReleaseSmokeScreen.fits(frame),
                      "The window \(frame) must stay inside a visible screen \(ReleaseSmokeScreen.visibleFrames())")
    }

    /// OBS-W6. The Inspector shows only the blocks of the result now on screen. A NAO-MGS result's block, titled
    /// "NAO-MGS Result", stayed at the top of the Inspector for the next Kraken2 and TaxTriage result, so the
    /// task opens the NAO-MGS result first and wants that block gone at every later step. "Classification Result"
    /// and "Comprehensive Triage Result" are the sidebar's type names (`InspectorView.swift:810-812`), not
    /// Inspector blocks, so each later step waits for its own viewer and the Inspector's Summary instead.
    @MainActor
    func testReleaseCandidateInspectorShowsOnlyTheCurrentResult() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try ReleaseSmokeFixtures.makeClassifierResultsProject(named: "ReleaseInspector-\(UUID().uuidString)")
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        try robot.launch()
        robot.openProject(project)
        let naoMgsBlock = robot.app.staticTexts["NAO-MGS Result"].firstMatch
        ReleaseSmokeFixtures.openSidebarItem(containing: "naomgs", in: robot.app)
        ReleaseSmokeFixtures.closeMissingDatabaseSheet(in: robot)
        XCTAssertTrue(ReleaseSmokeFixtures.showInspectorSummary(robot), "The Inspector shows a Summary for the NAO-MGS result")
        guard naoMgsBlock.waitForExistence(timeout: 10) else {
            robot.failShowingScreen("The Inspector shows no NAO-MGS Result block for the NAO-MGS result")
            return
        }
        let later = [("kraken2", ReleaseSmokeFixtures.kraken2Viewer(in: robot.app)),
                     ("taxtriage", robot.app.descendants(matching: .any)["taxtriage-result-view"].firstMatch)]
        for (folder, viewer) in later {
            ReleaseSmokeFixtures.openSidebarItem(containing: folder, in: robot.app)
            guard viewer.waitForExistence(timeout: 15) else {
                robot.failShowingScreen("The \(folder) result shows no viewer")
                return
            }
            XCTAssertTrue(ReleaseSmokeFixtures.showInspectorSummary(robot), "The Inspector shows a Summary for the \(folder) result")
            XCTAssertTrue(naoMgsBlock.waitForNonExistence(timeout: 5),
                          "The NAO-MGS block stays in the Inspector after the \(folder) result opened")
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
        let project = try ReleaseAppSmokeRobot.newProjectURL(named: "ReleaseExtract")
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        let renamed = project.appendingPathComponent("Analyses/kraken2-renamed-smoke", isDirectory: true)
        try robot.launch()
        try robot.openWritableProject(project) { try ReleaseSmokeFixtures.addKraken2Result(to: $0) }
        ReleaseSmokeFixtures.renameSidebarItem(containing: ReleaseSmokeFixtures.kraken2Folder, to: renamed.lastPathComponent,
                                               in: robot)
        let moved = NSPredicate { _, _ in FileManager.default.fileExists(atPath: renamed.path) }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 30) == .completed else {
            robot.failShowingScreen("The sidebar did not rename the result's folder to \(renamed.lastPathComponent) within 30 s")
            return
        }
        ReleaseSmokeFixtures.openSidebarItem(containing: renamed.lastPathComponent, in: robot.app)
        let drawer = ReleaseSmokeFixtures.kraken2CollectionsToggle(in: robot.app)
        XCTAssertTrue(drawer.waitForExistence(timeout: 15), "The Kraken2 result shows its Collections toggle")
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
        let project = try ReleaseAppSmokeRobot.newProjectURL(named: "ReleaseZip")
        let archive = try ReleaseSmokeFixtures.makeBundleArchive(named: "DroppedGenome")
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
        }
        try robot.launch()
        try robot.openWritableProject(project) { try ReleaseSmokeFixtures.addBundleBrowserContents(to: $0) }
        ReleaseSmokeFixtures.dragFromFinder(archive, onto: robot.window(project).outlines["sidebar-outline"], robot: robot)
        let landed = NSPredicate { _, _ in !ReleaseSmokeFixtures.paths(in: project, named: "DroppedGenome.lungfishref").isEmpty }
        guard XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landed, object: nil)], timeout: 30) == .completed else {
            robot.failShowingScreen("The dropped bundle did not land in the project outside .tmp within 30 s")
            return
        }
        XCTAssertEqual(ReleaseSmokeFixtures.paths(in: project, named: "sidebar-zip-import", includeStaging: true).count, 0,
                       "No staging folder is left behind")
    }

    /// OBS-W9. A ZIP holding a link out of the archive is refused with words that name it, and changes nothing.
    @MainActor
    func testReleaseCandidateRefusedZipShowsWords() throws {
        let robot = try ReleaseAppSmokeRobot()
        let project = try ReleaseAppSmokeRobot.newProjectURL(named: "ReleaseRefusedZip")
        let archive = try ReleaseSmokeFixtures.makeEscapingLinkArchive()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
        }
        try robot.launch()
        try robot.openWritableProject(project) { try ReleaseSmokeFixtures.addBundleBrowserContents(to: $0) }
        let before = ReleaseSmokeFixtures.listing(of: project)
        ReleaseSmokeFixtures.dragFromFinder(archive, onto: robot.window(project).outlines["sidebar-outline"], robot: robot)
        // An alert's words are its static texts' values, so the label and the value are both read.
        let named = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", archive.lastPathComponent, archive.lastPathComponent)
        let words = robot.app.staticTexts.matching(named).firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 15), "The refusal names \(archive.lastPathComponent)")
        let link = "link to a file outside the archive"
        let reason = robot.app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", link, link)).firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 5), "The refusal says the ZIP holds a link to a file outside the archive")
        robot.clickAlertButton("OK")
        XCTAssertEqual(ReleaseSmokeFixtures.listing(of: project), before, "A refused archive changes nothing in the project")
    }

    /// Exit check 3 of Phases 3.1 and 3.2. One bundle of each kind the smoke can build opens in turn on the candidate,
    /// and the viewer and the Inspector change with the kind: each kind's viewer shows and the one before it goes, and
    /// the NAO-MGS Inspector block shows for the NAO-MGS result only. The kinds come from `ViewSwitchKinds.all`
    /// (Tests/LungfishAppTests/SafetyNets). A kind joins the list when its fixture needs no managed tool and its viewer
    /// carries an accessibility identifier, and a preview kind also shows its status words. Assembly, Genotype, FASTQ,
    /// MHC reference and the text, PDF and image previews of Quick Look joined in 3.2, each with a fixture the test
    /// writes or copies from `Tests/Fixtures/analyses`, which the smoke gate stages. Left out: NVD, CZ ID, 12S, both
    /// primer kinds and FASTA document, which have no fixture the smoke can open without managed tools, as 3.1 found.
    /// Status only draws no viewer to wait for.
    @MainActor
    func testReleaseCandidateViewSwitchPerKind() throws {
        let robot = try ReleaseAppSmokeRobot()
        let cli = robot.candidateURL.appendingPathComponent("Contents/MacOS/lungfish-cli")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path), "The candidate embeds lungfish-cli")
        setenv("LUNGFISH_TEST_CLI", cli.path, 1)
        let project = try ReleaseSmokeFixtures.makeViewSwitchProject(named: "ReleaseViewSwitch-\(UUID().uuidString)")
        defer { robot.app.terminate(); try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        try robot.launch()
        robot.openProject(project)
        let any = robot.app.descendants(matching: .any)
        let naoMgsBlock = robot.app.staticTexts["NAO-MGS Result"].firstMatch
        let kinds: [(name: String, row: String, viewer: XCUIElement)] = [
            ("Reference", "TestGenome", any["reference-bundle-view"].firstMatch),
            ("Kraken2", "kraken2", ReleaseSmokeFixtures.kraken2Viewer(in: robot.app)),
            ("EsViritu", "esviritu", any["esviritu-result-view"].firstMatch),
            ("TaxTriage", "taxtriage", any["taxtriage-result-view"].firstMatch),
            ("NAO-MGS", "naomgs", naoMgsBlock),
            ("MSA", "MHC Alignment", any["multiple-sequence-alignment-row-gutter"].firstMatch),
            ("Tree", "MHC Tree", any["phylogenetic-tree-node-table"].firstMatch),
            ("Assembly", ReleaseSmokeFixtures.assemblyRow, any["assembly-result-view"].firstMatch),
            ("Genotype", ReleaseSmokeFixtures.genotypeRow, any["genotype-result-view"].firstMatch),
            ("Quick Look", ReleaseSmokeFixtures.previewFile, any["viewer-plain-text-preview"].firstMatch),
            ("FASTQ", ReleaseSmokeFixtures.fastqRow, any["fastq-dataset-view"].firstMatch),
            ("MHC reference", ReleaseSmokeFixtures.mhcRow, any["mhc-reference-bundle-view"].firstMatch),
            ("PDF", ReleaseSmokeFixtures.pdfFile, any["viewer-pdf-preview"].firstMatch),
            ("Image preview", ReleaseSmokeFixtures.imageFile, any["viewer-quick-look-preview"].firstMatch),
        ]
        // A preview's status words come from the status bar under it, as the matrix rows "Nextflow script previews as
        // text", "PDF figure" and "PNG image" say them (RoutingSafetyNetTable+ContainerAndFileRows).
        let statusWords = ["Quick Look": "Previewing: \(ReleaseSmokeFixtures.previewFile)",
                           "PDF": "\(ReleaseSmokeFixtures.pdfFile) (1 page)",
                           "Image preview": "Previewing: \(ReleaseSmokeFixtures.imageFile)"]
        var previous: (name: String, row: String, viewer: XCUIElement)?
        for kind in kinds + [kinds[0]] {
            ReleaseSmokeFixtures.openSidebarItem(containing: kind.row, in: robot.app)
            if kind.name == "NAO-MGS" {
                ReleaseSmokeFixtures.closeMissingDatabaseSheet(in: robot)
                XCTAssertTrue(ReleaseSmokeFixtures.showInspectorSummary(robot), "The Inspector shows the NAO-MGS Summary")
            }
            guard kind.viewer.waitForExistence(timeout: 15) else {
                robot.failShowingScreen("The \(kind.name) bundle shows no viewer after \(previous?.name ?? "the project") ")
                return
            }
            if let words = statusWords[kind.name] {
                let said = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words)
                XCTAssertTrue(robot.app.staticTexts.matching(said).firstMatch.waitForExistence(timeout: 5),
                              "The status bar says \"\(words)\" for the \(kind.name) bundle")
            }
            // The NAO-MGS block stands in for a viewer and has its own check below. Kraken2's query takes its root
            // or its Collections toggle, and either goes with the viewer.
            if let previous, previous.name != "NAO-MGS" {
                XCTAssertTrue(previous.viewer.waitForNonExistence(timeout: 5),
                              "The \(previous.name) viewer stays after the \(kind.name) bundle opened")
            }
            if kind.name != "NAO-MGS" {
                XCTAssertTrue(naoMgsBlock.waitForNonExistence(timeout: 5),
                              "The NAO-MGS Inspector block shows for the \(kind.name) bundle")
            }
            previous = kind
        }
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
        try writeTaxTriageOrganismReport(in: analyses.appendingPathComponent("taxtriage-2026-01-15T12-00-00", isDirectory: true))
        try writeNaoMgsResult(in: analyses.appendingPathComponent("naomgs-2026-01-15T09-00-00", isDirectory: true))
        return project
    }

    /// The `report/testSample.odr.txt` that `build-db taxtriage` reads. The shared TaxTriage fixture holds only
    /// `sample_report.tsv`, which the command does not read, so the app's build on open stopped with exit 64, "No
    /// supported TaxTriage taxonomy report found", and the result showed "Build failed" with no viewer. The rows
    /// match the fixture's `sample_report.tsv`.
    static func writeTaxTriageOrganismReport(in result: URL) throws {
        let report = result.appendingPathComponent("report", isDirectory: true)
        try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
        let rows = ["Detected Organism\tSpecimen ID\t% Reads\t# Reads Aligned\tTaxonomic ID #\tBreadth %\tTASS Score\tPasses Threshold\tTASS Threshold",
                    "SARS-CoV-2\ttestSample\t83.3\t500\t2697049\t95.0\t95\tTRUE\t75.0",
                    "Influenza A\ttestSample\t16.7\t100\t11320\t80.0\t80\tTRUE\t75.0"]
        try (rows.joined(separator: "\n") + "\n").write(to: report.appendingPathComponent("testSample.odr.txt"),
                                                       atomically: true, encoding: .utf8)
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
    static func closeMissingDatabaseSheet(in robot: ReleaseAppSmokeRobot) {
        let ok = robot.app.sheets.buttons["OK"].firstMatch
        if ok.waitForExistence(timeout: 10) { robot.clickAlertButton("OK") }
    }

    /// The accessibility label of the Kraken2 viewer's Collections toggle (`TaxonomyViewController`).
    static let kraken2CollectionsLabel = "Toggle Taxa Collections Drawer"

    /// The Kraken2 viewer, by its root's `kraken2-result-view` (`Kraken2Surface.viewIdentifier`, lane K2) or its
    /// Collections toggle. AppKit leaves a root that is a plain NSView out of the accessibility tree, identifier or
    /// not, so the toggle answers until the root is an element.
    static func kraken2Viewer(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                             "kraken2-result-view", kraken2CollectionsLabel)).firstMatch
    }

    /// The Kraken2 viewer's Collections toggle. GUI run 1 found it as a CheckBox (title Collections), since the
    /// button is `.pushOnPushOff`, where the robot asked for a button.
    static func kraken2CollectionsToggle(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", kraken2CollectionsLabel)).firstMatch
    }

    /// Shows the Inspector's Summary (the `resultSummary` tab, `InspectorView.swift`) and says whether it shows.
    /// The Inspector toggle is pressed only when no Summary shows, so a visible Inspector is never hidden. One tab
    /// shows as a header and several as buttons, so the label is looked for on any element.
    static func showInspectorSummary(_ robot: ReleaseAppSmokeRobot) -> Bool {
        let summary = robot.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Summary")).firstMatch
        if !summary.waitForExistence(timeout: 5) {
            robot.app.buttons["main-window-toggle-inspector"].firstMatch.click()
        }
        guard summary.waitForExistence(timeout: 10) else { return false }
        if summary.elementType == .button, summary.isHittable { summary.click() }
        return true
    }

    /// The classifier results project plus the multiple sequence alignment and tree bundles the candidate's own
    /// `lungfish-cli` builds (`LUNGFISH_TEST_CLI`), plus the Assembly, Genotype and Quick Look text fixtures written
    /// below, for the view switch of exit check 3.
    static func makeViewSwitchProject(named name: String) throws -> URL {
        let project = try makeClassifierResultsProject(named: name)
        let trees = try LungfishProjectFixtureBuilder.makeAlignmentTreeBundleProject(named: "ViewSwitchBundles")
        defer { try? FileManager.default.removeItem(at: trees.deletingLastPathComponent()) }
        for bundle in ["MHC Alignment.lungfishmsa", "MHC Tree.lungfishtree"] {
            try FileManager.default.copyItem(at: trees.appendingPathComponent(bundle, isDirectory: true),
                                             to: project.appendingPathComponent(bundle, isDirectory: true))
        }
        try addAssemblyResult(to: project)
        try addGenotypeResult(to: project)
        try addScriptPreview(to: project)
        try addFASTQBundle(to: project)
        try addMHCReferenceBundle(to: project)
        try addPDFPreview(to: project)
        try addImagePreview(to: project)
        return project
    }

    /// The PDF the PDF preview shows, a figure of one page as the matrix row "PDF figure" writes it. PDFKit draws it in
    /// the app, and the status bar says `figure.pdf (1 page)`.
    static let pdfFile = "figure.pdf"

    static func addPDFPreview(to project: URL) throws {
        let url = project.appendingPathComponent(pdfFile)
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "ReleaseSmokeFixtures", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No PDF context for \(url.path)"])
        }
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 40, y: 40, width: 120, height: 120))
        context.endPDFPage()
        context.closePDF()
    }

    /// The image the image preview shows, a 2 by 2 pixel PNG as the matrix row "PNG image" writes it. Quick Look draws it
    /// in the app, and the status bar says `Previewing: coverage.png`.
    static let imageFile = "coverage.png"

    static func addImagePreview(to project: URL) throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ReleaseSmokeFixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: "No PNG for \(imageFile)"])
        }
        try png.write(to: project.appendingPathComponent(imageFile))
    }

    /// The name an MHC amplicon reference bundle shares as its folder and its manifest name, so the sidebar row reads it.
    static let mhcRow = "Smoke MHC Reference"

    /// An MHC amplicon reference bundle of two reference records and no haplotype definition. The unit matrix row "MHC
    /// amplicon reference bundle" copies the manual fixture under `docs/user-manual/fixtures`, which the smoke gate does not
    /// copy for the runner (`SMOKE_FIXTURES` in `app_smoke_gate.py`), so the files are written here. The manifest is JSON with
    /// the keys `MHCAmpliconReferenceBundleManifest` requires, in `mhc-reference.json`.
    static func addMHCReferenceBundle(to project: URL) throws {
        let bundle = project.appendingPathComponent("\(mhcRow).lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try ">Mamu-A1-001 smoke\nACGTACGTACGTACGTACGT\n>Mamu-A1-002 smoke\nACGTACGTACGAACGTACGT\n"
            .write(to: bundle.appendingPathComponent("reference.fa"), atomically: true, encoding: .utf8)
        let manifest: [String: Any] = ["schemaVersion": 1, "kind": "mhc-reference", "name": mhcRow,
                                       "referenceFastaPath": "reference.fa", "haplotypeDefinitionPaths": [String](),
                                       "metrics": ["referenceCount": 2, "haplotypeDefinitionCount": 0],
                                       "createdAt": "2026-11-04T00:00:00Z"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: bundle.appendingPathComponent("mhc-reference.json"))
    }

    /// The sidebar words of the FASTQ bundle, which its folder name carries.
    static let fastqRow = "Smoke FASTQ"

    /// A FASTQ bundle with cached statistics, so the dashboard opens with no seqkit (the unit matrix row "FASTQ bundle with
    /// cached statistics"). The reads are two records of 8 bases at quality 40. The sidecar `reads.fastq.lungfish-meta.json`
    /// (`FASTQMetadataStore.metadataURL`) holds their `FASTQDatasetStatistics` as the encoder writes them, with 12 of 16
    /// bases G or C. The length histogram has Int keys, so it is an object, and the quality histogram has UInt8 keys, so it
    /// is a list of key and count. The per-position quality list is empty, which the charts draw as no boxes.
    static func addFASTQBundle(to project: URL) throws {
        let bundle = project.appendingPathComponent("\(fastqRow).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "@read1\nACGTACGT\n+\nIIIIIIII\n@read2\nGGCCGGCC\n+\nIIIIIIII\n"
            .write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        let statistics: [String: Any] = ["readCount": 2, "baseCount": 16, "meanReadLength": 8.0, "minReadLength": 8,
                                         "maxReadLength": 8, "medianReadLength": 8, "n50ReadLength": 8, "meanQuality": 40.0,
                                         "q20Percentage": 100.0, "q30Percentage": 100.0, "gcContent": 0.75,
                                         "readLengthHistogram": ["8": 2], "qualityScoreHistogram": [40, 16],
                                         "perPositionQuality": [Any]()]
        try JSONSerialization.data(withJSONObject: ["computedStatistics": statistics], options: [.prettyPrinted, .sortedKeys])
            .write(to: bundle.appendingPathComponent("reads.fastq.lungfish-meta.json"))
    }

    /// The sidebar words of the SPAdes result of `Tests/Fixtures/analyses`, whose folder starts `spades-`.
    static let assemblyRow = "spades"

    /// Copies the SPAdes result into Analyses as `makeAnalysesProject` does. Its sidecar names `contigs.fasta` by a path
    /// inside the folder, and the viewer reads the contigs itself, so the copy opens with no managed tool.
    static func addAssemblyResult(to project: URL) throws {
        let folder = "spades-2026-01-15T13-00-00"
        let destination = project.appendingPathComponent("Analyses/\(folder)", isDirectory: true)
        try FileManager.default.copyItem(at: LungfishFixtureCatalog.analyses.appendingPathComponent(folder), to: destination)
        try writeAnalysisMetadata(tool: "spades", in: destination)
    }

    /// The name a genotype result shares as its folder, its output name and its analysis name, so the sidebar row reads it.
    static let genotypeRow = "Smoke Genotype"

    /// A genotype result with one call, as `RoutingSafetyNetFixtures.genotypeResultBundle(withCalls: true)` writes it, with
    /// its manifest as JSON (`ONTGenotypeResultBundleManifest`, `genotype-result.json`). The native matrix reads the two CSV
    /// files and the stats, and the workbook is only named.
    static func addGenotypeResult(to project: URL) throws {
        let name = genotypeRow
        let bundle = project.appendingPathComponent("\(name).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("workbook".utf8).write(to: bundle.appendingPathComponent("\(name).xlsx"))
        let files = ["\(name).retained-demux-genotypes.csv": "sample,genotype,passed_alignments,passed_unique_reads\nDW472,01_Mafa_A1_063g,10,8\n",
                     "\(name).retained-demux-samples.csv": "sample,passed_alignments,passed_unique_reads\nDW472,10,8\n",
                     "\(name).retained-demux-stats.json": #"{"totalInputReads":10,"retainedUniqueReads":8}"#,
                     "retained-demux-genotyping-provenance.json": #"{"workflow":"safety-net"}"#]
        for (file, text) in files {
            try text.write(to: bundle.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "kind": "ont-barcode-genotype", "outputName": name, "analysisName": name,
                                       "primaryWorkbookPath": "\(name).xlsx",
                                       "longSummaryCSVPath": "\(name).retained-demux-genotypes.csv",
                                       "sampleSummaryCSVPath": "\(name).retained-demux-samples.csv",
                                       "statsJSONPath": "\(name).retained-demux-stats.json",
                                       "provenancePath": "retained-demux-genotyping-provenance.json"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: bundle.appendingPathComponent("genotype-result.json"))
    }

    /// The Nextflow script the Quick Look kind previews. macOS has no preview for it, so the viewer draws it as text
    /// itself, which is the matrix row "Nextflow script previews as text".
    static let previewFile = "main.nf"

    /// Writes the script at the project root, where the sidebar lists it as a file.
    static func addScriptPreview(to project: URL) throws {
        try "nextflow.enable.dsl = 2\n\nworkflow {\n    println 'HG002'\n}\n"
            .write(to: project.appendingPathComponent(previewFile), atomically: true, encoding: .utf8)
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

    /// Copies the files of the bundle browser fixture project (its reference bundle) into `project`, all but the
    /// fixture's own `metadata.json`, so a project the app made shows rows in its sidebar.
    static func addBundleBrowserContents(to project: URL) throws {
        let fixture = try LungfishProjectFixtureBuilder.makeBundleBrowserProject(named: "WritableSource")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        try merge(fixture, into: project, skipping: ["metadata.json"])
    }

    /// Copies each item of `source` into `destination`, merging into a folder the app already made there.
    nonisolated static func merge(_ source: URL, into destination: URL, skipping: Set<String> = []) throws {
        for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        where !skipping.contains(item.lastPathComponent) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder), isFolder.boolValue {
                try merge(item, into: target)
            } else {
                try FileManager.default.copyItem(at: item, to: target)
            }
        }
    }

    /// Adds the Kraken2 result of `Tests/Fixtures/kraken2-mini/SRR35517702` with its reads to `project`, its sidecar
    /// naming the result's folder by absolute path, as a real run writes it.
    static func addKraken2Result(to project: URL) throws {
        try addBundleBrowserContents(to: project)
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
    /// The context menu's item comes first, since an unscoped `menuItems` query may take a menu bar item of the
    /// same title, and the sheet's field is found by `sidebar-rename-field` (`SidebarViewController+MenuDelegate`).
    static func renameSidebarItem(containing text: String, to name: String, in robot: ReleaseAppSmokeRobot) {
        let app = robot.app
        let row = sidebarRow(containing: text, in: app)
        row.click()
        row.rightClick()
        let title = "Rename\u{2026}"
        guard let rename = robot.firstOf([app.outlines["sidebar-outline"].menuItems[title].firstMatch,
                                          app.menus.menuItems[title].firstMatch], timeout: 5, hittable: true) else {
            robot.failShowingScreen("The sidebar row's menu offers no \(title)")
            return
        }
        rename.click()
        guard let field = robot.firstOf([app.descendants(matching: .any)["sidebar-rename-field"].firstMatch,
                                         app.sheets.textFields.firstMatch, app.dialogs.textFields.firstMatch],
                                        timeout: 10) else {
            robot.failShowingScreen("The Rename sheet shows no name field")
            return
        }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        robot.clickAlertButton("Rename")
    }

    /// Shows `file` in a Finder window and drags it onto a point of `target` that no Finder window covers, then
    /// closes that window. GUI run 1 dragged onto the element, and XCUI fell back to a point outside the sidebar
    /// ({1749, 722} for an outline at {{327, 162}, {242, 422}}) or refused it as not hittable, so the drop point is
    /// worked out here from the frames and the drag runs between coordinates.
    static func dragFromFinder(_ file: URL, onto target: XCUIElement, robot: ReleaseAppSmokeRobot) {
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        NSWorkspace.shared.activateFileViewerSelecting([file])
        let names = [file.lastPathComponent, file.deletingPathExtension().lastPathComponent]
        let item = finder.windows.firstMatch.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@ OR value IN %@", names, names)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "Finder shows \(file.lastPathComponent)")
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        let covers = finder.windows.allElementsBoundByIndex.map(\.frame)
        guard let offset = uncoveredOffset(in: target.frame, avoiding: covers) else {
            robot.failShowingScreen("Finder windows \(covers) cover every point of the drop target \(target.frame)")
            return
        }
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1.0, thenDragTo: target.coordinate(withNormalizedOffset: offset),
                   withVelocity: .default, thenHoldForDuration: 0.5)
        let window = finder.windows.firstMatch
        if window.exists { window.buttons[XCUIIdentifierCloseWindow].firstMatch.click() }
    }

    /// The first normalized offset in `frame`, centre first, whose point lies outside every frame of `covers`.
    nonisolated static func uncoveredOffset(in frame: CGRect, avoiding covers: [CGRect]) -> CGVector? {
        let steps: [CGFloat] = [0.5, 0.3, 0.7, 0.15, 0.85, 0.05, 0.95]
        for dy in steps {
            for dx in steps {
                let point = CGPoint(x: frame.minX + dx * frame.width, y: frame.minY + dy * frame.height)
                if !covers.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) { return CGVector(dx: dx, dy: dy) }
            }
        }
        return nil
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
