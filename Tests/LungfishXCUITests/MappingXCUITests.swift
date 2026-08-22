import XCTest

final class MappingXCUITests: XCTestCase {
    @MainActor
    func testMinimap2DeterministicRunShowsResultViewport() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaMappingProject(
            named: "Minimap2DeterministicMappingFixture"
        )
        let robot = MappingRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openMappingDialog()
        robot.chooseMapper("minimap2")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "minimap2-", timeout: 30)
        XCTAssertTrue(robot.resultView.waitForExistence(timeout: 10))
        XCTAssertTrue(robot.resultTable.waitForExistence(timeout: 10))
    }

    @MainActor
    func testBwaMem2DeterministicRunShowsResultViewport() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaMappingProject(
            named: "BwaMem2DeterministicMappingFixture"
        )
        let robot = MappingRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openMappingDialog()
        robot.chooseMapper("BWA-MEM2")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "bwa-mem2-", timeout: 30)
        XCTAssertTrue(robot.resultView.waitForExistence(timeout: 10))
        XCTAssertTrue(robot.resultTable.waitForExistence(timeout: 10))
    }

    @MainActor
    func testBowtie2DeterministicRunShowsResultViewport() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaMappingProject(
            named: "Bowtie2DeterministicMappingFixture"
        )
        let robot = MappingRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openMappingDialog()
        robot.chooseMapper("Bowtie2")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "bowtie2-", timeout: 30)
        XCTAssertTrue(robot.resultView.waitForExistence(timeout: 10))
        XCTAssertTrue(robot.resultTable.waitForExistence(timeout: 10))
    }

    @MainActor
    func testBBMapDeterministicRunShowsResultViewport() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaMappingProject(
            named: "BBMapDeterministicMappingFixture"
        )
        let robot = MappingRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openMappingDialog()
        robot.chooseMapper("BBMap")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "bbmap-", timeout: 30)
        XCTAssertTrue(robot.resultView.waitForExistence(timeout: 10))
        XCTAssertTrue(robot.resultTable.waitForExistence(timeout: 10))
    }

    @MainActor
    func testDeterministicMappingViewportAcceptsZoomShortcuts() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaMappingProject(
            named: "MappingShortcutFixture"
        )
        let robot = MappingRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openMappingDialog()
        robot.chooseMapper("minimap2")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "minimap2-", timeout: 30)
        robot.waitForResultViewport()
        robot.pressResultZoomShortcut(.zoomIn)
        robot.pressResultZoomShortcut(.zoomOut)
        robot.pressResultZoomShortcut(.zoomToFit)

        robot.waitForResultViewport()
    }

    @MainActor
    func testDeterministicMappingViewportDoesNotShowNestedBundleBrowser() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaMappingProject(
            named: "MappingBundleModeFixture"
        )
        let robot = MappingRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openMappingDialog()
        robot.chooseMapper("minimap2")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "minimap2-", timeout: 30)
        robot.waitForResultViewport()
        XCTAssertFalse(robot.referenceBundleSequenceTable.waitForExistence(timeout: 1))
    }

    @MainActor
    func testMappingInspectorSourceDataLinksNavigateToSidebarItems() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeMappingInspectorNavigationProject(
            named: "MappingInspectorNavigationFixture"
        )
        let robot = MappingRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        // Deliberately select only test_1.fastq.gz (no extendingSelection).
        // makeMappingInspectorNavigationProject copies the raw sarscov2 FASTQ
        // fixtures straight into the project root as two loose files rather
        // than one pre-paired .lungfishfastq bundle. Per
        // MappingWizardSheet.bundleCount's doc comment, the sidebar
        // selection -> resolveFASTQOperationInputURL pipeline treats each
        // selected item as its own bundle and deliberately never
        // pattern-matches _R1/_R2/_1/_2 across separate bundles to re-pair
        // them, so selecting both loose files here would produce a 2-bundle
        // "per-bundle" batch plan (sidebar row "minimap2-batch-...") instead
        // of the single mapping document with Source Reference
        // Bundle/Reference FASTA inspector links this test exercises.
        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "test_1.fastq.gz")
        robot.openMappingDialog()
        robot.chooseMapper("minimap2")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "minimap2-", timeout: 30)
        robot.waitForResultViewport()

        // Selecting one loose file for a mapping run auto-ingests it into a
        // .lungfishfastq bundle before the run (resolveFASTQOperationInputURL,
        // see the comment above), so the mapping provenance's recorded
        // inputFASTQPaths -- and therefore the inspector's "Run Inputs"
        // source-data link label, which is just that path's
        // lastPathComponent (MappingDocumentStateBuilder) -- points at that
        // bundle: "test_1.lungfishfastq".
        robot.clickInspectorSourceLink("test_1.lungfishfastq")
        robot.waitForSelectedSidebarItem(containing: "test_1")

        robot.selectSidebarItem(prefix: "minimap2-")
        robot.clickInspectorSourceLink("Source Reference Bundle")
        robot.waitForSelectedSidebarItem(containing: "TestGenome")

        robot.selectSidebarItem(prefix: "minimap2-")
        robot.clickInspectorSourceLink("Reference FASTA")
        robot.waitForSelectedSidebarItem(containing: "TestGenome")
    }
}
