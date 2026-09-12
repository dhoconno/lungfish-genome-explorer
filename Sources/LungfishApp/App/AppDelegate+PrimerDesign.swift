import AppKit
import LungfishKit

extension AppDelegate {
  @objc func showPCRPrimerDesign(_ sender: Any?) {
    guard let controller = activeMainWindowController(sender: sender), let window = controller.window else {
      NSSound.beep()
      return
    }
    guard let projectURL = controller.projectSession.projectURL
      ?? controller.mainSplitViewController?.sidebarController?.currentProjectURL else {
      showAlert(title: "No Project Open", message: "Open a project before designing primers.", presentingWindow: window)
      return
    }
    let canRun = { [weak self, weak controller] in
      guard let self, let controller,
        (controller.projectSession.projectURL ?? controller.mainSplitViewController?.sidebarController?.currentProjectURL)?
          .standardizedFileURL == projectURL.standardizedFileURL else { return false }
      return self.canWriteProjectOutputs(projectURL: projectURL,
        windowStateScope: controller.projectSession.windowStateScope,
        workflowName: "PCR Primer Design", presentingWindow: controller.window)
    }
    guard canRun() else { return }
    let selected = controller.mainSplitViewController?.sidebarController?.selectedFileURLs() ?? []
    let supported = selected.filter {
      ["fa", "fasta", "fna", "ffn", "lungfishmsa"].contains($0.pathExtension.lowercased())
    }
    PrimerDesignDialogPresenter.present(from: window, projectURL: projectURL, inputURLs: supported,
      canRun: canRun,
      routeContext: OperationRouteContext(projectURL: projectURL, windowStateScope: controller.projectSession.windowStateScope),
      onShowOperations: { [weak self] in self?.showOperationsPanel(nil) },
      onResultSaved: { [weak controller] _ in
        guard (controller?.projectSession.projectURL ?? controller?.mainSplitViewController?.sidebarController?.currentProjectURL)?
          .standardizedFileURL == projectURL.standardizedFileURL else { return }
        controller?.mainSplitViewController?.sidebarController?.requestReloadFromFilesystem(notifyUnchangedSelectionRefresh: false)
      })
  }
}
