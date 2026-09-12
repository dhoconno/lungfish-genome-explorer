import Foundation
import LungfishKit

/// Owns primer execution independently of the configuration sheet's lifetime.
@MainActor
enum PrimerDesignOperation {
  struct Handle {
    let id: UUID
    let task: Task<Void, Never>
  }

  static func start(
    center: OperationCenter = .shared,
    title: String,
    destination: URL,
    routeContext: OperationRouteContext?,
    operation: @escaping @Sendable (@escaping @Sendable (Double, String) -> Void) async throws -> URL,
    onResultSaved: @escaping @MainActor (URL) -> Void
  ) -> Handle {
    // Registration is synchronous: the Operations Panel can show the run before
    // dependency preparation or scientific execution begins.
    let id = center.start(title: title, detail: "Preparing primer design…", operationType: .workflow,
      targetBundleURL: destination, routeContext: routeContext)
    let task = Task { @MainActor in
      guard center.items.first(where: { $0.id == id })?.state.isActive == true else { return }
      do {
        try Task.checkCancellation()
        let output = try await operation { fraction, message in
          Task { @MainActor in
            center.updateWithLog(id: id, progress: fraction.isFinite ? fraction : 0, detail: message)
          }
        }
        // The pipeline has already atomically published its bundle. Let the
        // OperationCenter arbitrate a concurrent cancellation before UI delivery.
        if center.complete(id: id, detail: "Primer analysis saved.", outputURLs: [output]) {
          onResultSaved(output)
        }
      } catch is CancellationError {
        center.acknowledgeCancellation(id: id)
      } catch {
        center.fail(id: id, detail: "Primer design failed.", errorMessage: error.localizedDescription,
          errorDetail: String(reflecting: error))
      }
    }
    center.setCancelCallback(for: id) { task.cancel() }
    return Handle(id: id, task: task)
  }
}
