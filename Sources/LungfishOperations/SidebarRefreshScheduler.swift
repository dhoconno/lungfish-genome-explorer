import Foundation

@MainActor
public final class SidebarRefreshScheduler {
    public typealias Handler = @MainActor (_ notifyUnchangedSelectionRefresh: Bool) -> Void

    private let debounce: Duration
    private let handler: Handler
    private var pendingTask: Task<Void, Never>?
    private var pendingNotifyUnchangedSelectionRefresh = false

    public init(debounce: Duration = .milliseconds(120), handler: @escaping Handler) {
        self.debounce = debounce
        self.handler = handler
    }

    public func requestFullReload(notifyUnchangedSelectionRefresh: Bool = true) {
        pendingNotifyUnchangedSelectionRefresh = pendingNotifyUnchangedSelectionRefresh || notifyUnchangedSelectionRefresh
        pendingTask?.cancel()

        let delay = debounce
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }
            let shouldNotify = pendingNotifyUnchangedSelectionRefresh
            pendingNotifyUnchangedSelectionRefresh = false
            pendingTask = nil
            handler(shouldNotify)
        }
    }

    public func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingNotifyUnchangedSelectionRefresh = false
    }
}
