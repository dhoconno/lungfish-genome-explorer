import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

@MainActor
public final class ProjectSession: Identifiable {
    public let id: UUID
    public let windowStateScope: WindowStateScope
    public private(set) var projectURL: URL?
    public private(set) var project: ProjectFile?
    public private(set) var openWarningState: ProjectOpenWarningState = .unlocked(projectURL: nil)
    public private(set) var documents: [LoadedDocument] = []
    public private(set) var activeDocument: LoadedDocument?
    public private(set) var workingDirectoryURL: URL?
    public private(set) var isReadOnlyFilesystemFallback = false

    public init(id: UUID = UUID(), windowStateScope: WindowStateScope = WindowStateScope()) {
        self.id = id
        self.windowStateScope = windowStateScope
    }

    @discardableResult
    public func openProject(at url: URL, access: ProjectAccessMode = .writable) throws -> ProjectFile {
        let standardizedURL = url.standardizedFileURL
        let warning = ProjectStore.ownsWriterLease(at: standardizedURL)
            ? ProjectOpenWarningState.unlocked(projectURL: standardizedURL)
            : ProjectOpenWarningState.evaluate(projectURL: standardizedURL)
        let databaseName = FileManager.default.fileExists(atPath: standardizedURL.appendingPathComponent(".project.db").path)
            ? ".project.db" : "project.db"
        let writablePaths = [standardizedURL.path,
                             standardizedURL.appendingPathComponent(databaseName).path,
                             standardizedURL.appendingPathComponent("metadata.json").path]
        let effectiveAccess: ProjectAccessMode = access == .readOnly || warning.isReadOnlyRecommended
            || writablePaths.contains(where: { !FileManager.default.isWritableFile(atPath: $0) })
            ? .readOnly : .writable
        let openedProject = try ProjectFile.open(at: standardizedURL, access: effectiveAccess)
        let loadedDocuments = try ProjectDocumentLoader.loadSequences(from: openedProject)

        projectURL = openedProject.url.standardizedFileURL
        workingDirectoryURL = openedProject.url.standardizedFileURL
        project = openedProject
        isReadOnlyFilesystemFallback = false
        openWarningState = warning
        documents = loadedDocuments
        activeDocument = loadedDocuments.first

        return openedProject
    }

    @discardableResult
    public func createProject(
        at url: URL,
        name: String,
        description: String? = nil,
        author: String? = nil
    ) throws -> ProjectFile {
        let createdProject = try ProjectFile.create(
            at: url,
            name: name,
            description: description,
            author: author
        )
        _ = try? PrimerSchemesFolder.ensureFolder(in: createdProject.url)

        projectURL = createdProject.url.standardizedFileURL
        workingDirectoryURL = createdProject.url.standardizedFileURL
        project = createdProject
        isReadOnlyFilesystemFallback = false
        openWarningState = .unlocked(projectURL: createdProject.url)
        documents = []
        activeDocument = nil

        return createdProject
    }

    public var isReadOnlyRecommended: Bool {
        isReadOnlyFilesystemFallback || project?.accessMode == .readOnly || openWarningState.isReadOnlyRecommended
    }

    /// A rejected native project can still be browsed, but its root must not
    /// become an implicitly writable plain folder through the fallback UI.
    public func openReadOnlyFilesystemFallback(at url: URL) {
        closeProject()
        projectURL = url.standardizedFileURL
        workingDirectoryURL = url.standardizedFileURL
        openWarningState = ProjectOpenWarningState.evaluate(projectURL: url)
        isReadOnlyFilesystemFallback = true
    }

    public func setActiveDocument(_ document: LoadedDocument?) {
        activeDocument = document
    }

    public func closeProject() {
        isReadOnlyFilesystemFallback = false
        projectURL = nil
        workingDirectoryURL = nil
        project = nil
        openWarningState = .unlocked(projectURL: nil)
        documents = []
        activeDocument = nil
    }
}
