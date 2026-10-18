import AppKit
import SwiftUI
import LungfishWorkflow
import LungfishKit

@MainActor
final class PrimerDesignDialogPresenter {
  private static var activePresenters: [UUID: PrimerDesignDialogPresenter] = [:]
  private let id = UUID()
  private let state: PrimerDesignDialogState
  private let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: true)
  private var routeContext: OperationRouteContext?
  private var showOperations: (() -> Void)?
  private var parentCloseObserver: NSObjectProtocol?
  private var resultSaved: ((URL) -> Void)?
  private var canRun: (() -> Bool)?

  private init(projectURL: URL) { state = PrimerDesignDialogState(projectURL: projectURL) }

  static func present(from window: NSWindow, projectURL: URL, inputURLs: [URL],
                      engine: PrimerDesignEngine = .primer3,
                      canRun: @escaping () -> Bool, routeContext: OperationRouteContext,
                      onShowOperations: @escaping () -> Void, onResultSaved: @escaping (URL) -> Void) {
    let presenter = PrimerDesignDialogPresenter(projectURL: projectURL)
    presenter.state.engine = engine
    presenter.canRun = canRun
    presenter.routeContext = routeContext
    presenter.showOperations = onShowOperations
    presenter.resultSaved = onResultSaved
    presenter.state.addInputs(inputURLs)
    presenter.panel.title = "PCR Primer Design"
    presenter.panel.isReleasedWhenClosed = false
    presenter.panel.contentViewController = NSHostingController(rootView: PrimerDesignDialog(
      state: presenter.state,
      onRun: { [weak presenter] in presenter?.run() },
      onClose: { [weak presenter] in presenter?.close() }))
    presenter.panel.setContentSize(NSSize(width: 1020, height: 780))
    presenter.parentCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak presenter] _ in
      Task { @MainActor [weak presenter] in
        guard let presenter else { return }
        presenter.dismiss()
      }
    }
    activePresenters[presenter.id] = presenter
    window.beginSheet(presenter.panel)
  }

  private func close() {
    guard !state.isRunning else { return }
    dismiss()
  }

  private func dismiss() {
    if let parent = panel.sheetParent { parent.endSheet(panel) }
    panel.orderOut(nil)
    panel.contentViewController = nil
    resultSaved = nil
    canRun = nil
    showOperations = nil
    if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
    parentCloseObserver = nil
    Self.activePresenters[id] = nil
  }

  /// Builds the dialog's `lungfish-cli primers design` command once, begins the row with it and runs it. Primer3,
  /// PrimalScheme3 and varVAMP run the command through `CLIPrimerDesignRunner`, which creates the `Analyses` folder
  /// and writes every record (Phase 2.12 lane 12.17 M2). Olivar runs in process until its bundle replay (2.13 row
  /// A67-OLIVAR) and records the same command. Settings with no command run nothing and keep the dialog open.
  private func run() {
    guard !state.isRunning, state.validationMessage == nil, state.inputReadinessMessage == nil,
      canRun?() == true else { return }
    do {
      let destination = try state.validatedDestinationURL(createParent: false)
      guard let argv = PrimerDesignOperation.cliArgv(state: state, destination: destination) else {
        state.errorMessage = PrimerDesignOperation.noCommandMessage
        return
      }
      let title = "\(state.engine.rawValue) · \(state.analysisName)"
      let saved = resultSaved
      let showPanel = showOperations
      if state.engine == .olivar {
        try runOlivarInProcess(destination: try state.validatedDestinationURL(createParent: true), argv: argv, title: title)
      } else {
        _ = PrimerDesignOperation.startThroughCLI(
          title: title, destination: destination, routeContext: routeContext, argv: argv,
          onResultSaved: { output in saved?(output) })
      }
      dismiss()
      showPanel?()
    } catch { state.errorMessage = error.localizedDescription }
  }

  /// The Olivar design in process, as every engine ran before lane 12.17 M2. Its record names the row's command.
  private func runOlivarInProcess(destination: URL, argv: [String], title: String) throws {
    let runtime = ProvenanceRuntimeIdentity()
    var visibleOptions: [String: ParameterValue] = [
      "analysisName": .string(state.analysisName),
      "engine": .string(state.engine.rawValue),
      "interface": .string("Lungfish PCR Primer Design"),
      "projectPath": .string(state.projectURL!.path),
    ]
    let options = try state.primerSchemeOptions()
    visibleOptions.merge(options.provenanceOptions) { _, resolved in resolved }
    visibleOptions["sizingSemantics"] = .string(
      "full saved-reference span including primer sites; nominal target is not a closeness objective")
    visibleOptions["poolSemantics"] = .string("native fixed two-pool tiled workflow")
    let invocation = PrimerAnalysisWrapperInvocation(
      argv: argv, callerVersion: runtime.appVersion ?? WorkflowRun.currentAppVersion,
      explicitOptions: visibleOptions, runtimeIdentity: runtime)
    let request = PrimerSchemeDesignRequest(
      inputURLs: state.inputURLs, destinationURL: destination, options: options, invocation: invocation,
      expectedInputChecksums: state.inputSummaries.mapValues(\.checksumSHA256))
    let saved = resultSaved
    _ = PrimerDesignOperation.start(title: title,
      destination: destination, routeContext: routeContext,
      cliCommand: OperationCenter.buildCLICommand(subcommand: "", args: Array(argv.dropFirst())),
      operation: { progress in try await PrimerSchemeDesignPipeline().run(request: request, progress: progress) },
      onResultSaved: { output in saved?(output) })
  }
}
