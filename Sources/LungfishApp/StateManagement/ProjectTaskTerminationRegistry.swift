import Foundation

/// Keeps project work reachable until it finishes, including cancelled loads
/// whose originating selection or window has already gone away.
@MainActor
enum ProjectTaskTerminationRegistry {
    private static var tasks: [UUID: Task<Void, Never>] = [:]

    static var hasPendingTasks: Bool { !tasks.isEmpty }

    static func start(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor in
            defer { tasks.removeValue(forKey: id) }
            await operation()
        }
        tasks[id] = task
        return task
    }

    static func cancelAndWait() async {
        // Work may enqueue another project operation before observing its
        // cancellation. Drain that work too before allowing process teardown.
        while !tasks.isEmpty {
            let pending = Array(tasks.values)
            pending.forEach { $0.cancel() }
            for task in pending { await task.value }
        }
    }
}
