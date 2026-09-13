import AppKit
import SwiftUI

private final class PrimerAnalysisHostingController: NSHostingController<PrimerAnalysisViewerView> {
    var installationID = UUID()
    var onDismiss: (@MainActor () -> Void)?
}

extension ViewerViewController {
    func displayPrimerAnalysisBundle(
        at url: URL,
        displaySession: PrimerAnalysisDisplaySession? = nil,
        onLoadStateChanged: @escaping @MainActor (PrimerAnalysisViewerModel.State) -> Void = { _ in },
        onDismiss: @escaping @MainActor () -> Void = {},
        onExportRequested: (@MainActor (PrimerAnalysisExportSelection, PrimerAnalysisExportKind) -> Void)? = nil
    ) {
        clearViewport()
        let installationID = UUID()
        let controller = PrimerAnalysisHostingController(rootView: PrimerAnalysisViewerView(
            bundleURL: url, model: PrimerAnalysisViewerModel(), displaySession: displaySession, onLoadStateChanged: { [weak self] state in
                guard let installed = self?.primerAnalysisViewController as? PrimerAnalysisHostingController,
                    installed.installationID == installationID else { return }
                onLoadStateChanged(state)
            }, onExportRequested: onExportRequested.map { callback in
                { [weak self] selection, kind in
                    guard let installed = self?.primerAnalysisViewController as? PrimerAnalysisHostingController,
                        installed.installationID == installationID else { return }
                    callback(selection, kind)
                }
            }))
        controller.installationID = installationID
        controller.onDismiss = onDismiss
        addChild(controller)
        let resultsView = controller.view
        resultsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resultsView)
        NSLayoutConstraint.activate([
            resultsView.topAnchor.constraint(equalTo: view.topAnchor),
            resultsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            resultsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            resultsView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        primerAnalysisViewController = controller
    }

    func hidePrimerAnalysisView() {
        guard let controller = primerAnalysisViewController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        primerAnalysisViewController = nil
        (controller as? PrimerAnalysisHostingController)?.onDismiss?()
    }
}
