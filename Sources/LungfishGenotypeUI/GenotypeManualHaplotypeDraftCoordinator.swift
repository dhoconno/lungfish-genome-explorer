import Foundation

public enum GenotypeManualHaplotypeDraftDecision: Equatable, Sendable {
    case save
    case discard
    case cancel
}

/// Serializes every transition that could abandon an in-memory manual
/// haplotype draft. A pending prompt is shared by repeated close/quit or
/// navigation requests so the analyst is never presented with overlapping
/// decisions for the same draft.
@MainActor
public final class GenotypeManualHaplotypeDraftCoordinator {
    public enum Transition: String, CaseIterable, Equatable, Sendable {
        case selection
        case search
        case filter
        case visibility
        case lens
        case reload
        case bundleSwitch
        case projectSwitch
        case windowClose
        case appQuit
        case eligibilityChange
    }

    private let hasUnsavedChanges: @MainActor () -> Bool
    private let save: @MainActor () async -> Bool
    private let prepareSave: @MainActor () async -> Bool
    private let finalizePreparedSave: @MainActor () -> Void
    private let cancelPreparedSave: @MainActor () -> Void
    private let discard: @MainActor () async -> Bool
    private var pendingDecision:
        Task<Resolution, Never>?
    private var pendingDecisionTransition: Transition?
    private var outstandingResolution: Resolution?
    private var pendingCommit:
        Task<(generation: UInt64, allowed: Bool), Never>?
    private var lastCommitted:
        (generation: UInt64, allowed: Bool)?
    private var resolutionGeneration: UInt64 = 0
    private var preparedSaveGeneration: UInt64?

    public struct Resolution: Equatable, Sendable {
        public let decision: GenotypeManualHaplotypeDraftDecision?
        public let transition: Transition?
        fileprivate let generation: UInt64

        fileprivate init(
            decision: GenotypeManualHaplotypeDraftDecision?,
            transition: Transition?,
            generation: UInt64
        ) {
            self.decision = decision
            self.transition = transition
            self.generation = generation
        }
    }

    public init(
        hasUnsavedChanges: @escaping @MainActor () -> Bool,
        save: @escaping @MainActor () async -> Bool,
        discard: @escaping @MainActor () async -> Bool
    ) {
        self.hasUnsavedChanges = hasUnsavedChanges
        self.save = save
        self.prepareSave = save
        self.finalizePreparedSave = {}
        self.cancelPreparedSave = {}
        self.discard = discard
    }

    public init(
        hasUnsavedChanges: @escaping @MainActor () -> Bool,
        save: @escaping @MainActor () async -> Bool,
        prepareSave: @escaping @MainActor () async -> Bool,
        finalizePreparedSave: @escaping @MainActor () -> Void,
        cancelPreparedSave: @escaping @MainActor () -> Void,
        discard: @escaping @MainActor () async -> Bool
    ) {
        self.hasUnsavedChanges = hasUnsavedChanges
        self.save = save
        self.prepareSave = prepareSave
        self.finalizePreparedSave = finalizePreparedSave
        self.cancelPreparedSave = cancelPreparedSave
        self.discard = discard
    }

    public var hasPendingResolution: Bool {
        pendingDecision != nil
            || outstandingResolution != nil
            || pendingCommit != nil
    }

    public var hasUnsavedDraft: Bool {
        hasUnsavedChanges()
    }

    public func prepare(
        for transition: Transition,
        decision: @escaping @MainActor ()
            async -> GenotypeManualHaplotypeDraftDecision
    ) async -> Bool {
        let resolution = await resolve(
            for: transition,
            decision: decision
        )
        return await commit(resolution)
    }

    public func resolve(
        for transition: Transition,
        decision: @escaping @MainActor ()
            async -> GenotypeManualHaplotypeDraftDecision
    ) async -> Resolution {
        if let outstandingResolution {
            guard outstandingResolution.transition == transition else {
                return Resolution(
                    decision: .cancel,
                    transition: transition,
                    generation: 0
                )
            }
            return outstandingResolution
        }
        if let pendingDecision {
            guard pendingDecisionTransition == transition else {
                return Resolution(
                    decision: .cancel,
                    transition: transition,
                    generation: 0
                )
            }
            let resolution = await pendingDecision.value
            return resolution
        }
        guard hasUnsavedChanges() else {
            return Resolution(
                decision: nil,
                transition: transition,
                generation: 0
            )
        }

        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        let task = Task { @MainActor in
            Resolution(
                decision: await decision(),
                transition: transition,
                generation: generation
            )
        }
        pendingDecision = task
        pendingDecisionTransition = transition
        let resolution = await task.value
        if resolutionGeneration == generation {
            pendingDecision = nil
            pendingDecisionTransition = nil
            outstandingResolution = resolution
        }
        return resolution
    }

