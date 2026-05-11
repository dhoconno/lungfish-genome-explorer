// PrimerTrimXCUITests.swift - Inspector surfaces the Primer-trim BAM button and runs the dialog
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

/// Exercises the primer-trim Inspector button against a sarscov2 mapped bundle
/// fixture. The first test asserts the dialog opens and exposes the project-
/// local scheme; the second exercises the full Run path and waits for the
/// new primer-trimmed alignment track to appear in the sidebar.
final class PrimerTrimXCUITests: XCTestCase {
    @MainActor
    func testInspectorExposesPrimerTrimButtonAndOpensDialog() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeMappedBundleProject(
            named: "PrimerTrimXCUIFixture"
        )
        let robot = BundleBrowserRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL)
        robot.openBundle(named: "Sample.lungfishref")
        robot.selectInspectorTab(named: "Analysis")
        robot.selectInspectorTab(named: "Primer Trim")

        let primerTrimButton = robot.app.buttons["Primer-trim BAM…"]
        XCTAssertTrue(
            primerTrimButton.waitForExistence(timeout: 10),
            "Inspector must surface the Primer-trim BAM button"
        )
        primerTrimButton.click()

        let picker = robot.app.descendants(matching: .any)["primer-scheme-picker"].firstMatch
        XCTAssertTrue(
            picker.waitForExistence(timeout: 5),
            "Clicking the button must open the primer-trim dialog with the standard primer scheme picker"
        )
    }

    @MainActor
    func testRunButtonProducesNewAlignmentTrack() throws {
        let projectURL = try LungfishProjectFixtureBuilder.makeMappedBundleProject(
            named: "PrimerTrimRunFixture"
        )
        let robot = BundleBrowserRobot()
        defer {
            robot.app.terminate()
            try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent())
        }

        robot.launch(opening: projectURL)
        robot.openBundle(named: "Sample.lungfishref")
        robot.selectInspectorTab(named: "Analysis")
        robot.selectInspectorTab(named: "Primer Trim")

        let primerTrimButton = robot.app.buttons["Primer-trim BAM…"]
        XCTAssertTrue(primerTrimButton.waitForExistence(timeout: 10))
        primerTrimButton.click()

        choosePrimerScheme(named: "MT192765 Integration Test", in: robot.app)

        XCTAssertTrue(
            robot.app.staticTexts["Ready to trim using MT192765 Integration Test."].waitForExistence(timeout: 5)
        )

        let runButton = robot.app.buttons["Run"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 5))
        XCTAssertTrue(runButton.isEnabled)
        runButton.click()

        XCTAssertTrue(
            waitForPrimerTrimmedAlignment(in: projectURL, timeout: 120),
            "The GUI run must append a primer-trimmed alignment track with bundle-owned BAM/BAI artifacts and provenance."
        )
    }

    private func waitForPrimerTrimmedAlignment(
        in projectURL: URL,
        timeout: TimeInterval
    ) -> Bool {
        let bundleURL = projectURL.appendingPathComponent("Sample.lungfishref", isDirectory: true)
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if primerTrimmedAlignmentExists(bundleURL: bundleURL, manifestURL: manifestURL) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return false
    }

    @MainActor
    private func choosePrimerScheme(named name: String, in app: XCUIApplication) {
        let picker = app.descendants(matching: .any)["primer-scheme-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()

        let menuItem = app.menuItems[name].firstMatch
        if menuItem.waitForExistence(timeout: 5) {
            menuItem.click()
            return
        }

        let textItem = app.staticTexts[name].firstMatch
        XCTAssertTrue(textItem.waitForExistence(timeout: 5))
        textItem.click()
    }

    private func primerTrimmedAlignmentExists(bundleURL: URL, manifestURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let alignments = json["alignments"] as? [[String: Any]] else {
            return false
        }

        for alignment in alignments {
            guard let name = alignment["name"] as? String,
                  name.contains("Primer-trimmed"),
                  let sourcePath = alignment["source_path"] as? String,
                  let indexPath = alignment["index_path"] as? String else {
                continue
            }

            let bamURL = bundleURL.appendingPathComponent(sourcePath)
            let indexURL = bundleURL.appendingPathComponent(indexPath)
            let provenanceURL = bamURL
                .deletingPathExtension()
                .appendingPathExtension("primer-trim-provenance.json")

            if FileManager.default.fileExists(atPath: bamURL.path),
               FileManager.default.fileExists(atPath: indexURL.path),
               primerTrimSidecarIsComplete(provenanceURL: provenanceURL, bamURL: bamURL, indexURL: indexURL) {
                return true
            }
        }

        return false
    }

    private func primerTrimSidecarIsComplete(provenanceURL: URL, bamURL: URL, indexURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: provenanceURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["operation"] as? String == "primer-trim",
              (json["schema_version"] as? Int ?? 0) >= 2,
              json["workflow_name"] as? String == "lungfish bam primer-trim",
              json["exit_status"] as? Int == 0,
              let command = json["command"] as? [String],
              command.contains("primer-trim"),
              let inputFiles = json["input_files"] as? [[String: Any]],
              !inputFiles.isEmpty,
              let outputFiles = json["output_files"] as? [[String: Any]],
              let runtimeIdentity = json["runtime_identity"] as? [String: Any],
              !runtimeIdentity.isEmpty else {
            return false
        }

        let outputPaths = Set(outputFiles.compactMap { $0["path"] as? String })
        return outputPaths.contains(bamURL.path) && outputPaths.contains(indexURL.path)
    }
}
