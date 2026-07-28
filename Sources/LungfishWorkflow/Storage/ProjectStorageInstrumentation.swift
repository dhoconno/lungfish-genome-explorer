import Foundation
import LungfishCore
import os

public struct ProjectStorageInstrumentation: Sendable {
    public enum Phase: String, Equatable, Sendable {
        case scan = "ProjectStorage.Scan"
        case descriptorPreparation = "ProjectStorage.DescriptorPreparation"
        case mainActorCommit = "ProjectStorage.MainActorCommit"
    }

    public enum Outcome: String, Equatable, Sendable {
        case success
        case cancelled
        case failure
    }

    public enum Counter: String, Equatable, Sendable {
        case visitedObjects
        case candidateEntries
        case trackedHardLinkIdentities
        case retainedScannerRecords
        case reusedHashes
        case computedHashes
        case mainActorCommits
    }

    public struct Interval: Sendable, Equatable {
        public let id: UUID
        public let phase: Phase

        init(id: UUID = UUID(), phase: Phase) {
            self.id = id
            self.phase = phase
        }
    }

    public enum Event: Equatable, Sendable {
        case began(Interval)
        case counted(Counter, UInt64, intervalID: UUID)
        case ended(Interval, Outcome)
    }

    private let recording: @Sendable (Event) -> Void
    private let lifecycle: InstrumentationIntervalLifecycle

    public init(
        record: @escaping @Sendable (Event) -> Void
    ) {
        self.recording = record
        self.lifecycle = InstrumentationIntervalLifecycle()
    }

    public func begin(_ phase: Phase) -> Interval {
        let interval = Interval(phase: phase)
        lifecycle.begin(interval.id)
        recording(.began(interval))
        return interval
    }

    public func count(
        _ counter: Counter,
        _ value: UInt64,
        in interval: Interval
    ) {
        recording(.counted(counter, value, intervalID: interval.id))
    }

    public func end(
        _ interval: Interval,
        outcome: Outcome
    ) {
        guard lifecycle.finish(interval.id) else { return }
        recording(.ended(interval, outcome))
    }

    public static func production(
        subsystem: String
    ) -> ProjectStorageInstrumentation {
        let recorder = ProductionRecorder(subsystem: subsystem)
        return .init(record: recorder.record)
    }
}

private final class InstrumentationIntervalLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var active: Set<UUID> = []

    func begin(_ id: UUID) {
        lock.withLock {
            _ = active.insert(id)
        }
    }

    func finish(_ id: UUID) -> Bool {
        lock.withLock {
            active.remove(id) != nil
        }
    }
}

private final class ProductionRecorder: @unchecked Sendable {
    private let signposter: OSSignposter
    private let lock = NSLock()
    private var states: [UUID: OSSignpostIntervalState] = [:]

    init(subsystem: String) {
        signposter = OSSignposter(
            subsystem: subsystem,
            category: "ProjectStorage"
        )
    }

    func record(_ event: ProjectStorageInstrumentation.Event) {
        switch event {
        case .began(let interval):
            begin(interval)
        case .counted(let counter, let value, _):
            emit(counter, value: value)
        case .ended(let interval, let outcome):
            end(interval, outcome: outcome)
        }
    }

    private func begin(_ interval: ProjectStorageInstrumentation.Interval) {
        let id = signposter.makeSignpostID()
        let state: OSSignpostIntervalState
        switch interval.phase {
        case .scan:
            state = signposter.beginInterval("ProjectStorage.Scan", id: id)
        case .descriptorPreparation:
            state = signposter.beginInterval(
                "ProjectStorage.DescriptorPreparation",
                id: id
            )
        case .mainActorCommit:
            state = signposter.beginInterval(
                "ProjectStorage.MainActorCommit",
                id: id
            )
        }
        lock.withLock {
            states[interval.id] = state
        }
    }

    private func emit(
        _ counter: ProjectStorageInstrumentation.Counter,
        value: UInt64
    ) {
        switch counter {
        case .visitedObjects:
            signposter.emitEvent(
                "ProjectStorage.visitedObjects",
                "count=\(value)"
            )
        case .candidateEntries:
            signposter.emitEvent(
                "ProjectStorage.candidateEntries",
                "count=\(value)"
            )
        case .trackedHardLinkIdentities:
            signposter.emitEvent(
                "ProjectStorage.trackedHardLinkIdentities",
                "count=\(value)"
            )
        case .retainedScannerRecords:
            signposter.emitEvent(
                "ProjectStorage.retainedScannerRecords",
                "count=\(value)"
            )
        case .reusedHashes:
            signposter.emitEvent(
                "ProjectStorage.reusedHashes",
                "count=\(value)"
            )
        case .computedHashes:
            signposter.emitEvent(
                "ProjectStorage.computedHashes",
                "count=\(value)"
            )
        case .mainActorCommits:
            signposter.emitEvent(
                "ProjectStorage.mainActorCommits",
                "count=\(value)"
            )
        }
    }

    private func end(
        _ interval: ProjectStorageInstrumentation.Interval,
        outcome: ProjectStorageInstrumentation.Outcome
    ) {
        let state = lock.withLock {
            states.removeValue(forKey: interval.id)
        }
        guard let state else { return }
        switch interval.phase {
        case .scan:
            signposter.endInterval(
                "ProjectStorage.Scan",
                state,
                "outcome=\(outcome.rawValue)"
            )
        case .descriptorPreparation:
            signposter.endInterval(
                "ProjectStorage.DescriptorPreparation",
                state,
                "outcome=\(outcome.rawValue)"
            )
        case .mainActorCommit:
            signposter.endInterval(
                "ProjectStorage.MainActorCommit",
                state,
                "outcome=\(outcome.rawValue)"
            )
        }
    }
}
