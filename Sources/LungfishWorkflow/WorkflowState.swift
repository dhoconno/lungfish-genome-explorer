// WorkflowState.swift - State machine for workflow execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Swift Architecture Lead (Role 01)

import Foundation
import os.log
import LungfishCore

// MARK: - WorkflowStatus

/// The current status of a workflow execution.
///
/// WorkflowStatus represents the various states a workflow can be in
/// during its lifecycle from pending to completion.
///
/// ## State Transitions
///
/// ```
///                    +-----------+
///                    |  pending  |
///                    +-----+-----+
///                          |
///                          v
///                    +-----------+
///         +--------->| starting  |<---------+
///         |          +-----+-----+          |
///         |                |                |
///         |                v                |
///         |          +-----------+          |
///         |          |  running  |----------+
///         |          +-----+-----+      (resume)
///         |                |
///         |     +----------+----------+
///         |     |          |          |
///         |     v          v          v
///      +--+--+  +-------+ +------+ +--------+
///      |pause|  |complete| | fail | | cancel |
///      +-----+  +-------+ +------+ +--------+
/// ```
public enum WorkflowStatus: String, Sendable, Codable, CaseIterable {
    /// Workflow is created but not yet started.
    case pending

    /// Workflow is initializing and preparing to run.
    case starting

    /// Workflow is actively running.
    case running

    /// Workflow is temporarily paused.
    case paused

    /// Workflow completed successfully.
    case completed

    /// Workflow failed with an error.
    case failed

    /// Workflow was cancelled by user or system.
    case cancelled

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .starting: return "Starting"
        case .running: return "Running"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    /// SF Symbol icon name for this status.
    public var iconName: String {
        switch self {
        case .pending: return "clock"
        case .starting: return "arrow.clockwise"
        case .running: return "play.fill"
        case .paused: return "pause.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        }
    }

    /// Whether this status represents a terminal state.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    /// Whether this status represents an active/running state.
    public var isActive: Bool {
        switch self {
        case .starting, .running:
            return true
        default:
            return false
        }
    }

    /// Whether the workflow can be cancelled in this state.
    public var canCancel: Bool {
        switch self {
        case .pending, .starting, .running, .paused:
            return true
        default:
            return false
        }
    }

    /// Whether the workflow can be paused in this state.
    public var canPause: Bool {
        self == .running
    }

    /// Whether the workflow can be resumed in this state.
    public var canResume: Bool {
        self == .paused
    }
}

// MARK: - StateTransition

/// A state transition event in the workflow state machine.
public struct StateTransition: Sendable {
    /// The previous state.
    public let from: WorkflowStatus

    /// The new state.
    public let to: WorkflowStatus

    /// When the transition occurred.
    public let timestamp: Date

    /// Optional reason for the transition.
    public let reason: String?

