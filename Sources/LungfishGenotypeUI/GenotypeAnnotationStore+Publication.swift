import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os

extension GenotypeAnnotationStore {
    /// Publishes the pair on the main actor. Only the two replayed edits use it, because their
    /// editors still call them synchronously (2.11 S35 M2a). Outside a step of the chain it refuses
    /// while a step publishes, since this store has not adopted that step's result yet.
    func transactAnnotationPublication(
        _ prepare: (GenotypeAnnotationPublicationSnapshot) throws -> GenotypeAnnotationPublicationPayload?
    ) throws -> GenotypeAnnotationPublicationPayload? {
        guard publicationChain.isIdle || GenotypeAnnotationPublicationStepScope.isInside else {
            throw GenotypeAnnotationStorePersistenceError.publicationInFlight
        }
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
    /// The pair is encoded, hashed and written on a background thread, and the result is adopted here
    /// on the main actor (2.11 S35, plan S2).
    func persist(action: String, editContext: ProvenanceEditContext? = nil) async throws {
        guard !isReadOnly else { return }
        let runClock = ProvenanceRunClock()
        var desiredSidecar = sidecar.storingSmartCohortIDs()
        do {
            try desiredSidecar.promoteToCurrentSchema()
        } catch {
            adoptPersisted(lastPersistedSidecar)
            throw error
        }
        let desired = desiredSidecar
        let expected = lastPersistedSidecar
        let unsaved = unsavedBuiltInSmartCohorts
        let outcome = await publishAwayFromMainActor(expected: expected) { [self] snapshot, latest in
            guard latest == expected else {
                throw GenotypeAnnotationStorePersistenceError.staleRevision
            }
            var promoted = latest
            try promoted.promoteToCurrentSchema()
            let payload = try annotationPublicationPayload(
                sidecar: desired,
                action: action,
                editContext: editContext,
                snapshot: snapshot,
                unsavedBuiltInSmartCohorts: unsaved,
                startedAt: runClock.startedAt,
                endedAt: runClock.now
            )
            return GenotypeAnnotationPublicationStep(payload: payload, published: desired, value: ())
        }
        switch outcome.result {
        case .success:
            sidecar = desired
            lastPersistedSidecar = desired
            unsavedBuiltInSmartCohorts = []
        case .failure(let error):
            adoptPersisted(outcome.latest ?? expected)
            throw error
        }
    }

    /// `persist` on the main actor, for `publishViewedSidecar`, which the two replayed edits call
    /// synchronously before their own publication.
    func persistOnMainActor(action: String, editContext: ProvenanceEditContext? = nil) throws {
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
                    unsavedBuiltInSmartCohorts: unsavedBuiltInSmartCohorts,
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

    /// Runs one transaction of the pair on a background thread (2.11 S35, plan S2). `prepare` runs
    /// inside the bundle's publication lock with the bytes the bundle holds and the sidecar they
    /// decode to, and builds the payload there. The outcome carries that sidecar, which a refused
    /// edit adopts.
    func publishAwayFromMainActor<Value: Sendable>(
        expected: GenotypeAnnotationSidecar,
        _ prepare: @escaping @Sendable (GenotypeAnnotationPublicationSnapshot, GenotypeAnnotationSidecar) throws
            -> GenotypeAnnotationPublicationStep<Value>
    ) async -> GenotypeAnnotationPublicationOutcome<Value> {
        let emptyGeneratedAt = expected.generatedAt
        return await Task.detached(priority: .userInitiated) { [self] in
            var latest: GenotypeAnnotationSidecar?
            var prepared: GenotypeAnnotationPublicationStep<Value>?
            do {
                _ = try annotationPublicationCoordinator().transact { snapshot in
                    let decoded = try Self.decodedLatestSidecar(
                        from: snapshot.annotationData,
                        emptyGeneratedAt: emptyGeneratedAt
                    )
                    latest = decoded
                    let step = try prepare(snapshot, decoded)
                    prepared = step
                    guard let payload = step.payload else { return nil }
                    // The coordinator writes the pair next, on this thread and inside this transaction.
                    reportPublicationStage(.write)
                    return payload
                }
                guard let prepared else { preconditionFailure("A finished transaction ran its prepare.") }
                return GenotypeAnnotationPublicationOutcome(latest: latest, result: .success(prepared))
            } catch {
                return GenotypeAnnotationPublicationOutcome(latest: latest, result: .failure(error))
            }
        }.value
    }

    nonisolated static func decodedLatestSidecar(
        from data: Data?,
        emptyGeneratedAt: String
    ) throws -> GenotypeAnnotationSidecar {
        guard let data else { return GenotypeAnnotationSidecar.empty(generatedAt: emptyGeneratedAt) }
        return try GenotypeAnnotationSidecar.decode(data)
    }

    /// Starts an edit from the edge of the UI (2.11 S35, plan S2). The edit starts in this event's
    /// turn, so it takes its place on the chain in the order the person made it, and the edit
    /// controls hold until it ends. `onFailure` gets a refusal on the main actor.
    func beginEdit(
        _ edit: @escaping @MainActor () async throws -> Void,
        onFailure: @escaping @MainActor (any Error) -> Void
    ) {
        publicationChain.beginEdit(edit, onFailure: onFailure)
    }

    /// Whether an edit the UI started is still publishing, which holds the edit controls.
    var isHoldingEdits: Bool { publicationChain.isHoldingEdits }

    /// Returns once every edit the UI started on this store has ended.
    func waitForEdits() async {
        await publicationChain.waitForEdits()
    }

    private nonisolated func annotationPublicationCoordinator() -> GenotypeAnnotationPublicationCoordinator {
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

/// What one publication writes and returns, built away from the main actor (2.11 S35).
struct GenotypeAnnotationPublicationStep<Value: Sendable>: Sendable {
    /// The pair to write, or nil when the edit writes nothing.
    var payload: GenotypeAnnotationPublicationPayload?
    /// The sidecar the store adopts once the pair is written, or nil when it keeps its own.
    var published: GenotypeAnnotationSidecar?
    var value: Value
}

/// How a transaction away from the main actor ended, with the sidecar the bundle held when it ran.
struct GenotypeAnnotationPublicationOutcome<Value: Sendable>: Sendable {
    var latest: GenotypeAnnotationSidecar?
    var result: Result<GenotypeAnnotationPublicationStep<Value>, any Error>
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
