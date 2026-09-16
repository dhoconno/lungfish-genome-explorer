import XCTest

@MainActor
final class DatabaseSearchXCUITests: XCTestCase {
    private var robot: LungfishAppRobot!

    override func setUpWithError() throws {
        continueAfterFailure = false
        robot = LungfishAppRobot()
    }

    override func tearDownWithError() throws {
        robot = nil
    }

    @MainActor
    func testOpeningNCBISearchThroughToolsMenuShowsUnifiedSearchDialog() {
        robot.launch()

        let dialog = robot.openDatabaseSearch(destinationMenuTitle: "Search NCBI...")

        XCTAssertTrue(dialog.exists)
        XCTAssertTrue(robot.sidebarToolButton("database-search-tool-genbank-genomes").exists)
        XCTAssertTrue(robot.queryField.exists)
        XCTAssertEqual(robot.primaryActionButton.label, "Search")
    }

    @MainActor
    func testOpeningPathoplexusRequiresConsentBeforeSearchActionsAreEnabled() {
        robot.launch(pathoplexusConsentAccepted: false)

        _ = robot.openDatabaseSearch(destinationMenuTitle: "Search Pathoplexus...")

        XCTAssertTrue(robot.app.buttons["database-search-pathoplexus-consent-accept"].waitForExistence(timeout: 5))
        XCTAssertTrue(robot.app.buttons["database-search-pathoplexus-consent-cancel"].exists)
        XCTAssertFalse(robot.primaryActionButton.isEnabled)
    }

    @MainActor
    func testSwitchingDestinationsPreservesEnteredQueryText() {
        robot.launch()

        _ = robot.openDatabaseSearch(destinationMenuTitle: "Search NCBI...")
        robot.enterQuery("influenza A virus")

        robot.sidebarToolButton("database-search-tool-sra-runs").click()
        XCTAssertEqual(robot.queryValue(), "")

        robot.enterQuery("SRR35517702")
        robot.sidebarToolButton("database-search-tool-genbank-genomes").click()
        XCTAssertEqual(robot.queryValue(), "influenza A virus")

        robot.sidebarToolButton("database-search-tool-sra-runs").click()
        XCTAssertEqual(robot.queryValue(), "SRR35517702")
    }

    @MainActor
    func testDeterministicSearchChangesPrimaryActionToDownloadSelectedAfterSelection() {
        robot.launch()

        _ = robot.openDatabaseSearch(destinationMenuTitle: "Search NCBI...")
        robot.enterQuery("SARS-CoV-2")

        XCTAssertEqual(robot.primaryActionButton.label, "Search")
        robot.primaryActionButton.click()

        let firstResult = robot.resultRow(accession: "NC_045512.2")
        firstResult.click()

        robot.waitForPrimaryActionLabel("Download Selected")
        XCTAssertEqual(robot.primaryActionButton.label, "Download Selected")
    }

    @MainActor
    func testSelectAllAndDeselectAllNCBIResults() {
        robot.launch()
        _ = robot.openDatabaseSearch(destinationMenuTitle: "Search NCBI...")
        robot.enterQuery("SARS-CoV-2")
        robot.primaryActionButton.click()

        robot.waitForBulkSelectionLabel("Select all")
        robot.bulkSelectionButton.click()
        robot.waitForBulkSelectionLabel("Deselect all")
        robot.waitForStatusText("2 selected")
        robot.waitForPrimaryActionLabel("Download Selected")

        robot.bulkSelectionButton.click()
        robot.waitForBulkSelectionLabel("Select all")
        robot.waitForStatusText("Ready")
        robot.waitForPrimaryActionLabel("Search")
    }

    @MainActor
    func testSelectAllAndDeselectAllSRARunResults() {
        robot.launch()
        _ = robot.openDatabaseSearch(destinationMenuTitle: "Search NCBI...")
        robot.sidebarToolButton("database-search-tool-sra-runs").click()
        robot.enterQuery("SRR000001")
        robot.primaryActionButton.click()

        robot.waitForBulkSelectionLabel("Select all")
        robot.bulkSelectionButton.click()
        robot.waitForBulkSelectionLabel("Deselect all")
        robot.waitForStatusText("1 selected")
        robot.waitForPrimaryActionLabel("Download Selected")

        robot.bulkSelectionButton.click()
        robot.waitForBulkSelectionLabel("Select all")
        robot.waitForStatusText("Ready")
        robot.waitForPrimaryActionLabel("Search")
    }
}
