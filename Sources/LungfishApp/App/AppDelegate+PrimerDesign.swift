import AppKit

extension AppDelegate {
  @objc func showPCRPrimerDesign(_ sender: Any?) {
    guard let controller = activeMainWindowController(sender: sender), let window = controller.window else {
      NSSound.beep()
      return
    }
    let selected = controller.mainSplitViewController?.sidebarController?.selectedFileURLs() ?? []
    let supported = selected.filter {
      ["fa", "fasta", "fna", "ffn", "lungfishmsa"].contains($0.pathExtension.lowercased())
    }
    PrimerDesignDialogPresenter.present(from: window, inputURLs: supported) { [weak self] url in
      _ = self?.openDocument(at: url)
    }
  }
}
