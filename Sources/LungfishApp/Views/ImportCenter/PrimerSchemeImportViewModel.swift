// PrimerSchemeImportViewModel.swift - Import Center view model for user-authored primer schemes
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow
import Observation

/// View model that writes a user-authored `.lungfishprimers` bundle from a BED
/// file (and optional FASTA + attachments) into the active project's
/// `Primer Schemes/` folder.
///
/// Separate from ``BuiltInPrimerSchemeService``: this writes to the project,
/// not the shipped Resources bundle. The user edits the canonical accession,
/// display name, and any equivalents; the view model parses primer/amplicon
/// counts from column 4 of the BED.
@MainActor
@Observable
final class PrimerSchemeImportViewModel {
    /// Result returned to the Import Center when an import succeeds.
    public struct ImportResult: Sendable {
        public let bundleURL: URL
    }

    /// Errors thrown by ``performImport``.
    public enum ImportError: Error, LocalizedError, Sendable {
        case bedUnreadable(underlying: Error & Sendable)
        case emptyName
        case emptyCanonical
        case bundleAlreadyExists(name: String, url: URL)
        case copyFailed(path: String, underlying: Error & Sendable)
        case writeFailed(underlying: Error & Sendable)

        public var errorDescription: String? {
            switch self {
            case .bedUnreadable(let underlying):
                return "Could not read the primer BED: \(underlying.localizedDescription)"
            case .emptyName:
                return "Give the primer scheme a file-safe name."
            case .emptyCanonical:
                return "Enter the canonical reference accession (e.g., MN908947.3)."
            case .bundleAlreadyExists(let name, _):
                return "A primer scheme named \(name) already exists in this project."
            case .copyFailed(let path, let underlying):
                return "Failed to copy \(path): \(underlying.localizedDescription)"
            case .writeFailed(let underlying):
                return "Failed to write the primer-scheme bundle: \(underlying.localizedDescription)"
            }
        }
    }

    public init() {}

    /// Writes a primer-scheme bundle into `projectURL/Primer Schemes/<name>.lungfishprimers`.
    ///
    /// - Parameters:
    ///   - bedURL: Required BED file describing primer coordinates.
    ///   - fastaURL: Optional primer-sequences FASTA; bundled as `primers.fasta` when present.
    ///   - attachments: Optional extra files copied under `attachments/`.
    ///   - name: File-safe bundle name (slashes are replaced with underscores).
    ///   - displayName: Human-readable name shown in pickers.
    ///   - canonicalAccession: Reference accession the BED's column 1 is anchored to.
    ///   - equivalentAccessions: Additional accessions the resolver may rewrite to.
    ///   - projectURL: The currently open project's folder.
    public func performImport(
        bedURL: URL,
        fastaURL: URL?,
        attachments: [URL],
        name: String,
        displayName: String,
        canonicalAccession: String,
        equivalentAccessions: [String],
        projectURL: URL
    ) throws -> ImportResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCanonical = canonicalAccession.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ImportError.emptyName }
        guard !trimmedCanonical.isEmpty else { throw ImportError.emptyCanonical }

        let safeName = trimmedName.replacingOccurrences(of: "/", with: "_")
        let outputURL = URL(fileURLWithPath: "\(safeName).lungfishprimers")
        do {
            let result = try PrimerSchemeImportService.importBundle(
                request: PrimerSchemeImportRequest(
                    bedURL: bedURL,
                    fastaURL: fastaURL,
                    attachments: attachments,
                    outputURL: outputURL,
                    projectURL: projectURL,
                    displayName: displayName.isEmpty ? safeName : displayName,
                    canonicalAccession: trimmedCanonical,
                    equivalentAccessions: equivalentAccessions,
                    argv: [
                        "Lungfish", "Import Center", "Primer Scheme Import",
                        "--bed", bedURL.path,
                        "--fasta", fastaURL?.path ?? "",
                        "--output", outputURL.path,
                        "--project", projectURL.path,
                        "--reference-accession", trimmedCanonical,
                    ].filter { !$0.isEmpty },
                    workflowName: "Lungfish Import Center primer scheme import",
                    toolVersion: WorkflowRun.currentAppVersion
                )
            )
            return ImportResult(bundleURL: result.bundleURL)
        } catch let error as PrimerSchemeImportError {
            switch error {
            case .unreadableBED:
                throw ImportError.bedUnreadable(underlying: error as NSError)
            case .bundleAlreadyExists(let url):
                throw ImportError.bundleAlreadyExists(name: safeName, url: url)
            case .writeFailed:
                throw ImportError.writeFailed(underlying: error as NSError)
            default:
                throw ImportError.copyFailed(path: outputURL.lastPathComponent, underlying: error as NSError)
            }
        } catch {
            throw ImportError.writeFailed(underlying: error as NSError)
        }
    }

    /// Parses `bedURL` and returns `(primerCount, ampliconCount)`.
    ///
    /// `primerCount` is the number of non-empty, non-comment lines.
    /// `ampliconCount` is the distinct amplicon names — primer names in column 4
    /// with trailing `_LEFT`/`_RIGHT` stripped and any trailing `-N` variant tag removed.
    private static func parseCounts(bedURL: URL) throws -> (primerCount: Int, ampliconCount: Int) {
        try PrimerSchemeImportService.parseCounts(bedURL: bedURL)
    }
}
