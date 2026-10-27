// ProjectRootTest.swift - The one test of whether a folder is a Lungfish project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Whether a folder is a Lungfish project. Every check of "is this a project" asks it, so the app, the CLI and
/// the workflow layer agree on which folder is the project (Phase 3.0 lane PROJECT-ROOT, walk WF-3 and WF-2b).
///
/// A folder is a project when its name ends in `.lungfish`, or when it holds `metadata.json` and the project
/// database, `.project.db` or `project.db`. Those are the files ``ProjectFile/prepareOpen(at:access:deferCleanup:)``
/// opens, so a folder that File > Open Project Folder… opens as a project is one here too, as Finder's copy
/// `P.lungfish copy` or a project renamed without its extension. The name comes first, so a folder named
/// `X.lungfish` that holds nothing yet is a project, as a test fixture is.
///
/// The test reads no file contents, so a walk up from a deep result stays cheap. A result folder or a bundle that
/// holds its own `metadata.json` holds no project database, so it is never taken for a project. The `.lungfish/`
/// folder is no sign, since only the first writer lock makes it and a project opened read-only has none.
public nonisolated enum ProjectRootTest {

    /// The metadata file of a project, which ``ProjectFile`` writes when it makes one.
    public static let metadataFileName = "metadata.json"

    /// The names the project database may have. `ProjectStore` makes `.project.db`, and an older project has
    /// `project.db`.
    public static let databaseFileNames = [".project.db", "project.db"]

    /// Whether `url` is the root folder of a Lungfish project.
    public static func isProjectRoot(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == ProjectFile.fileExtension {
            return true
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.appendingPathComponent(metadataFileName).path) else {
            return false
        }
        return databaseFileNames.contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }
}