    /// Creates a new state transition.
    public init(
        from: WorkflowStatus,
        to: WorkflowStatus,
        timestamp: Date = Date(),
        reason: String? = nil
    ) {
        self.from = from
        self.to = to
        self.timestamp = timestamp
        self.reason = reason
    }
}

// MARK: - WorkflowStateMachine

/// Thread-safe state machine for workflow execution.
///
/// WorkflowStateMachine manages the state of a workflow execution,
/// enforcing valid state transitions and broadcasting state changes
/// to observers via AsyncStream.
///
/// ## Usage
///
/// ```swift
/// let stateMachine = WorkflowStateMachine()
///
/// // Observe state changes
/// Task {
///     for await transition in await stateMachine.stateChanges {
///         print("State changed: \(transition.from) -> \(transition.to)")
///     }
/// }
///
/// // Transition to new states
/// try await stateMachine.transition(to: .starting)
/// try await stateMachine.transition(to: .running)
/// try await stateMachine.transition(to: .completed)
/// ```
public actor WorkflowStateMachine {

    // MARK: - Properties

    /// Logger for state machine events.
    private let logger = Logger(
        subsystem: LogSubsystem.workflow,
        category: "WorkflowStateMachine"
    )

    /// The current workflow status.
    private var _currentStatus: WorkflowStatus = .pending

    /// History of state transitions.
    private var _transitionHistory: [StateTransition] = []

    /// Lazy stream state - initialized on first access to stateChanges.
    private var _streamState: StreamState?

    /// Internal struct to hold stream and continuation together.
    private struct StreamState {
        let stream: AsyncStream<StateTransition>
        let continuation: AsyncStream<StateTransition>.Continuation
    }

    /// Valid state transitions map.
    private static let validTransitions: [WorkflowStatus: Set<WorkflowStatus>] = [
        .pending: [.starting, .cancelled],
        .starting: [.running, .failed, .cancelled],
        .running: [.paused, .completed, .failed, .cancelled],
        .paused: [.running, .cancelled, .failed],
        .completed: [],
        .failed: [],
        .cancelled: []
    ]

    // MARK: - Initialization

    /// Creates a new workflow state machine.
    ///
    /// - Parameter initialStatus: The initial status (defaults to .pending)
    public init(initialStatus: WorkflowStatus = .pending) {
        self._currentStatus = initialStatus
        // Stream is lazily initialized on first access to stateChanges
        logger.debug("WorkflowStateMachine initialized with status: \(initialStatus.rawValue)")
    }

    /// Ensures the stream is initialized and returns the stream state.
    private func ensureStreamInitialized() -> StreamState {
        if let state = _streamState {
            return state
        }

        let (stream, continuation) = AsyncStream<StateTransition>.makeStream()
        let state = StreamState(stream: stream, continuation: continuation)
        _streamState = state
        return state
    }

    /// The async stream of state changes.
    ///
    /// Access this property to observe state transitions. The stream is
    /// lazily initialized on first access.
    public var stateChanges: AsyncStream<StateTransition> {
        ensureStreamInitialized().stream
    }

    /// The continuation for emitting state changes.
    private var stateChangeContinuation: AsyncStream<StateTransition>.Continuation? {
        _streamState?.continuation
    }

    // MARK: - Public API

    /// The current workflow status.
    public var currentStatus: WorkflowStatus {
        _currentStatus
    }

    /// The complete history of state transitions.
    public var transitionHistory: [StateTransition] {
        _transitionHistory
    }

    /// The timestamp when the workflow entered the current state.
    public var currentStateTimestamp: Date {
        _transitionHistory.last?.timestamp ?? Date()
    }

    /// Duration in the current state.
    public var timeInCurrentState: TimeInterval {
        Date().timeIntervalSince(currentStateTimestamp)
    }

    /// Total running time (sum of all time spent in .running state).
    public var totalRunningTime: TimeInterval {
        var totalTime: TimeInterval = 0
        var runningStartTime: Date?

        for transition in _transitionHistory {
            if transition.to == .running {
                runningStartTime = transition.timestamp
            } else if transition.from == .running, let startTime = runningStartTime {
                totalTime += transition.timestamp.timeIntervalSince(startTime)
                runningStartTime = nil
            }
        }

        // If currently running, add time since last transition to running
        if _currentStatus == .running, let startTime = runningStartTime {
            totalTime += Date().timeIntervalSince(startTime)
        }

        return totalTime
    }

    /// Attempts to transition to a new state.
    ///
    /// - Parameters:
    ///   - newStatus: The target status
    ///   - reason: Optional reason for the transition
    /// - Throws: `WorkflowError.invalidStateTransition` if the transition is not allowed
    public func transition(to newStatus: WorkflowStatus, reason: String? = nil) throws {
        let currentStatus = _currentStatus

        // Check if transition is valid
        guard Self.canTransition(from: currentStatus, to: newStatus) else {
            logger.error(
                "Invalid state transition: \(currentStatus.rawValue) -> \(newStatus.rawValue)"
            )
            throw WorkflowError.invalidStateTransition(
                from: currentStatus.rawValue,
                to: newStatus.rawValue
            )
        }

        // Perform the transition
        let transition = StateTransition(
            from: currentStatus,
            to: newStatus,
            reason: reason
        )

        _currentStatus = newStatus
        _transitionHistory.append(transition)

        logger.info(
            "State transition: \(currentStatus.rawValue) -> \(newStatus.rawValue)\(reason.map { " (\($0))" } ?? "")"
        )

        // Broadcast to observers
        stateChangeContinuation?.yield(transition)

        // If terminal state, finish the stream
        if newStatus.isTerminal {
            stateChangeContinuation?.finish()
        }
    }

    /// Checks if a transition from one state to another is valid.
    ///
    /// - Parameters:
    ///   - from: The source state
    ///   - to: The target state
    /// - Returns: True if the transition is allowed
    public static func canTransition(from: WorkflowStatus, to: WorkflowStatus) -> Bool {
        validTransitions[from]?.contains(to) ?? false
    }

    /// Resets the state machine to pending state.
    ///
    /// This clears the transition history and allows the workflow to be restarted.
    public func reset() {
        let currentStatusValue = self._currentStatus.rawValue
        logger.info("Resetting state machine from \(currentStatusValue) to pending")

        let transition = StateTransition(
            from: _currentStatus,
            to: .pending,
            reason: "State machine reset"
        )

        _currentStatus = .pending
        _transitionHistory = []

        stateChangeContinuation?.yield(transition)
    }

    /// Cancels the state stream.
    ///
    /// Call this when the workflow is being deallocated to clean up resources.
    public func cancel() {
        logger.debug("Cancelling state change stream")
        _streamState?.continuation.finish()
        _streamState = nil
    }

    // MARK: - Convenience Methods

    /// Marks the workflow as starting.
    public func markStarting() throws {
        try transition(to: .starting)
    }

    /// Marks the workflow as running.
    public func markRunning() throws {
        try transition(to: .running)
    }

    /// Marks the workflow as paused.
    public func markPaused(reason: String? = nil) throws {
        try transition(to: .paused, reason: reason)
    }

    /// Resumes a paused workflow.
    public func resume() throws {
        try transition(to: .running, reason: "Resumed")
    }

    /// Marks the workflow as completed successfully.
    public func markCompleted() throws {
        try transition(to: .completed)
    }

    /// Marks the workflow as failed.
    ///
    /// - Parameter error: The error that caused the failure
    public func markFailed(error: Error) throws {
        try transition(to: .failed, reason: error.localizedDescription)
    }

    /// Marks the workflow as cancelled.
    ///
    /// - Parameter reason: The cancellation reason
    public func markCancelled(reason: CancellationReason) throws {
        try transition(to: .cancelled, reason: reason.rawValue)
    }
}

// MARK: - WorkflowStateSnapshot

/// A snapshot of workflow state at a point in time.
///
/// Use this for serialization or checkpointing workflow state.
public struct WorkflowStateSnapshot: Sendable, Codable {
    /// The workflow execution ID.
    public let executionId: UUID

