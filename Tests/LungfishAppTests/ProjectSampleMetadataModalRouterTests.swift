// ProjectSampleMetadataModalRouterTests.swift - project metadata modal routing coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

@MainActor
final class ProjectSampleMetadataModalRouterTests: XCTestCase {
    func testExportRouteRequiresProjectFolder() {
        XCTAssertEqual(
            ProjectSampleMetadataModalRouter.exportRoute(projectURL: nil),
            .missingProject(
                title: "No Project Open",
                message: "Open a project folder to export sample metadata."
            )
        )
    }

    func testExportRouteBuildsSheetRequestForProjectFolder() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)

        XCTAssertEqual(
            ProjectSampleMetadataModalRouter.exportRoute(projectURL: projectURL),
            .exportSheet(.init(projectURL: projectURL, windowStateScope: nil))
        )
    }

    func testImportRouteRequiresProjectFolder() {
        XCTAssertEqual(
            ProjectSampleMetadataModalRouter.importRoute(projectURL: nil, windowStateScope: WindowStateScope()),
            .missingProject(
                title: "No Project Open",
                message: "Open a project folder to import sample metadata."
            )
        )
    }

    func testImportRouteCarriesOriginatingWindowScope() {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let scope = WindowStateScope()

        XCTAssertEqual(
            ProjectSampleMetadataModalRouter.importRoute(projectURL: projectURL, windowStateScope: scope),
            .importSheet(.init(projectURL: projectURL, windowStateScope: scope))
        )
    }
}
