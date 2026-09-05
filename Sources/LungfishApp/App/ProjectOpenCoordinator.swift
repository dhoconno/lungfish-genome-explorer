// ProjectOpenCoordinator.swift - Project create/open coordination
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

@MainActor
final class ProjectOpenCoordinator {
    struct FilesystemFallback {
        let url: URL
        let name: String
        let error: Error
    }

    enum OpenResult {
        case opened(ProjectFile)
        case filesystemFallback(FilesystemFallback)
    }

    typealias RecentProjectRecorder = (_ url: URL, _ name: String) -> Void

    private let recordRecentProject: RecentProjectRecorder

    init(recordRecentProject: @escaping RecentProjectRecorder = { url, name in
        RecentProjectsManager.shared.addRecentProject(url: url, name: name)
    }) {
        self.recordRecentProject = recordRecentProject
    }

    @discardableResult
    func createProject(
        at projectURL: URL,
        using session: ProjectSession,
        name: String? = nil
    ) throws -> ProjectFile {
        let project = try session.createProject(
            at: projectURL,
            name: name ?? projectURL.deletingPathExtension().lastPathComponent
        )
        recordRecentProject(project.url, project.name)
        return project
    }

    func completePreparedOpen(_ preparation: Result<ProjectSession.PreparedProject, Error>, at projectURL: URL, using session: ProjectSession, generation: UInt64) throws -> OpenResult {
        guard session.documentGeneration == generation else { throw CancellationError() }
        switch preparation {
        case .success(let prepared):
            let project = try session.acceptPreparedProject(prepared, generation: generation)
            recordRecentProject(project.url, project.name)
            return .opened(project)
        case .failure(let error):
            if error is CancellationError { throw error }
            let name = projectURL.deletingPathExtension().lastPathComponent
            recordRecentProject(projectURL, name)
            return .filesystemFallback(FilesystemFallback(url: projectURL, name: name, error: error))
        }
    }

    @discardableResult
    func openProject(
        at projectURL: URL,
        using session: ProjectSession
    ) -> OpenResult {
        do {
            let project = try session.openProject(at: projectURL)
            recordRecentProject(project.url, project.name)
            return .opened(project)
        } catch {
            let projectName = projectURL.deletingPathExtension().lastPathComponent
            recordRecentProject(projectURL, projectName)
            return .filesystemFallback(FilesystemFallback(
                url: projectURL,
                name: projectName,
                error: error
            ))
        }
    }
}
