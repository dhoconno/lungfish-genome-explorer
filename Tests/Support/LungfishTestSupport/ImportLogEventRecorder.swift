// ImportLogEventRecorder.swift - Records the events a FASTQ batch import logs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishWorkflow
import Synchronization

/// The case of an ``ImportLogEvent``, without its payload.
public enum ImportLogEventKind: Sendable {
    case importStart
    case platformResolved
    case sampleStart
    case stepStart
    case stepComplete
    case notice
    case recipeReadDelta
    case sampleComplete
    case sampleSkip
    case sampleFailed
    case importComplete
}

extension ImportLogEvent {
    /// The event's case, for a test that asks which events a run emitted and does not read their payloads.
    public var kind: ImportLogEventKind {
        switch self {
        case .importStart: .importStart
        case .platformResolved: .platformResolved
        case .sampleStart: .sampleStart
        case .stepStart: .stepStart
        case .stepComplete: .stepComplete
        case .notice: .notice
        case .recipeReadDelta: .recipeReadDelta
        case .sampleComplete: .sampleComplete
        case .sampleSkip: .sampleSkip
        case .sampleFailed: .sampleFailed
        case .importComplete: .importComplete
        }
    }
}

/// Collects the events a batch import passes to its `log` closure, for a test that only observes them.
///
/// Pass `{ recorder.append($0) }` as `log:` and read ``events`` or ``kinds`` once the run returns.
public final class ImportLogEventRecorder: Sendable {
    private let storage = Mutex<[ImportLogEvent]>([])

    public init() {}

    public func append(_ event: ImportLogEvent) {
        storage.withLock { $0.append(event) }
    }

    /// Every event, in the order it arrived.
    public var events: [ImportLogEvent] {
        storage.withLock { $0 }
    }

    /// The case of every event, in the order it arrived.
    public var kinds: [ImportLogEventKind] {
        events.map(\.kind)
    }
}
