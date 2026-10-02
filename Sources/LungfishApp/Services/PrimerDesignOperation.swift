import Foundation
import LungfishKit
import LungfishWorkflow

/// Owns primer execution independently of the configuration sheet's lifetime.
@MainActor
enum PrimerDesignOperation {
  struct Handle {
    let id: UUID
    let task: Task<Void, Never>
  }

  /// Registers the primer design row and, only when it starts, calls `launch`
  /// with the operation ID. The row locks `destination`, the new
  /// `.lungfishprimeranalysis` bundle the run writes.
  ///
  /// CLI parity gap. The row records no command when it starts. Once a native
  /// tool launches, `start` replaces the command with that tool's argv
  /// through `setCommand`, which is not a `lungfish-cli` command. The closest
  /// commands are `lungfish-cli primers design primer3`, `primalscheme3`,
  /// `olivar` and `varvamp`, which run the same pipelines. The app has no
  /// builder from the dialog's settings to those commands' options, so the row
  /// keeps today's value until one exists.
  @discardableResult
  static func beginPrimerDesignOperation(
    title: String,
    destination: URL,
    routeContext: OperationRouteContext?,
    reporter: any OperationReporting = OperationCenter.shared,
    launch: (UUID) -> Void
  ) -> OperationStartResult {
    let result = reporter.begin(title: title, detail: "Preparing primer design…", operationType: .workflow,
      targetBundleURL: destination, cliCommand: nil, routeContext: routeContext)
    switch result {
    case .started(let id):
      launch(id)
    case .refused:
      break  // The panel already shows the refused row. Nothing was launched.
    }
    return result
  }

  /// Starts the run and returns its handle. A refused row launches nothing,
  /// and its handle carries the refused row's ID with a task that has
  /// already finished.
  static func start(
    center: any OperationReporting = OperationCenter.shared,
    title: String,
    destination: URL,
    routeContext: OperationRouteContext?,
    operation: @escaping @Sendable (@escaping @Sendable (Double, String) -> Void) async throws -> URL,
    onResultSaved: @escaping @MainActor (URL) -> Void
  ) -> Handle {
    // Registration is synchronous: the Operations Panel can show the run before
    // dependency preparation or scientific execution begins.
    var launched: Handle?
    let result = beginPrimerDesignOperation(
      title: title, destination: destination, routeContext: routeContext, reporter: center
    ) { id in
      let task = Task { @MainActor in
        do {
          try Task.checkCancellation()
          let output = try await NativeProcessObservation.$onEvent.withValue({ event in
            // Keep native reader callbacks short and deliver UI events in FIFO order.
            DispatchQueue.main.async {
              MainActor.assumeIsolated {
                switch event {
                case .started(let argv):
                  center.setCommand(id: id, command: argv.map(shellEscape).joined(separator: " "))
                case .output(_, let line):
                  // Stderr is commonly routine tool progress, not an error outcome.
                  center.log(id: id, level: .info, message: line)
                }
              }
            }
          }) {
            try await operation { fraction, message in
              Task { @MainActor in
                center.updateWithLog(id: id, progress: fraction.isFinite ? fraction : 0, detail: message)
              }
            }
          }
          // Flush queued diagnostic events before marking the operation complete.
          await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
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
      launched = Handle(id: id, task: task)
    }
    if let launched { return launched }
    // `launch` runs for every started row, so only a refused row gets here.
    guard case .refused(let refusal) = result else {
      preconditionFailure("A started primer design row always launches its worker.")
    }
    return Handle(id: refusal.id, task: Task {})
  }
}
