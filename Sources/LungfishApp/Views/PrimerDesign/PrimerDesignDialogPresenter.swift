import AppKit
import SwiftUI
import LungfishWorkflow

@MainActor
final class PrimerDesignDialogPresenter {
  private static var activePresenters: [UUID: PrimerDesignDialogPresenter] = [:]
  private let id = UUID()
  private let state = PrimerDesignDialogState()
  private let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: true)
  private var runTask: Task<Void, Never>?
  private var runID: UUID?
  private var openResult: ((URL) -> Void)?
  private var parentCloseObserver: NSObjectProtocol?

  static func present(from window: NSWindow, inputURLs: [URL], onOpenResult: @escaping (URL) -> Void) {
    let presenter = PrimerDesignDialogPresenter()
    presenter.openResult = onOpenResult
    presenter.state.addInputs(inputURLs)
    presenter.panel.title = "PCR Primer Design"
    presenter.panel.isReleasedWhenClosed = false
    presenter.panel.contentViewController = NSHostingController(rootView: PrimerDesignDialog(
      state: presenter.state,
      onRun: { [weak presenter] in presenter?.run() },
      onCancelRun: { [weak presenter] in presenter?.cancelRun() },
      onClose: { [weak presenter] in presenter?.close() },
      onOpenResult: { [weak presenter] url in
        guard let presenter else { return }
        let callback = presenter.openResult
        presenter.close()
        callback?(url)
      }))
    presenter.panel.setContentSize(NSSize(width: 1020, height: 780))
    presenter.parentCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak presenter] _ in
      Task { @MainActor [weak presenter] in
        guard let presenter else { return }
        presenter.runTask?.cancel()
        presenter.runID = nil
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
    openResult = nil
    if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
    parentCloseObserver = nil
    Self.activePresenters[id] = nil
  }

  private func cancelRun() {
    state.progressMessage = "Cancelling…"
    runID = nil
    runTask?.cancel()
  }

  private func run() {
    guard !state.isRunning, state.validationMessage == nil, state.inputReadinessMessage == nil,
      let destination = state.destinationURL else { return }
    do {
      let runtime = ProvenanceRuntimeIdentity()
      var visibleOptions: [String: ParameterValue] = [
        "analysisName": .string(state.analysisName),
        "engine": .string(state.engine.rawValue),
        "interface": .string("Lungfish PCR Primer Design"),
      ]
      if state.engine == .primer3 { visibleOptions["assay"] = .string(state.chemistry.rawValue) }
      let invocation = PrimerAnalysisWrapperInvocation(
        argv: CommandLine.arguments, callerVersion: runtime.appVersion,
        explicitOptions: visibleOptions, runtimeIdentity: runtime)
      let checksums = state.inputSummaries.mapValues(\.checksumSHA256)
      let overridePath = state.executableOverride.trimmingCharacters(in: .whitespacesAndNewlines)
      let executable = overridePath.isEmpty ? nil : URL(fileURLWithPath: overridePath)
      let generation = UUID()
      let progress: @Sendable (Double, String) -> Void = { [weak self] _, message in
        Task { @MainActor [weak self] in
          guard let self, self.runID == generation, self.state.isRunning else { return }
          self.state.progressMessage = message
        }
      }
      let operation: @Sendable () async throws -> URL
      if state.engine == .primer3 {
        let request = Primer3DesignRequest(
          inputURLs: state.inputURLs, selections: try state.primer3Selections(), destinationURL: destination,
          options: try state.primer3Options(), invocation: invocation, executableURL: executable,
          expectedInputChecksums: checksums)
        operation = { try await Primer3DesignPipeline().run(request: request, progress: progress) }
      } else {
        let request = PrimalScheme3DesignRequest(
          inputURLs: state.inputURLs, destinationURL: destination,
          options: try state.primalSchemeOptions(),
          grouping: state.grouping, invocation: invocation, executableURL: executable,
          expectedInputChecksums: checksums)
        operation = { try await PrimalScheme3DesignPipeline().run(request: request, progress: progress) }
      }
      runID = generation
      state.isRunning = true
      state.errorMessage = nil
      state.completedURL = nil
      state.progressMessage = "Starting \(state.engine.rawValue)…"
      runTask = Task { [weak self] in
        guard let self else { return }
        do {
          let output = try await operation()
          self.state.completedURL = output
          self.state.progressMessage = "Analysis saved."
        } catch is CancellationError {
          self.state.progressMessage = "Run cancelled."
        } catch {
          self.state.errorMessage = error.localizedDescription
          self.state.progressMessage = nil
        }
        self.state.isRunning = false
        self.runID = nil
        self.runTask = nil
      }
    } catch { state.errorMessage = error.localizedDescription }
  }
}
