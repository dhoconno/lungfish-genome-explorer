import XCTest

final class AssemblyXCUITests: XCTestCase {
    @MainActor
    func testIlluminaAssemblyDialogExposesAssemblerSpecificControls() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaAssemblyProject(named: "IlluminaAssemblyFixture")
        let robot = AssemblyRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openAssemblyDialog()

        robot.chooseAssembler("SPAdes")
        robot.expandAdvancedOptionsIfNeeded()
        XCTAssertTrue(robot.profilePicker.waitForExistence(timeout: 5))
        XCTAssertTrue(robot.memorySlider.exists)
        robot.reveal(robot.spadesCarefulToggle)

        robot.chooseAssembler("MEGAHIT")
        XCTAssertTrue(robot.profilePicker.waitForExistence(timeout: 5))
        XCTAssertTrue(robot.memorySlider.exists)
        XCTAssertFalse(robot.spadesCarefulToggle.exists)

        robot.chooseAssembler("SKESA")
        XCTAssertFalse(robot.profilePicker.exists)
        XCTAssertTrue(robot.memorySlider.exists)

        robot.chooseAssembler("Flye")
        XCTAssertTrue(robot.profilePicker.waitForExistence(timeout: 5))
        XCTAssertFalse(robot.memorySlider.exists)
        XCTAssertFalse(robot.minContigStepper.exists)
    }

    @MainActor
    func testOntAndHiFiDialogsExposeLongReadSpecificControls() throws {
        let ontProjectURL = try LungfishProjectFixtureBuilder.makeOntAssemblyProject(named: "OntAssemblyFixture")
        let hifiProjectURL = try LungfishProjectFixtureBuilder.makePacBioHiFiAssemblyProject(named: "HiFiAssemblyFixture")
        let robot = AssemblyRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: ontProjectURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: hifiProjectURL.deletingLastPathComponent())
        }

        robot.launch(opening: ontProjectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "reads.fastq")
        robot.openAssemblyDialog()
        robot.chooseAssembler("Flye")
        robot.expandAdvancedOptionsIfNeeded()
        XCTAssertTrue(robot.profilePicker.waitForExistence(timeout: 5))
        XCTAssertFalse(robot.memorySlider.exists)
        XCTAssertFalse(robot.minContigStepper.exists)
        robot.reveal(robot.flyeMetagenomeToggle)
        robot.app.terminate()

        robot.launch(opening: hifiProjectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "reads.fastq")
        robot.openAssemblyDialog()
        robot.chooseAssembler("Hifiasm")
        robot.expandAdvancedOptionsIfNeeded()
        XCTAssertFalse(robot.profilePicker.exists)
        XCTAssertFalse(robot.memorySlider.exists)
        XCTAssertFalse(robot.minContigStepper.exists)
        robot.reveal(robot.hifiasmPrimaryOnlyToggle)
    }

    @MainActor
    func testMegahitLiveSmokeAddsAnalysisToSidebarAndShowsResultViewport() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaAssemblyProject(named: "MegahitLiveAssemblyFixture")
        let robot = AssemblyRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "live-smoke")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openAssemblyDialog()
        robot.chooseAssembler("MEGAHIT")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "megahit-", timeout: 120)
        XCTAssertTrue(robot.resultView.waitForExistence(timeout: 30))
        XCTAssertTrue(robot.resultTable.waitForExistence(timeout: 30))
    }

    @MainActor
    func testMegahitDeterministicRunAddsAnalysisToSidebarAndShowsResultViewport() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaAssemblyProject(named: "MegahitDeterministicAssemblyFixture")
        let robot = AssemblyRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openAssemblyDialog()
        robot.chooseAssembler("MEGAHIT")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "megahit-", timeout: 30)
        XCTAssertTrue(robot.resultView.waitForExistence(timeout: 10))
        XCTAssertTrue(robot.resultTable.waitForExistence(timeout: 10))
    }

    @MainActor
    func testSkesaLiveSmokeAddsAnalysisToSidebarAndShowsResultViewport() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaAssemblyProject(named: "SkesaLiveAssemblyFixture")
        let robot = AssemblyRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "live-smoke")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openAssemblyDialog()
        robot.chooseAssembler("SKESA")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "skesa-", timeout: 120)
        XCTAssertTrue(robot.resultView.waitForExistence(timeout: 30))
        XCTAssertTrue(robot.resultTable.waitForExistence(timeout: 30))
    }

    @MainActor
    func testSpadesDeterministicRunShowsResultViewport() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaAssemblyProject(named: "SpadesDeterministicAssemblyFixture")
        let robot = AssemblyRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openAssemblyDialog()
        robot.chooseAssembler("SPAdes")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "spades-", timeout: 30)
        XCTAssertTrue(robot.resultView.waitForExistence(timeout: 10))
        XCTAssertTrue(robot.resultTable.waitForExistence(timeout: 10))
    }

    @MainActor
    func testSkesaDeterministicRunShowsResultViewport() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeIlluminaAssemblyProject(named: "SkesaDeterministicAssemblyFixture")
        let robot = AssemblyRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "test_1.fastq.gz", extendingSelection: true)
        robot.openAssemblyDialog()
        robot.chooseAssembler("SKESA")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "skesa-", timeout: 30)
        XCTAssertTrue(robot.resultView.waitForExistence(timeout: 10))
        XCTAssertTrue(robot.resultTable.waitForExistence(timeout: 10))
    }

    @MainActor
    func testFlyeDeterministicRunShowsResultViewport() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeOntAssemblyProject(named: "FlyeDeterministicAssemblyFixture")
        let robot = AssemblyRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "reads.fastq")
        robot.openAssemblyDialog()
        robot.chooseAssembler("Flye")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "flye-", timeout: 30)
        XCTAssertTrue(robot.resultView.waitForExistence(timeout: 10))
        XCTAssertTrue(robot.resultTable.waitForExistence(timeout: 10))
    }

    @MainActor
    func testHifiasmDeterministicRunShowsResultViewport() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makePacBioHiFiAssemblyProject(named: "HifiasmDeterministicAssemblyFixture")
        let robot = AssemblyRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "reads.fastq")
        robot.openAssemblyDialog()
        robot.chooseAssembler("Hifiasm")
        robot.clickPrimaryAction()

        robot.waitForAnalysisRow(prefix: "hifiasm-", timeout: 30)
        XCTAssertTrue(robot.resultView.waitForExistence(timeout: 10))
        XCTAssertTrue(robot.resultTable.waitForExistence(timeout: 10))
    }
}
