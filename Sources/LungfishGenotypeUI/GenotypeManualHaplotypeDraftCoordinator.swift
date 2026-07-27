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
    private let discard: @MainActor () async -> Bool
    private var pendingDecision:
        Task<Resolution, Never>?
    private var outstandingResolution: Resolution?
    private var pendingCommit:
        Task<(generation: UInt64, allowed: Bool), Never>?
    private var lastCommitted:
        (generation: UInt64, allowed: Bool)?
    private var resolutionGeneration: UInt64 = 0

    public struct Resolution: Equatable, Sendable {
        public let decision: GenotypeManualHaplotypeDraftDecision?
        fileprivate let generation: UInt64

        fileprivate init(
            decision: GenotypeManualHaplotypeDraftDecision?,
            generation: UInt64
        ) {
            self.decision = decision
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
        _ = transition
        guard hasUnsavedChanges() else {
            return Resolution(decision: nil, generation: 0)
        }
        if let outstandingResolution {
            return outstandingResolution
        }
        if let pendingDecision {
            return await pendingDecision.value
        }

        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        let task = Task { @MainActor in
            Resolution(
                decision: await decision(),
                generation: generation
            )
        }
        pendingDecision = task
        let resolution = await task.value
        if resolutionGeneration == generation {
            pendingDecision = nil
            outstandingResolution = resolution
        }
        return resolution
    }

    public func commit(_ resolution: Resolution) async -> Bool {
        guard let decision = resolution.decision else { return true }
        if let lastCommitted,
           lastCommitted.generation == resolution.generation {
            return lastCommitted.allowed
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

    public func abandon(_ resolution: Resolution) {
        guard resolution.generation != 0 else { return }
        if outstandingResolution?.generation == resolution.generation {
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
