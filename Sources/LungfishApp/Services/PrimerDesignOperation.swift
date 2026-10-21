import Foundation
import LungfishCore
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
  /// value the dialog controls, so it replays the parameters the run used. It is ``cliArgv(state:destination:)``
  /// with each word shell-escaped.
  static func cliCommand(state: PrimerDesignDialogState, destination: URL) -> String? {
    guard let argv = cliArgv(state: state, destination: destination) else { return nil }
    return OperationCenter.buildCLICommand(subcommand: "", args: Array(argv.dropFirst()))
  }

  /// The words of ``cliCommand(state:destination:)``, the executable name, the subcommand words and the
  /// arguments, or nil when the dialog has no command. A design run records them as its provenance argv
  /// (`docs/contracts/CLI-EQUIVALENCE.md`), so the Provenance tab names the command Copy CLI Command gives
  /// and not the app's launch arguments (Phase 2.12 lane 12.17, A67-ARGV).
  static func cliArgv(state: PrimerDesignDialogState, destination: URL) -> [String]? {
    do {
      let engine: String
      let arguments: [String]?
      switch state.engine {
      case .primer3:
        engine = "primer3"
        arguments = PrimerDesignCLIArguments.primer3(
          selections: try state.primer3Selections(), output: destination, options: try state.primer3Options())
      case .primalScheme:
        engine = "primalscheme3"
        arguments = PrimerDesignCLIArguments.primalScheme3(
          inputs: state.inputURLs, output: destination, grouping: state.grouping,
          options: try state.primalSchemeOptions(), executableURL: state.primalschemeExecutableURL)
      case .olivar, .varVAMP:
        engine = state.engine == .olivar ? "olivar" : "varvamp"
        arguments = PrimerDesignCLIArguments.primerScheme(
          inputs: state.inputURLs, output: destination, options: try state.primerSchemeOptions())
      }
      return arguments.map {
        [CLICommandIdentity.executableName, "primers", "design", engine] + inProjectForm($0, destination: destination)
      }
    } catch {
      return nil
    }
  }

  /// `arguments` with `--output <destination>` replaced by `--project <project> --name=<name>`, the form of a result in
  /// a project (`docs/contracts/ADDING-AN-OPERATION.md`, the Copy CLI Command part). A replay in Terminal then writes a
  /// new bundle in the project and leaves the one the app wrote alone, and it makes the project's `Analyses` folder
  /// when the project has none (Phase 2.13 lane 13.43, row PRIMER-PROJECT). The classifier routes do the same with
  /// `--output-dir`. `destination` is `<project>/Analyses/<name>.lungfishprimeranalysis`, which the dialog validated.
  /// The name joins its option with `=`, so the parser reads a name that starts with a hyphen as a value. Arguments
  /// with no `--output` pair for `destination` stay as they are.
  static func inProjectForm(_ arguments: [String], destination: URL) -> [String] {
    guard let index = arguments.firstIndex(of: "--output"), arguments.indices.contains(index + 1),
      arguments[index + 1] == destination.path
    else { return arguments }
    let project = destination.deletingLastPathComponent().deletingLastPathComponent()
    let name = destination.deletingPathExtension().lastPathComponent
    var words = arguments
    words.replaceSubrange(index...(index + 1), with: ["--project", project.path, "--name=\(name)"])
    return words
  }

  /// The status line of a dialog whose settings have no `lungfish-cli` command. Nothing runs (UX ruling on lane 12.17).
  static let noCommandMessage =
    "Lungfish could not build the lungfish-cli command for these settings, so nothing ran. Check the settings and try again."
  /// The alert text of a run the command refused because a bundle already sat at the destination (UX ruling on R-B1).
  static let existingDestinationMessage =
    "An analysis with this name already exists in the project. Run the design again with a different name."

  /// Starts a Primer3, PrimalScheme3 or varVAMP design through `lungfish-cli` and returns its handle (Phase 2.12 lane
  /// 12.17 M2). `argv` is the dialog's command, ``cliArgv(state:destination:)``, built once. The row records it and
  /// the runner runs it with `--format json`. The row keeps the in-process route's title, first detail, end detail
  /// and failure detail, and `onResultSaved` gets the bundle the command published. A refused row launches nothing.
  static func startThroughCLI(
    title: String,
    destination: URL,
    routeContext: OperationRouteContext?,
    argv: [String],
    runner: CLIPrimerDesignRunner = CLIPrimerDesignRunner(),
    onResultSaved: @escaping @MainActor (URL) -> Void
  ) -> Handle {
    let center = OperationCenter.shared
    var launched: Handle?
    let result = beginPrimerDesignOperation(
      title: title, destination: destination, routeContext: routeContext,
      cliCommand: OperationCenter.buildCLICommand(subcommand: "", args: Array(argv.dropFirst())), reporter: center
    ) { id in
      let task = Task { @MainActor in
        do {
          let output = try await runner.run(arguments: CLIPrimerDesignRunner.arguments(argv: argv), operationID: id)
          if center.complete(id: id, detail: "Primer analysis saved.", outputURLs: [output]) {
            onResultSaved(output)
          }
        } catch is CancellationError {
          center.acknowledgeCancellation(id: id)
        } catch {
          let message = CLIPrimerDesignRunner.refusedAnExistingDestination(error, destination: destination)
            ? existingDestinationMessage : error.localizedDescription
          _ = center.fail(id: id, detail: "Primer design failed.", errorMessage: message, errorDetail: String(reflecting: error))
        }
      }
      center.setCancelCallback(for: id) { runner.cancel() }
      launched = Handle(id: id, task: task)
    }
    if let launched { return launched }
    guard case .refused(let refusal) = result else {
      preconditionFailure("A started primer design row always launches its runner.")
    }
    return Handle(id: refusal.id, task: Task {})
  }

  /// Starts the run in process and returns its handle, the route Olivar keeps until its bundle replay (2.13 row
  /// A67-OLIVAR). A refused row launches nothing, and its handle carries the refused row's ID with a task that has
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
