import XCTest

final class ViralReconXCUITests: XCTestCase {
    @MainActor
    func testViralReconDeterministicRunUsesSelectedIlluminaBundlesAndProjectPrimerScheme() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeViralReconIlluminaProject(
            named: "ViralReconIlluminaFixture"
        )
        let robot = MappingRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "SampleA", extendingSelection: true)
        robot.openMappingDialog()
        robot.chooseMapper("Viral Recon")

        let inputSummary = robot.app.descendants(matching: .any)["viral-recon-input-summary"].firstMatch
        XCTAssertTrue(inputSummary.waitForExistence(timeout: 10))

        robot.clickPrimaryAction()

        let runBundle = waitForViralReconRunBundle(in: projectURL)
        let request = try readRunBundleFile("inputs/viralrecon-request.json", in: runBundle)
        let samplesheet = try readRunBundleFile("inputs/samplesheet.csv", in: runBundle)

        XCTAssertContains(request, "\"platform\" : \"illumina\"")
        XCTAssertContains(request, "SampleA")
        XCTAssertContains(request, "SampleB")
        XCTAssertContains(request, "A UI Viral Recon Project Scheme")
        XCTAssertContains(request, "A-UI-ViralRecon-SARS2.lungfishprimers")
        XCTAssertContains(samplesheet, "sample,fastq_1,fastq_2")
        XCTAssertContains(samplesheet, "SampleA")
        XCTAssertContains(samplesheet, "SampleB")
        XCTAssertContains(samplesheet, "SampleA_R1.fastq.gz")
        XCTAssertContains(samplesheet, "SampleB_R2.fastq.gz")

        openOperationsPanel(in: robot.app)
        XCTAssertTrue(waitForOperationText("Viral Recon", in: robot.app, timeout: 10))
    }

    @MainActor
    func testViralReconDeterministicRunUsesSelectedONTBundlesAndBarcodes() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeViralReconONTProject(
            named: "ViralReconONTFixture"
        )
        let robot = MappingRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL, backendMode: "deterministic")
        robot.selectSidebarItem(named: "Barcode01", extendingSelection: true)
        robot.openMappingDialog()
        robot.chooseMapper("Viral Recon")
        robot.clickPrimaryAction()

        let runBundle = waitForViralReconRunBundle(in: projectURL)
        let request = try readRunBundleFile("inputs/viralrecon-request.json", in: runBundle)
        let samplesheet = try readRunBundleFile("inputs/samplesheet.csv", in: runBundle)

        XCTAssertContains(request, "\"platform\" : \"nanopore\"")
        XCTAssertContains(request, "Barcode01")
        XCTAssertContains(request, "Barcode02")
        XCTAssertContains(request, "A UI Viral Recon Project Scheme")
        XCTAssertContains(samplesheet, "sample,barcode")
        XCTAssertContains(samplesheet, "Barcode01,1")
        XCTAssertContains(samplesheet, "Barcode02,2")

        let barcode01 = runBundle.appendingPathComponent("inputs/nanopore/fastq_pass/barcode01", isDirectory: true)
        let barcode02 = runBundle.appendingPathComponent("inputs/nanopore/fastq_pass/barcode02", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: barcode01.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: barcode02.path))

        openOperationsPanel(in: robot.app)
        XCTAssertTrue(waitForOperationText("Viral Recon", in: robot.app, timeout: 10))
    }

    private func waitForViralReconRunBundle(
        in projectURL: URL,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL {
        let analysesURL = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let bundle = latestViralReconRunBundle(in: analysesURL),
               FileManager.default.fileExists(atPath: bundle.appendingPathComponent("inputs/viralrecon-request.json").path),
               FileManager.default.fileExists(atPath: bundle.appendingPathComponent("inputs/samplesheet.csv").path) {
                return bundle
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTFail("Timed out waiting for Viral Recon run bundle in \(analysesURL.path)", file: file, line: line)
        return analysesURL.appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
    }

    private func latestViralReconRunBundle(in analysesURL: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: analysesURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return contents
            .filter { $0.pathExtension == "lungfishrun" && $0.lastPathComponent.hasPrefix("viralrecon") }
            .sorted {
                let leftDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rightDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }
            .first
    }

    private func readRunBundleFile(_ relativePath: String, in runBundle: URL) throws -> String {
        try String(
            contentsOf: runBundle.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @MainActor
    private func openOperationsPanel(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.activate()
        let operationsMenu = app.menuBars.menuBarItems["Operations"]
        XCTAssertTrue(operationsMenu.waitForExistence(timeout: 5), file: file, line: line)
        operationsMenu.click()

        let panelItem = app.menuItems["Show Operations Panel"]
        XCTAssertTrue(panelItem.waitForExistence(timeout: 5), file: file, line: line)
        panelItem.click()

        XCTAssertTrue(app.tables["operations-table"].waitForExistence(timeout: 5), file: file, line: line)
    }

    @MainActor
    private func waitForOperationText(
        _ text: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let element = app.descendants(matching: .any).matching(predicate).firstMatch
        return element.waitForExistence(timeout: timeout)
    }

    private func XCTAssertContains(
        _ haystack: String,
        _ needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            haystack.contains(needle),
            "Expected text to contain \(needle).\nActual text:\n\(haystack)",
            file: file,
            line: line
        )
    }
}
