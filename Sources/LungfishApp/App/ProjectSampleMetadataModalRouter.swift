// ProjectSampleMetadataModalRouter.swift - project-level sample metadata sheet routing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

struct ProjectSampleMetadataSheetRequest: Equatable {
    let projectURL: URL
    let windowStateScope: WindowStateScope?
}

enum ProjectSampleMetadataModalRoute: Equatable {
    case missingProject(title: String, message: String)
    case exportSheet(ProjectSampleMetadataSheetRequest)
    case importSheet(ProjectSampleMetadataSheetRequest)
}

enum ProjectSampleMetadataModalRouter {
    static func exportRoute(projectURL: URL?) -> ProjectSampleMetadataModalRoute {
        guard let projectURL else {
            return .missingProject(
                title: "No Project Open",
                message: "Open a project folder to export sample metadata."
            )
        }
        return .exportSheet(.init(projectURL: projectURL, windowStateScope: nil))
    }

    static func importRoute(
        projectURL: URL?,
        windowStateScope: WindowStateScope?
    ) -> ProjectSampleMetadataModalRoute {
        guard let projectURL else {
            return .missingProject(
                title: "No Project Open",
                message: "Open a project folder to import sample metadata."
            )
        }
        return .importSheet(.init(projectURL: projectURL, windowStateScope: windowStateScope))
    }

    @MainActor
    static func makeExportSheet(for request: ProjectSampleMetadataSheetRequest) -> MetadataExportSheet {
        MetadataExportSheet(folderURL: request.projectURL)
    }

    @MainActor
    static func makeImportSheet(for request: ProjectSampleMetadataSheetRequest) -> MetadataImportSheet {
        MetadataImportSheet(
            folderURL: request.projectURL,
            windowStateScope: request.windowStateScope
        )
    }
}
