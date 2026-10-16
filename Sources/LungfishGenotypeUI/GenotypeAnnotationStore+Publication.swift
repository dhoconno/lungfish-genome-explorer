import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os

extension GenotypeAnnotationStore {
    func transactAnnotationPublication(
        _ prepare: (GenotypeAnnotationPublicationSnapshot) throws -> GenotypeAnnotationPublicationPayload?
    ) throws -> GenotypeAnnotationPublicationPayload? {
        return try annotationPublicationCoordinator().transact { snapshot in
            guard let payload = try prepare(snapshot) else { return nil }
            // The coordinator writes the pair next, on this thread and inside this transaction.
            reportPublicationStage(.write)
            return payload
        }
    }

    /// Publishes the whole sidecar the analyst sees in one write, with the derived id of each smart cohort
    /// that stores none (plan decision G2). The built-in smart cohorts that are only in memory go out with
    /// the edit, because the file is checked against `lastPersistedSidecar` and not against `sidecar`.
    func persist(action: String, editContext: ProvenanceEditContext? = nil) throws {
        guard !isReadOnly else { return }
        let runClock = ProvenanceRunClock()
        var desiredSidecar = sidecar.storingSmartCohortIDs()
        do {
            try desiredSidecar.promoteToCurrentSchema()
        } catch {
            adoptPersisted(lastPersistedSidecar)
            throw error
        }
        var latestForRollback = lastPersistedSidecar
        do {
            _ = try transactAnnotationPublication { snapshot in
                var latest = try decodedLatestSidecar(from: snapshot.annotationData)
                latestForRollback = latest
                guard latest == lastPersistedSidecar else {
                    throw GenotypeAnnotationStorePersistenceError.staleRevision
                }
                try latest.promoteToCurrentSchema()
                return try annotationPublicationPayload(
                    sidecar: desiredSidecar,
                    action: action,
                    editContext: editContext,
                    snapshot: snapshot,
                    startedAt: runClock.startedAt,
                    endedAt: runClock.now
                )
            }
            sidecar = desiredSidecar
            lastPersistedSidecar = desiredSidecar
            unsavedBuiltInSmartCohorts = []
        } catch {
            adoptPersisted(latestForRollback)
            throw error
        }
    }

    private func annotationPublicationCoordinator() -> GenotypeAnnotationPublicationCoordinator {
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        return GenotypeAnnotationPublicationCoordinator(
            bundleURL: bundleURL,
            annotationFilename: annotationURL.lastPathComponent,
            provenanceFilename: ProvenanceRecorder.fileSidecarURL(for: annotationURL).lastPathComponent,
            faultInjector: publicationFaultInjector
        )
    }

    /// Reports one step of a publication to the stage hook with whether it runs on the main thread.
    /// It is nonisolated, so a step that runs away from the main actor reports its own thread.
    nonisolated func reportPublicationStage(_ stage: GenotypeAnnotationPublicationStage) {
        publicationStageObserver?(GenotypeAnnotationPublicationStageEvent(
            stage: stage,
            onMainThread: Thread.isMainThread
        ))
    }
}

/// A step of a genotype annotation publication that the stage hook reports (2.11 S35, SWIFT SC3).
enum GenotypeAnnotationPublicationStage: String, Sendable {
    /// Encoding `annotations.json` for the payload.
    case encode
    /// Hashing bytes that the record names.
    case digest
    /// Writing the pair, reported on the thread that writes, just before the coordinator writes it.
    case write
}

/// One report of the stage hook.
struct GenotypeAnnotationPublicationStageEvent: Equatable, Sendable {
    let stage: GenotypeAnnotationPublicationStage
    let onMainThread: Bool
}

typealias GenotypeAnnotationPublicationStageObserver =
    @Sendable (GenotypeAnnotationPublicationStageEvent) -> Void

/// The hook a store reports to when its creator passes none. A Debug build logs each step with its
/// thread to the unified log, subsystem `com.lungfish.app` and category
/// `GenotypeAnnotationPublication`, which a GUI walk reads. A Release build reports nowhere.
enum GenotypeAnnotationPublicationStageLog {
    #if DEBUG
    private static let logger = Logger(subsystem: LogSubsystem.app, category: "GenotypeAnnotationPublication")

    static let defaultObserver: GenotypeAnnotationPublicationStageObserver? = { event in
        let thread = event.onMainThread ? "main" : "background"
        GenotypeAnnotationPublicationStageLog.logger.notice(
            "genotype annotation publication stage=\(event.stage.rawValue, privacy: .public) thread=\(thread, privacy: .public)"
        )
    }
    #else
    static let defaultObserver: GenotypeAnnotationPublicationStageObserver? = nil
    #endif
}
