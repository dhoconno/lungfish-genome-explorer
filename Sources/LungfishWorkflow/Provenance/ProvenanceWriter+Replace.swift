// ProvenanceWriter+Replace.swift - Record rewrites through DurableReplace and recovery of released asides
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore

extension ProvenanceWriter {
    /// The infix released builds gave the old record while a rewrite was
    /// under way, `.<name>.provenance-displaced-<UUID>`. A crash between that
    /// rename and the publication of the new record left the name empty, and
    /// nothing restored it until this build.
    static let releasedDisplacedInfix = ".provenance-displaced-"

    /// Publishes `data` under `destinationURL` through `DurableReplace`, so
    /// the name holds a complete old or new file at every step (plan
    /// decisions S1 and V1).
    ///
    /// An observer sees the swap as one receipt. The prior state is read from
    /// the old file under its stage name, where the swap moved it with its
    /// inode, and the resulting state from the staged file. When the observer
    /// refuses, the swap is undone, so the old file is back with that inode.
    ///
    /// Without an observer the publication first restores a released
    /// displaced record whose name is empty. With one it does not, because
    /// the observer's snapshot saw the name empty, and the aside copy stays.
    func publishDurably(
        _ data: Data,
        to destinationURL: URL,
        kind: ProvenanceWriterMutation.Kind
    ) throws {
        let observed = publicationMutationDidOccur != nil
        // Receipts are keyed by physical path (CanonicalFilePath) and name
        // the destination as the caller spelled it.
        let receiptKey = destinationURL.canonicalFileURL.path
        var stagedState = ProvenancePublicationArtifactState.missing
        do {
            try DurableReplace.replace(
                data,
                named: destinationURL.lastPathComponent,
                in: destinationURL.deletingLastPathComponent(),
                recovery: observed ? .none : .restoring(asideInfixes: [Self.releasedDisplacedInfix]),
                beforePublish: { stageURL in
                    guard observed else { return }
                    stagedState = try ProvenancePublicationSnapshot.artifactState(
                        at: stageURL,
                        fileManager: .default
                    )
                },
                observe: { publication in
                    guard observed else { return }
                    let priorState = try publication.retiredURL.map {
                        try ProvenancePublicationSnapshot.artifactState(at: $0, fileManager: .default)
                    } ?? .missing
                    do {
                        try reportMutation(ProvenanceWriterMutation(
                            kind: kind,
                            affectedURLs: [destinationURL.standardizedFileURL],
                            requiredPriorStates: [receiptKey: priorState],
                            resultingStates: [receiptKey: stagedState]
                        ))
                    } catch let accepted as ProvenanceWriterMutationAcceptedError {
                        // The enclosing transaction owns restoration now.
                        throw DurableReplace.AcceptedFailure(accepted)
                    }
                }
            )
        } catch let error as DurableReplace.ReplaceError {
            throw Self.writerError(for: error)
        }
    }

    /// Restores a released displaced record when its name holds nothing, and
    /// says whether it did.
    func recoverReleasedRecord(at provenanceURL: URL) throws -> Bool {
        try DurableReplace.recover(
            named: provenanceURL.lastPathComponent,
            in: provenanceURL.deletingLastPathComponent(),
            asideInfixes: [Self.releasedDisplacedInfix]
        ) != nil
    }

    /// The writer's own error for a helper failure that callers already
    /// tell apart.
    private static func writerError(for error: DurableReplace.ReplaceError) -> any Error {
        switch error {
        case .unsafeExistingEntry(let path):
            return ProvenanceWriterError.unsafeExistingArtifact(
                path: path,
                reason: "the existing destination is not a regular file"
            )
        case .rollbackIncomplete(let originalError, _, let retainedPath, let reason):
            return ProvenanceWriterError.exclusivePublicationRollbackFailed(
                originalError: originalError,
                cleanupErrors: [reason],
                preservedQuarantinePaths: [retainedPath]
            )
        case .retiredCopyRetained(let path, let retainedPath, let code):
            return ProvenanceWriterError.exclusivePublicationCleanupFailed(
                path: path,
                quarantinePath: retainedPath,
                reason: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription
            )
        default:
            return error
        }
    }
}