    public func commit(_ resolution: Resolution) async -> Bool {
        guard let decision = resolution.decision else { return true }
        guard resolution.generation != 0 else {
            return false
        }
        if let lastCommitted,
           lastCommitted.generation == resolution.generation {
            return lastCommitted.allowed
        }
        guard outstandingResolution == resolution else {
            return false
        }
        if let pendingCommit {
            let committed = await pendingCommit.value
            if committed.generation == resolution.generation {
                return committed.allowed
            }
        }

        let save = self.save
        let discard = self.discard
        let generation = resolution.generation
        let task = Task { @MainActor in
            let allowed: Bool
            switch decision {
            case .save:
                allowed = await save()
            case .discard:
                allowed = await discard()
            case .cancel:
                allowed = false
            }
            return (generation: generation, allowed: allowed)
        }
        pendingCommit = task
        let committed = await task.value
        if resolutionGeneration == generation {
            pendingCommit = nil
            outstandingResolution = nil
            lastCommitted = committed
        }
        return committed.allowed
    }

    public func prepareTransactionalCommit(
        _ resolution: Resolution
    ) async -> Bool {
        guard resolution.decision != .cancel else { return false }
        guard resolution.decision != nil else { return true }
        guard resolution.generation != 0,
              outstandingResolution == resolution else {
            return false
        }
        guard resolution.decision == .save else { return true }
        if preparedSaveGeneration == resolution.generation {
            return true
        }
        guard await prepareSave() else { return false }
        preparedSaveGeneration = resolution.generation
        return true
    }

    public func finalizeTransactionalCommit(
        _ resolution: Resolution
    ) async -> Bool {
        guard let decision = resolution.decision else { return true }
        guard resolution.generation != 0,
              outstandingResolution == resolution else {
            return false
        }
        let allowed: Bool
        switch decision {
        case .save:
            guard preparedSaveGeneration == resolution.generation else {
                return false
            }
            finalizePreparedSave()
            preparedSaveGeneration = nil
            allowed = true
        case .discard:
            allowed = await discard()
        case .cancel:
            allowed = false
        }
        outstandingResolution = nil
        lastCommitted = (
            generation: resolution.generation,
            allowed: allowed
        )
        return allowed
    }

    public func cancelTransactionalCommit(_ resolution: Resolution) {
        if preparedSaveGeneration == resolution.generation {
            cancelPreparedSave()
            preparedSaveGeneration = nil
        }
        abandon(resolution)
    }

    public func abandon(_ resolution: Resolution) {
        guard resolution.generation != 0 else { return }
        if outstandingResolution == resolution {
            outstandingResolution = nil
        }
    }
}

/// Retains at most one transition mutation while a draft decision is pending.
/// Newer user intent replaces older intent, so a shared prompt cannot release
/// several stale selection, filter, reload, or configuration closures.
@MainActor
public final class GenotypeManualHaplotypeTransitionMutationCoordinator {
    private struct PendingMutation {
        let generation: UInt64
        let transition:
            GenotypeManualHaplotypeDraftCoordinator.Transition
        let mutation: @MainActor () -> Void
    }

    private var nextGeneration: UInt64 = 0
    private var pendingMutation: PendingMutation?
    private var resolutionTask: Task<Void, Never>?

    public init() {}

    public var retainedMutationCount: Int {
        pendingMutation == nil ? 0 : 1
    }

    public var hasPendingMutation: Bool {
        pendingMutation != nil || resolutionTask != nil
    }

    public func enqueue(
        transition: GenotypeManualHaplotypeDraftCoordinator.Transition,
        prepare: @escaping @MainActor (
            GenotypeManualHaplotypeDraftCoordinator.Transition
        ) async -> Bool,
        mutation: @escaping @MainActor () -> Void
    ) {
        nextGeneration &+= 1
        pendingMutation = PendingMutation(
            generation: nextGeneration,
            transition: transition,
            mutation: mutation
        )
        guard resolutionTask == nil else { return }
        let promptingTransition = transition
        resolutionTask = Task { @MainActor [weak self] in
            let allowed = await prepare(promptingTransition)
            guard let self else { return }
            self.resolutionTask = nil
            guard let latest = self.pendingMutation else { return }
            self.pendingMutation = nil
            guard allowed,
                  latest.generation == self.nextGeneration else {
                return
            }
            latest.mutation()
        }
    }
}
