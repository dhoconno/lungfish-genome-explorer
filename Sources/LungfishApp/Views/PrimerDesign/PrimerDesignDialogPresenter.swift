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
                      canRun: @escaping () -> Bool, routeContext: OperationRouteContext,
                      onShowOperations: @escaping () -> Void, onResultSaved: @escaping (URL) -> Void) {
    let presenter = PrimerDesignDialogPresenter(projectURL: projectURL)
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

  private func run() {
    guard !state.isRunning, state.validationMessage == nil, state.inputReadinessMessage == nil,
      canRun?() == true else { return }
    do {
      let destination = try state.validatedDestinationURL(createParent: true)
      let runtime = ProvenanceRuntimeIdentity()
      var visibleOptions: [String: ParameterValue] = [
        "analysisName": .string(state.analysisName),
        "engine": .string(state.engine.rawValue),
        "interface": .string("Lungfish PCR Primer Design"),
        "projectPath": .string(state.projectURL!.path),
      ]
      if state.engine == .primer3 { visibleOptions["assay"] = .string(state.chemistry.rawValue) }
      let invocation = PrimerAnalysisWrapperInvocation(
        argv: CommandLine.arguments, callerVersion: runtime.appVersion,
        explicitOptions: visibleOptions, runtimeIdentity: runtime)
      let checksums = state.inputSummaries.mapValues(\.checksumSHA256)
      let executable: URL? = nil
      let operation: @Sendable (@escaping @Sendable (Double, String) -> Void) async throws -> URL
      if state.engine == .primer3 {
        let request = Primer3DesignRequest(
          inputURLs: state.inputURLs, selections: try state.primer3Selections(), destinationURL: destination,
          options: try state.primer3Options(), invocation: invocation, executableURL: executable,
          expectedInputChecksums: checksums)
        operation = { progress in try await Primer3DesignPipeline().run(request: request, progress: progress) }
      } else {
        let request = PrimalScheme3DesignRequest(
          inputURLs: state.inputURLs, destinationURL: destination,
          options: try state.primalSchemeOptions(),
          grouping: state.grouping, invocation: invocation, executableURL: executable,
          expectedInputChecksums: checksums)
        operation = { progress in try await PrimalScheme3DesignPipeline().run(request: request, progress: progress) }
      }
      let saved = resultSaved
      let showPanel = showOperations
      _ = PrimerDesignOperation.start(title: "\(state.engine.rawValue) · \(state.analysisName)",
        destination: destination, routeContext: routeContext, operation: operation,
        onResultSaved: { output in saved?(output) })
      dismiss()
      showPanel?()
    } catch { state.errorMessage = error.localizedDescription }
  }
}
