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
    private var pendingResolution: Task<Bool, Never>?
    private var pendingResolutionGeneration: UInt64 = 0

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
        pendingResolution != nil
    }

    public var hasUnsavedDraft: Bool {
        hasUnsavedChanges()
    }

    public func prepare(
        for transition: Transition,
        decision: @escaping @MainActor ()
            async -> GenotypeManualHaplotypeDraftDecision
    ) async -> Bool {
        _ = transition
        guard hasUnsavedChanges() else { return true }
        if let pendingResolution {
            return await pendingResolution.value
        }

        pendingResolutionGeneration &+= 1
        let generation = pendingResolutionGeneration
        let save = self.save
        let discard = self.discard
        let task = Task { @MainActor in
            switch await decision() {
            case .save:
                return await save()
            case .discard:
                return await discard()
            case .cancel:
                return false
            }
        }
        pendingResolution = task
        let allowed = await task.value
        if pendingResolutionGeneration == generation {
            pendingResolution = nil
        }
        return allowed
    }
}
