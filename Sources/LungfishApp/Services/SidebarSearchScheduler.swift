import Foundation

@MainActor
final class SidebarSearchScheduler {
    typealias ClearHandler = @MainActor () -> Void
    typealias SearchHandler = @MainActor (_ query: String, _ generation: Int) -> Void

    private let debounceDelay: Duration
    private let minimumUniversalSearchLength: Int
    private let onClear: ClearHandler
    private let onLocalSearch: SearchHandler
    private let onUniversalSearch: SearchHandler

    private var pendingTask: Task<Void, Never>?
    private(set) var generation: Int = 0

    init(
        debounceDelay: Duration = .milliseconds(220),
        minimumUniversalSearchLength: Int = 3,
        onClear: @escaping ClearHandler,
        onLocalSearch: @escaping SearchHandler,
        onUniversalSearch: @escaping SearchHandler
    ) {
        self.debounceDelay = debounceDelay
        self.minimumUniversalSearchLength = minimumUniversalSearchLength
        self.onClear = onClear
        self.onLocalSearch = onLocalSearch
        self.onUniversalSearch = onUniversalSearch
    }

    deinit {
        pendingTask?.cancel()
    }

    func submit(_ rawQuery: String, immediate: Bool = false) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        generation &+= 1
        let searchGeneration = generation
        pendingTask?.cancel()
        pendingTask = nil

        guard !query.isEmpty else {
            onClear()
            return
        }

        if immediate {
            perform(query: query, generation: searchGeneration)
            return
        }

        let delay = debounceDelay
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.generation == searchGeneration else { return }
            self.pendingTask = nil
            self.perform(query: query, generation: searchGeneration)
        }
    }

    func cancel() {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
    }

    private func perform(query: String, generation: Int) {
        onLocalSearch(query, generation)
        if query.count >= minimumUniversalSearchLength {
            onUniversalSearch(query, generation)
        }
    }
}
