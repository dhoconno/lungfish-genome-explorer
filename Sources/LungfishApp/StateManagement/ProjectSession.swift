import Foundation
import LungfishCore
import LungfishIO

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

    public init(id: UUID = UUID(), windowStateScope: WindowStateScope = WindowStateScope()) {
        self.id = id
        self.windowStateScope = windowStateScope
    }

    @discardableResult
    public func openProject(at url: URL) throws -> ProjectFile {
        let standardizedURL = url.standardizedFileURL
        let warning = ProjectOpenWarningState.evaluate(projectURL: standardizedURL)
        let openedProject = try ProjectFile.open(at: standardizedURL)
        let loadedDocuments = try ProjectDocumentLoader.loadSequences(from: openedProject)

        projectURL = openedProject.url.standardizedFileURL
        workingDirectoryURL = openedProject.url.standardizedFileURL
        project = openedProject
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
        openWarningState = .unlocked(projectURL: createdProject.url)
        documents = []
        activeDocument = nil

        return createdProject
    }

    public var isReadOnlyRecommended: Bool {
        openWarningState.isReadOnlyRecommended
    }

    public func setActiveDocument(_ document: LoadedDocument?) {
        activeDocument = document
    }

    public func closeProject() {
        projectURL = nil
        workingDirectoryURL = nil
        project = nil
        openWarningState = .unlocked(projectURL: nil)
        documents = []
        activeDocument = nil
    }
}