    /// The current status.
    public let status: WorkflowStatus

    /// When this snapshot was taken.
    public let timestamp: Date

    /// The transition history.
    public let transitions: [SerializableTransition]

    /// Creates a new state snapshot.
    public init(
        executionId: UUID,
        status: WorkflowStatus,
        timestamp: Date = Date(),
        transitions: [SerializableTransition] = []
    ) {
        self.executionId = executionId
        self.status = status
        self.timestamp = timestamp
        self.transitions = transitions
    }

    /// Serializable version of StateTransition.
    public struct SerializableTransition: Sendable, Codable {
        public let from: WorkflowStatus
        public let to: WorkflowStatus
        public let timestamp: Date
        public let reason: String?

        public init(from transition: StateTransition) {
            self.from = transition.from
            self.to = transition.to
            self.timestamp = transition.timestamp
            self.reason = transition.reason
        }
    }
}

// MARK: - WorkflowStateMachine Extensions

extension WorkflowStateMachine {
    /// Creates a snapshot of the current state.
    ///
    /// - Parameter executionId: The workflow execution ID
    /// - Returns: A state snapshot
    public func snapshot(executionId: UUID) -> WorkflowStateSnapshot {
        WorkflowStateSnapshot(
            executionId: executionId,
            status: _currentStatus,
            timestamp: Date(),
            transitions: _transitionHistory.map {
                WorkflowStateSnapshot.SerializableTransition(from: $0)
            }
        )
    }

    /// Restores state from a snapshot.
    ///
    /// - Parameter snapshot: The snapshot to restore from
    /// - Note: This does not validate transitions; use for recovery only.
    public func restore(from snapshot: WorkflowStateSnapshot) {
        logger.info("Restoring state from snapshot: \(snapshot.status.rawValue)")
        _currentStatus = snapshot.status
        _transitionHistory = snapshot.transitions.map { st in
            StateTransition(
                from: st.from,
                to: st.to,
                timestamp: st.timestamp,
                reason: st.reason
            )
        }
    }
}
