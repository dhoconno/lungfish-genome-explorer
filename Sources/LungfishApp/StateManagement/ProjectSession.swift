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
    public private(set) var isFilesystemUnavailable = false
    public private(set) var documentGeneration: UInt64 = 0
    private(set) var hydrationWorker: ProjectHydrationWorker?
    var hydrationLoader: (@Sendable (ProjectStore, UUID) async throws -> ProjectHydrationSnapshot)?

    public init(id: UUID = UUID(), windowStateScope: WindowStateScope = WindowStateScope()) {
        self.id = id
        self.windowStateScope = windowStateScope
    }

    struct PreparedProject: Sendable {
        let file: ProjectFile.PreparedOpen
        let warning: ProjectOpenWarningState
    }

    /// No UI object crosses this boundary. Access/lease checks and all database
    /// inspection run on the caller's storage executor.
    nonisolated static func prepareProject(at url: URL, access: ProjectAccessMode = .writable, deferCleanup: Bool = false) throws -> PreparedProject {
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
        return PreparedProject(file: try ProjectFile.prepareOpen(at: standardizedURL, access: effectiveAccess, deferCleanup: deferCleanup), warning: warning)
    }

    @discardableResult
    public func openProject(at url: URL, access: ProjectAccessMode = .writable) throws -> ProjectFile {
        try acceptPreparedProject(Self.prepareProject(at: url, access: access))
    }

    /// Reserve ownership before launching a worker. Close/switch invalidates it.
    func beginProjectOpen() -> UInt64 {
        documentGeneration &+= 1
        return documentGeneration
    }

    @discardableResult
    func acceptPreparedProject(_ prepared: PreparedProject, generation: UInt64? = nil) throws -> ProjectFile {
        if let generation, generation != documentGeneration { throw CancellationError() }
        let openedProject = ProjectFile.acceptPreparedOpen(prepared.file)
        let catalog = ProjectDocumentLoader.catalogDocuments(prepared.file.catalog, projectURL: openedProject.url)
        documentGeneration &+= 1
        projectURL = openedProject.url.standardizedFileURL
        workingDirectoryURL = openedProject.url.standardizedFileURL
        project = openedProject
        isReadOnlyFilesystemFallback = false
        isFilesystemUnavailable = false
        openWarningState = prepared.warning
        documents = catalog
        activeDocument = catalog.first
        hydrationWorker = ProjectHydrationWorkers.worker(for: openedProject.url)
        return openedProject
    }

    @discardableResult
    public func openProjectAsync(at url: URL, access: ProjectAccessMode = .writable) async throws -> ProjectFile {
        let generation = beginProjectOpen()
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepareProject(at: url, access: access, deferCleanup: true)
        }.value
        try Task.checkCancellation()
        return try acceptPreparedProject(prepared, generation: generation)
    }

    /// Payload construction runs on the shared project worker. The caller's
    /// existing display gate authorizes all observable mutation after the await.
    func hydrateProjectDocument(_ document: LoadedDocument, keeping selectedIDs: Set<UUID> = [], canPublish: @escaping @MainActor () -> Bool = { true }) async throws -> LoadedDocument? {
        guard let sequenceID = document.projectSequenceID, let project, let worker = hydrationWorker,
              documents.contains(where: { $0 === document }), canPublish() else { return nil }
        let generation = documentGeneration
        let store = project.hydrationStore
        let snapshot: ProjectHydrationSnapshot
        if let hydrationLoader { snapshot = try await hydrationLoader(store, sequenceID) }
        else { snapshot = try await worker.hydrate(sequenceID: sequenceID, store: store) }
        guard !Task.isCancelled, documentGeneration == generation, canPublish(),
              documents.contains(where: { $0 === document }) else { return nil }
        for other in documents where other.projectSequenceID != nil && other !== document && !selectedIDs.contains(other.id) {
            other.sequences = []
            other.annotations = []
        }
        document.sequences = [snapshot.sequence]
        document.annotations = snapshot.annotations
        activeDocument = document
        DocumentManager.shared.refreshMirror(ifOwnedBy: self)
        return document
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

        documentGeneration &+= 1
        projectURL = createdProject.url.standardizedFileURL
        workingDirectoryURL = createdProject.url.standardizedFileURL
        project = createdProject
        isReadOnlyFilesystemFallback = false
        isFilesystemUnavailable = false
        openWarningState = .unlocked(projectURL: createdProject.url)
        documents = []
        activeDocument = nil
        hydrationWorker = ProjectHydrationWorkers.worker(for: createdProject.url)

        return createdProject
    }

    public var isReadOnlyRecommended: Bool {
        isFilesystemUnavailable || isReadOnlyFilesystemFallback || project?.accessMode == .readOnly || openWarningState.isReadOnlyRecommended
    }

    /// Retain the remembered root and readable document values, but release the
    /// writable project handle. A later accepted open restores usable scope.
    func markFilesystemUnavailable(at url: URL, invalidateGeneration: Bool = true) {
        guard projectURL == nil || projectURL?.standardizedFileURL.path == url.standardizedFileURL.path else { return }
        guard !isFilesystemUnavailable else { return }
        if invalidateGeneration { documentGeneration &+= 1 }
        isFilesystemUnavailable = true
        project = nil
        hydrationWorker = nil
        DocumentManager.shared.refreshMirror(ifOwnedBy: self)
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

    /// Canonical, component-aware containment. Symlinks refer to their resolved
    /// target, so sibling prefixes and aliases cannot imply project membership.
    public nonisolated static func contains(_ documentURL: URL, in projectURL: URL) -> Bool {
        let document = documentURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let project = projectURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return document.starts(with: project)
    }

    @discardableResult
    public func registerDocument(_ document: LoadedDocument, makeActive: Bool = true, replaceContent: Bool = false) -> LoadedDocument {
        let registered = documents.first(where: { existing in
            if let sequenceID = document.projectSequenceID { return existing.projectSequenceID == sequenceID }
            return existing.projectSequenceID == nil && existing.url.standardizedFileURL == document.url.standardizedFileURL
        }) ?? document
        if replaceContent, registered !== document {
            registered.sequences = document.sequences
            registered.annotations = document.annotations
            registered.bundleManifest = document.bundleManifest
            registered.isTruncated = document.isTruncated
        }
        if !documents.contains(where: { $0.id == registered.id }) {
            documents.append(registered)
        }
        if makeActive { activeDocument = registered }
        NotificationCenter.default.post(name: DocumentManager.documentLoadedNotification, object: self, userInfo: [
            "document": registered,
            "sessionID": id,
            "makeActive": makeActive,
            NotificationUserInfoKey.windowStateScope: windowStateScope
        ])
        return registered
    }

    public func closeDocument(_ document: LoadedDocument) {
        documents.removeAll { $0.id == document.id }
        if activeDocument?.id == document.id { activeDocument = documents.first }
    }

    /// The caller supplies its existing display gate. Registration, viewport and
    /// inspector publication, errors, and progress all obey the same authority.
    public func loadAndPublishDocument(
        at url: URL,
        loader: @escaping @MainActor (URL) async throws -> LoadedDocument = { try await DocumentManager.shared.readDocument(at: $0) },
        canPublish: @escaping @MainActor () -> Bool,
        publish: @escaping @MainActor (LoadedDocument) -> Void,
        failure: @escaping @MainActor (Error) -> Void,
        loading: @escaping @MainActor (Bool) -> Void
    ) async {
        let generation = documentGeneration
        let isCurrent = { @MainActor in
            !Task.isCancelled && self.documentGeneration == generation && canPublish()
        }
        guard isCurrent() else { return }
        loading(true)
        defer { if isCurrent() { loading(false) } }
        do {
            let loaded = try await loader(url)
            guard isCurrent() else { return }
            let document = registerDocument(loaded, replaceContent: true)
            DocumentManager.shared.refreshMirror(ifOwnedBy: self)
            guard isCurrent() else { return }
            publish(document)
        } catch {
            guard isCurrent() else { return }
            failure(error)
        }
    }

    public func setActiveDocument(_ document: LoadedDocument?) {
        activeDocument = document
    }

    public func closeProject() {
        documentGeneration &+= 1
        hydrationWorker = nil
        isReadOnlyFilesystemFallback = false
        isFilesystemUnavailable = false
        projectURL = nil
        workingDirectoryURL = nil
        project = nil
        openWarningState = .unlocked(projectURL: nil)
        documents = []
        activeDocument = nil
    }
}
