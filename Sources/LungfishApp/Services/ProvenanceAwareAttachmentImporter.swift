// ProvenanceAwareAttachmentImporter.swift - Generic attachment import with scientific provenance guardrails
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum ProvenanceAwareAttachmentImporter {
    @discardableResult
    static func attach(fileAt sourceURL: URL, to store: BundleAttachmentStore) throws -> String {
        guard let scientificFormat = GenericAttachmentPolicy.scientificFormatDescription(
            forFilename: sourceURL.lastPathComponent
        ) else {
            try store.attach(fileAt: sourceURL)
            return sourceURL.lastPathComponent
        }

        let filename = sourceURL.lastPathComponent
        let destinationURL = store.urlForAttachment(filename)
        try copyScientificAttachmentWithSidecar(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            scientificFormat: scientificFormat
        )
        store.reload()
        return filename
    }

    @discardableResult
    static func addAttachment(from sourceURL: URL, using manager: BundleAttachmentManager) throws -> String {
        guard let scientificFormat = GenericAttachmentPolicy.scientificFormatDescription(
            forFilename: sourceURL.lastPathComponent
        ) else {
            return try manager.addAttachment(from: sourceURL)
        }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var filename = sourceURL.lastPathComponent
        var counter = 2
        while FileManager.default.fileExists(atPath: manager.urlForAttachment(filename).path) {
            filename = ext.isEmpty ? "\(baseName)-\(counter)" : "\(baseName)-\(counter).\(ext)"
            counter += 1
        }
        try copyScientificAttachmentWithSidecar(sourceURL: sourceURL,
            destinationURL: manager.urlForAttachment(filename), scientificFormat: scientificFormat,
            replacingExisting: false)
        return filename
    }

    private static func copyScientificAttachmentWithSidecar(
        sourceURL: URL,
        destinationURL: URL,
        scientificFormat: String,
        replacingExisting: Bool = true
    ) throws {
        guard sourceURL.resolvingSymlinksInPath().standardizedFileURL != destinationURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw CocoaError(.fileWriteFileExists)
        }
        let fileManager = FileManager.default
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifacts = [destinationURL] + ProvenancePublicationArtifacts.fileSidecarArtifacts(for: destinationURL)
        let publication = try ScientificFilePublicationTransaction(protectedURLs: artifacts, fileDestinations: artifacts)
        let staged = directory.appendingPathComponent(".attachment-\(UUID())")
        defer { try? fileManager.removeItem(at: staged) }
        do {
            try fileManager.copyItem(at: sourceURL, to: staged)
            try publication.publish(stagedURL: staged, to: destinationURL, replacingExisting: replacingExisting)
            try rehydrateScientificSidecar(sourceURL: sourceURL, destinationURL: destinationURL,
                scientificFormat: scientificFormat,
                provenanceWriter: ProvenanceWriter(publicationMutationDidOccur: { try publication.observe($0) }, signingProvider: nil))
            publication.commit()
        } catch {
            try publication.rollback(after: error)
        }
    }

    private static func rehydrateScientificSidecar(
        sourceURL: URL,
        destinationURL: URL,
        scientificFormat: String,
        provenanceWriter: ProvenanceWriter
    ) throws {
        do {
            try GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar(
                from: sourceURL,
                to: destinationURL,
                provenanceWriter: provenanceWriter
            )
        } catch GUIImportedProvenanceRehydratorError.unsupportedSourceProvenance {
            throw GenericAttachmentValidationError.scientificDataRequiresImportWorkflow(
                filename: sourceURL.lastPathComponent,
                formatDescription: scientificFormat
            )
        } catch GUIImportedProvenanceRehydratorError.sourceOutputIntegrityMissing {
            throw GenericAttachmentValidationError.scientificDataRequiresImportWorkflow(
                filename: sourceURL.lastPathComponent,
                formatDescription: scientificFormat
            )
        } catch GUIImportedProvenanceRehydratorError.sourceOutputIntegrityMismatch {
            throw GenericAttachmentValidationError.scientificDataRequiresImportWorkflow(
                filename: sourceURL.lastPathComponent,
                formatDescription: scientificFormat
            )
        } catch ProvenanceRehydrationError.missingSourceProvenance {
            throw GenericAttachmentValidationError.scientificDataRequiresImportWorkflow(
                filename: sourceURL.lastPathComponent,
                formatDescription: scientificFormat
            )
        } catch ProvenanceRehydrationError.outputPathNotMapped {
            throw GenericAttachmentValidationError.scientificDataRequiresImportWorkflow(
                filename: sourceURL.lastPathComponent,
                formatDescription: scientificFormat
            )
        } catch {
            throw error
        }
    }
}
