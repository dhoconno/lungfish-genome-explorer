import AppKit
import SwiftUI

extension ViewerViewController {
    func displayPrimerAnalysisBundle(at url: URL) {
        clearViewport()
        let controller = NSHostingController(rootView: PrimerAnalysisViewerView(bundleURL: url))
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
    }
}
