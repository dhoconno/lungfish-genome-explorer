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

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openMappingDialog()
        robot.chooseMapper("minimap2")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "minimap2-", timeout: 30)
        robot.waitForResultViewport()

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
