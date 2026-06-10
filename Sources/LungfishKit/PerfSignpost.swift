import Foundation
import os
import LungfishCore

/// Lightweight wrapper around `OSSignposter` for marking responsiveness-critical
/// regions so Instruments traces self-label. Effectively free when no trace is
/// recording. Shared kernel infra for the responsiveness sweep.
///
/// Usage:
/// ```swift
/// let state = PerfSignpost.sidebar.begin("Sidebar.Delete")
/// defer { PerfSignpost.sidebar.end("Sidebar.Delete", state) }
/// ```
public struct PerfSignpost: Sendable {
    private let signposter: OSSignposter

    /// - Parameter category: Instruments category, e.g. "Sidebar".
    public init(category: String) {
        self.signposter = OSSignposter(
            subsystem: LogSubsystem.app,
            category: category
        )
    }

    /// Begin an interval. Returns the state that must be passed to `end`.
    /// The name must be a static string (OSSignposter requirement).
    public func begin(_ name: StaticString) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        return signposter.beginInterval(name, id: id)
    }

    /// End a previously-begun interval.
    public func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// Emit a single point-of-interest event.
    public func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}

public extension PerfSignpost {
    /// Shared instance for sidebar interactions.
    static let sidebar = PerfSignpost(category: "Sidebar")
}
