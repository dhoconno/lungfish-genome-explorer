// MainSplitSidebarDropRoutingTests.swift - Tests for sidebar drop notification ownership
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import XCTest
@testable import LungfishApp

@MainActor
final class MainSplitSidebarDropRoutingTests: XCTestCase {

    func testSidebarDropNotificationsAreHandledOnlyByOwningSplitController() {
        let sourceSidebar = SidebarViewController()
        let destinationSidebar = SidebarViewController()

        XCTAssertFalse(
            MainSplitViewController.shouldHandleSidebarFileDropNotification(
                from: destinationSidebar,
                owningSidebar: sourceSidebar,
                owningViewer: nil
            ),
            "A source project window must not process a drop posted by a different sidebar."
        )
        XCTAssertTrue(
            MainSplitViewController.shouldHandleSidebarFileDropNotification(
                from: destinationSidebar,
                owningSidebar: destinationSidebar,
                owningViewer: nil
            ),
            "The destination project window should process drops posted by its own sidebar."
        )
        XCTAssertTrue(
            MainSplitViewController.shouldHandleSidebarFileDropNotification(
                from: nil,
                owningSidebar: sourceSidebar,
                owningViewer: nil
            ),
            "Legacy/global import notifications should continue to route through the existing handler."
        )
    }

    func testImportedCSVAutoDisplayUsesSidebarPreviewPath() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainSplitImportedCSV-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let csvURL = projectURL.appendingPathComponent("report.csv")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "sample,reads\nDW472,20\n".write(to: csvURL, atomically: true, encoding: .utf8)

        let controller = MainSplitViewController()
        _ = controller.view
        controller.sidebarController.openProject(at: projectURL)

        defer {
            controller.sidebarController.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        controller.testingDisplayImportedProjectFile(csvURL)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(
            controller.sidebarController.selectedFileURL?.standardizedFileURL,
            csvURL.standardizedFileURL
        )
        XCTAssertEqual(
            controller.viewerController.testQuickLookURL?.standardizedFileURL,
            csvURL.standardizedFileURL
        )
        XCTAssertFalse(
            controller.viewerController.testHasQuickLookView,
            "Unit tests should verify routing without instantiating embedded QuickLook views."
        )
    }

    func testDroppedMHCReferenceBundleInstallsIntoReferenceAlleleDatabases() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainSplitMHCRefDrop-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let dropSourceDir = tempRoot.appendingPathComponent("DroppedFrom", isDirectory: true)
        let bundleURL = dropSourceDir.appendingPathComponent("Example.lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // A valid bundle so MHCAmpliconReferenceBundle.isBundleURL + validate pass.
        try ">ref\nACGT\n".write(
            to: bundleURL.appendingPathComponent("reference.fa"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "Example",
            referenceFastaPath: "reference.fa",
            haplotypeDefinitionPaths: [],
            defaultHaplotypeDefinitionID: nil,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 0),
            createdAt: "2026-05-31T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)
        XCTAssertTrue(MHCAmpliconReferenceBundle.isBundleURL(bundleURL))

        let controller = MainSplitViewController()
        _ = controller.view
        controller.sidebarController.openProject(at: projectURL)

        defer {
            controller.sidebarController.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        // Mirror the drop routing: dropping onto the project root passes targetDir =
        // projectURL, but the bundle must land in Reference allele databases/, not
        // the generic targetDir.
        await controller.testingImportNonFASTQFile(
            url: bundleURL,
            projectURL: projectURL,
            targetDir: projectURL
        )

        let installedBundleURL = projectURL
            .appendingPathComponent("Reference allele databases", isDirectory: true)
            .appendingPathComponent("Example.lungfishmhcref", isDirectory: true)
        XCTAssertTrue(
            MHCAmpliconReferenceBundle.isBundleURL(installedBundleURL),
            "Dropped .lungfishmhcref must be installed as a single bundle under Reference allele databases/."
        )

        // It must NOT be shattered into the project root as loose manifest/reference files.
        let strayManifest = projectURL.appendingPathComponent("mhc-reference.json")
        let strayReference = projectURL.appendingPathComponent("reference.fa")
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayManifest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayReference.path))
    }

    func testDroppedMHCReferenceBundleZipInstallsDecompressedBundleAndLeavesOriginalArchive() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainSplitMHCRefZipDrop-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let dropSourceDir = tempRoot.appendingPathComponent("DroppedFrom", isDirectory: true)
        let bundleURL = dropSourceDir.appendingPathComponent("Example.lungfishmhcref", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Self.writeMHCReferenceBundle(at: bundleURL)

        let archiveURL = tempRoot.appendingPathComponent("Example.lungfishmhcref.zip")
        try Self.runZip(
            workingDirectory: dropSourceDir,
            archiveURL: archiveURL,
            entries: ["Example.lungfishmhcref"]
        )

        let controller = MainSplitViewController()
        _ = controller.view
        controller.sidebarController.openProject(at: projectURL)

        defer {
            controller.sidebarController.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        NotificationCenter.default.post(
            name: .sidebarFileDropped,
            object: controller.sidebarController,
            userInfo: [
                "urls": [archiveURL],
                "destination": NSNull(),
                "requestID": UUID().uuidString,
                NotificationUserInfoKey.windowStateScope: controller.testingWindowStateScope
            ]
        )

        let installedBundleURL = projectURL
            .appendingPathComponent("Reference allele databases", isDirectory: true)
            .appendingPathComponent("Example.lungfishmhcref", isDirectory: true)
        try await Self.waitUntilFileExists(installedBundleURL)

        XCTAssertTrue(MHCAmpliconReferenceBundle.isBundleURL(installedBundleURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path), "The user's original ZIP must remain in place.")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: projectURL.appendingPathComponent(archiveURL.lastPathComponent).path),
            "The ZIP wrapper must not be copied into the project as the imported object."
        )

        let projectTempURL = projectURL.appendingPathComponent(".tmp", isDirectory: true)
        let tempChildren = (try? FileManager.default.contentsOfDirectory(
            at: projectTempURL,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertFalse(
            tempChildren.contains { $0.lastPathComponent.hasPrefix("sidebar-zip-import-") },
            "Temporary ZIP extraction directories should be removed after import consumes the bundle."
        )
    }

    private static func writeMHCReferenceBundle(at bundleURL: URL) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try ">ref\nACGT\n".write(
            to: bundleURL.appendingPathComponent("reference.fa"),
            atomically: true,
            encoding: .utf8
        )
        let manifest = MHCAmpliconReferenceBundleManifest(
            name: "Example",
            referenceFastaPath: "reference.fa",
            haplotypeDefinitionPaths: [],
            defaultHaplotypeDefinitionID: nil,
            metrics: MHCAmpliconReferenceBundleMetrics(referenceCount: 1, haplotypeDefinitionCount: 0),
            createdAt: "2026-06-24T00:00:00Z"
        )
        try MHCAmpliconReferenceBundle.writeManifest(manifest, to: bundleURL)
    }

    private static func runZip(workingDirectory: URL, archiveURL: URL, entries: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workingDirectory
        process.arguments = ["-qry", archiveURL.path] + entries
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private static func waitUntilFileExists(
        _ url: URL,
        timeout: TimeInterval = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(url.path)", file: file, line: line)
    }
}
