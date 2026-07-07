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

        let filename = try manager.addAttachment(from: sourceURL)
        let destinationURL = manager.urlForAttachment(filename)
        do {
            try rehydrateScientificSidecar(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                scientificFormat: scientificFormat
            )
            return filename
        } catch {
            try? FileManager.default.removeItem(at: ProvenanceRecorder.fileSidecarURL(for: destinationURL))
            try? manager.removeAttachment(filename)
            throw error
        }
    }

    private static func copyScientificAttachmentWithSidecar(
        sourceURL: URL,
        destinationURL: URL,
        scientificFormat: String
    ) throws {
        let fileManager = FileManager.default
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: destinationURL)
        let token = UUID().uuidString
        let backupURL = destinationDirectory.appendingPathComponent(".\(destinationURL.lastPathComponent).\(token).attachment-backup")
        let sidecarBackupURL = destinationDirectory.appendingPathComponent(".\(sidecarURL.lastPathComponent).\(token).attachment-backup")
        var didBackupPayload = false
        var didBackupSidecar = false

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.moveItem(at: destinationURL, to: backupURL)
                didBackupPayload = true
            }
            if fileManager.fileExists(atPath: sidecarURL.path) {
                try fileManager.moveItem(at: sidecarURL, to: sidecarBackupURL)
                didBackupSidecar = true
            }

            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try rehydrateScientificSidecar(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                scientificFormat: scientificFormat
            )

            try? fileManager.removeItem(at: backupURL)
            try? fileManager.removeItem(at: sidecarBackupURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            try? fileManager.removeItem(at: sidecarURL)
            if didBackupPayload {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
            }
            if didBackupSidecar {
                try? fileManager.moveItem(at: sidecarBackupURL, to: sidecarURL)
            }
            throw error
        }
    }

    private static func rehydrateScientificSidecar(
        sourceURL: URL,
        destinationURL: URL,
        scientificFormat: String
    ) throws {
        do {
            try GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar(
                from: sourceURL,
                to: destinationURL
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
