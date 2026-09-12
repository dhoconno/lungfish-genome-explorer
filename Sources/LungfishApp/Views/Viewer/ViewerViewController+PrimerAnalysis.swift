import AppKit
import SwiftUI

private final class PrimerAnalysisHostingController: NSHostingController<PrimerAnalysisViewerView> {
    var installationID = UUID()
    var onDismiss: (@MainActor () -> Void)?
}

extension ViewerViewController {
    func displayPrimerAnalysisBundle(
        at url: URL,
        onLoadStateChanged: @escaping @MainActor (PrimerAnalysisViewerModel.State) -> Void = { _ in },
        onDismiss: @escaping @MainActor () -> Void = {}
    ) {
        clearViewport()
        let installationID = UUID()
        let controller = PrimerAnalysisHostingController(rootView: PrimerAnalysisViewerView(
            bundleURL: url, model: PrimerAnalysisViewerModel(), onLoadStateChanged: { [weak self] state in
                guard let installed = self?.primerAnalysisViewController as? PrimerAnalysisHostingController,
                    installed.installationID == installationID else { return }
                onLoadStateChanged(state)
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
