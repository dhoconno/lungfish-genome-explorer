import Foundation
import LungfishCore

/// Ordered source values captured before the destination sheet. The export
/// writer and retained-selection publication remain separate authorities.
@MainActor
enum SequenceExportSourceResolver {
    struct Metadata: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case filesystem, openDocument, nativeProjectSequence }
        let kind: Kind
        let url: URL
        let documentID: UUID?
        let nativeSequenceID: UUID?
        let projectURL: URL?
    }

    struct Source: Sendable {
        let metadata: Metadata
        let document: SequenceExportDocumentSnapshot?
    }

    enum CaptureError: LocalizedError {
        case staleDocument(String)
        case unavailableNativeDocument(String)
        case missingFileURL(String)
        var errorDescription: String? {
            switch self {
            case .staleDocument(let name): return "The selected document \(name) is no longer open. Select it again before exporting."
            case .unavailableNativeDocument(let name): return "The selected project sequence \(name) is unavailable. Reopen the project before exporting."
            case .missingFileURL(let name): return "The selected source \(name) has no file location."
            }
        }
    }

    fileprivate typealias Loader = @Sendable (ProjectStore, UUID) async throws -> ProjectHydrationSnapshot
    fileprivate enum PendingSource {
        case value(Source)
        case native(Metadata, String, ProjectStore, ProjectHydrationWorker, Loader?)
    }

    @MainActor
    struct Request {
        fileprivate let session: ProjectSession
        fileprivate let generation: UInt64
        fileprivate let registeredDocuments: [LoadedDocument]
        fileprivate let pending: [PendingSource]

        private func validateOwnership() throws {
            try Task.checkCancellation()
            guard session.documentGeneration == generation, !session.isFilesystemUnavailable,
                  registeredDocuments.allSatisfy({ selected in session.documents.contains { $0 === selected } }) else {
                throw CancellationError()
            }
        }

        /// Resolve once before presenting the destination. Only immutable values
        /// are returned; no document, selection or Inspector publication occurs.
        func resolve() async throws -> [Source] {
            try validateOwnership()
            var sources: [Source] = []
            for source in pending {
                try validateOwnership()
                switch source {
                case .value(let value): sources.append(value)
                case .native(let metadata, let name, let store, let worker, let loader):
                    guard let sequenceID = metadata.nativeSequenceID else {
                        throw CaptureError.unavailableNativeDocument(name)
                    }
                    let snapshot: ProjectHydrationSnapshot
                    if let loader { snapshot = try await loader(store, sequenceID) }
                    else { snapshot = try await worker.hydrate(sequenceID: sequenceID, store: store) }
                    try validateOwnership()
                    sources.append(Source(metadata: metadata, document: SequenceExportDocumentSnapshot(
                        name: name, url: metadata.url, sequences: [snapshot.sequence], annotations: snapshot.annotations)))
                }
            }
            try validateOwnership()
            return sources
        }
    }

    /// Eligibility is supplied by SidebarExportSelection. Explicit document IDs
    /// resolve only within the originating session/current viewer; display paths
    /// never substitute for a missing document identity.
    static func capture(items: [SidebarItem], session: ProjectSession,
                        currentDocument: LoadedDocument? = nil) throws -> Request {
        try Task.checkCancellation()
        guard !session.isFilesystemUnavailable else { throw CancellationError() }
        let registeredByID = Dictionary(uniqueKeysWithValues: session.documents.map { ($0.id, $0) })
        var registeredDocuments: [LoadedDocument] = []
        var pending: [PendingSource] = []

        func captureDocument(_ document: LoadedDocument) throws -> PendingSource {
            // A previous native viewport may remain visible while a different
            // project is accepted. Its record cannot inherit the new root.
            if document.projectSequenceID != nil, registeredByID[document.id] !== document {
                throw CaptureError.staleDocument(document.name)
            }
            if registeredByID[document.id] === document { registeredDocuments.append(document) }
            let metadata = Metadata(kind: document.projectSequenceID == nil ? .openDocument : .nativeProjectSequence,
                url: document.url, documentID: document.id, nativeSequenceID: document.projectSequenceID,
                projectURL: document.projectSequenceID == nil ? nil : session.projectURL)
            if document.projectSequenceID != nil, document.sequences.isEmpty {
                guard registeredByID[document.id] === document,
                      let project = session.project, let worker = session.hydrationWorker else {
                    throw CaptureError.unavailableNativeDocument(document.name)
                }
                return .native(metadata, document.name, project.hydrationStore, worker, session.hydrationLoader)
            }
            return .value(Source(metadata: metadata, document: SequenceExportDocumentSnapshot(
                name: document.name, url: document.url, sequences: document.sequences, annotations: document.annotations)))
        }

        if items.isEmpty, let currentDocument {
            pending.append(try captureDocument(currentDocument))
        } else {
            for item in items {
                if let rawID = item.userInfo["documentID"] {
                    guard let id = UUID(uuidString: rawID),
                          let document = registeredByID[id] ?? (currentDocument?.id == id ? currentDocument : nil) else {
                        throw CaptureError.staleDocument(item.title)
                    }
                    pending.append(try captureDocument(document))
                } else if let currentDocument,
                          SidebarExportSelection.matchesLoadedDocument(item, url: currentDocument.url,
                            id: currentDocument.id, nativeSequenceID: currentDocument.projectSequenceID) {
                    pending.append(try captureDocument(currentDocument))
                } else {
                    guard let url = item.url else { throw CaptureError.missingFileURL(item.title) }
                    pending.append(.value(Source(metadata: Metadata(kind: .filesystem, url: url,
                        documentID: nil, nativeSequenceID: nil, projectURL: nil), document: nil)))
                }
            }
        }
        return Request(session: session, generation: session.documentGeneration,
            registeredDocuments: registeredDocuments, pending: pending)
    }
}
