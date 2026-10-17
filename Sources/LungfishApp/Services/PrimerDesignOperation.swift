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
  /// `.lungfishprimeranalysis` bundle the run writes, and records
  /// `cliCommand`, the `lungfish-cli primers design <engine>` command
  /// ``cliCommand(state:destination:)`` builds from the dialog's settings.
  /// Once a native tool launches, `start` logs that tool's argv, which is not
  /// a `lungfish-cli` command, to the row's log.
  @discardableResult
  static func beginPrimerDesignOperation(
    title: String,
    destination: URL,
    routeContext: OperationRouteContext?,
    cliCommand: String?,
    reporter: any OperationReporting = OperationCenter.shared,
    launch: (UUID) -> Void
  ) -> OperationStartResult {
    let result = reporter.begin(title: title, detail: "Preparing primer design…", operationType: .workflow,
      targetBundleURL: destination, cliCommand: cliCommand, routeContext: routeContext)
    switch result {
    case .started(let id):
      launch(id)
    case .refused:
      break  // The panel already shows the refused row. Nothing was launched.
    }
    return result
  }

  /// The `lungfish-cli primers design <engine>` command that reproduces a run of the dialog's
  /// current settings into `destination`, or nil when the settings are invalid or name an
  /// option the command cannot say (see ``PrimerDesignCLIArguments``). The command names every
  /// value the dialog controls, so it replays the parameters the run used.
  static func cliCommand(state: PrimerDesignDialogState, destination: URL) -> String? {
    do {
      let subcommand: String
      let arguments: [String]?
      switch state.engine {
      case .primer3:
        subcommand = "primers design primer3"
        arguments = PrimerDesignCLIArguments.primer3(
          selections: try state.primer3Selections(), output: destination, options: try state.primer3Options())
      case .primalScheme:
        subcommand = "primers design primalscheme3"
        arguments = PrimerDesignCLIArguments.primalScheme3(
          inputs: state.inputURLs, output: destination, grouping: state.grouping,
          options: try state.primalSchemeOptions(), executableURL: state.primalschemeExecutableURL)
      case .olivar, .varVAMP:
        subcommand = state.engine == .olivar ? "primers design olivar" : "primers design varvamp"
        arguments = PrimerDesignCLIArguments.primerScheme(
          inputs: state.inputURLs, output: destination, options: try state.primerSchemeOptions())
      }
      return arguments.map { OperationCenter.buildCLICommand(subcommand: subcommand, args: $0) }
    } catch {
      return nil
    }
  }

  /// Starts the run and returns its handle. A refused row launches nothing,
  /// and its handle carries the refused row's ID with a task that has
  /// already finished.
  static func start(
    center: any OperationReporting = OperationCenter.shared,
    title: String,
    destination: URL,
    routeContext: OperationRouteContext?,
    cliCommand: String?,
    operation: @escaping @Sendable (@escaping @Sendable (Double, String) -> Void) async throws -> URL,
    onResultSaved: @escaping @MainActor (URL) -> Void
  ) -> Handle {
    // Registration is synchronous: the Operations Panel can show the run before
    // dependency preparation or scientific execution begins.
    var launched: Handle?
    let result = beginPrimerDesignOperation(
      title: title, destination: destination, routeContext: routeContext, cliCommand: cliCommand, reporter: center
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
                  center.log(id: id, level: .info, message: "Native command: " + argv.map(shellEscape).joined(separator: " "))
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
