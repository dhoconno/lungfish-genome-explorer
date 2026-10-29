import AppKit
import SwiftUI
import LungfishIO
import LungfishKit
import LungfishWorkflow

extension ViewerViewController {
    /// The installed primer analysis or primer order viewer, read from the surface host.
    var primerAnalysisViewController: NSViewController? {
        let controller = surfaceHost.activeViewport?.viewController
        return controller is PrimerAnalysisHostingController || controller is PrimerOrderHostingController ? controller : nil
    }

    /// Shows the saved primer analysis at `url` through the surface host, or throws
    /// the reason it is not installed. `onDismiss` runs when the host removes it.
    func displayPrimerAnalysisBundle(
        at url: URL,
        displaySession: PrimerAnalysisDisplaySession? = nil,
        onLoadStateChanged: @escaping @MainActor (PrimerAnalysisViewerModel.State) -> Void = { _ in },
        onDismiss: @escaping @MainActor () -> Void = {},
        onExportRequested: (@MainActor (PrimerAnalysisExportSelection, PrimerAnalysisExportKind) -> Void)? = nil
    ) throws {
        clearViewport()
        let installationID = UUID()
        let rootView = PrimerAnalysisViewerView(
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
            })
        let input = PrimerSurfaceInput(installationID: installationID, rootView: rootView, onDismiss: onDismiss)
        _ = try showSurface(.bundle(.primerAnalysis), input: input, as: PrimerAnalysisSurface.self)
    }

    /// Shows the reviewed primer order at `url` through the surface host, or throws
    /// the reason it is not installed. `onDismiss` runs when the host removes it.
    func displayPrimerOrder(
        at url: URL,
        onLoaded: @escaping @MainActor (PrimerOrderViewerSnapshot) -> Void = { _ in },
        onLoadFailed: @escaping @MainActor (String) -> Void = { _ in },
        onDismiss: @escaping @MainActor () -> Void = {}
    ) throws {
        clearViewport()
        let installationID = UUID()
        let rootView = PrimerOrderResultView(
            orderURL: url, onLoaded: { [weak self] document in
                guard let installed = self?.primerAnalysisViewController as? PrimerOrderHostingController,
                      installed.installationID == installationID else { return }
                onLoaded(document)
            }, onLoadFailed: { [weak self] message in
                guard let installed = self?.primerAnalysisViewController as? PrimerOrderHostingController,
                      installed.installationID == installationID else { return }
                onLoadFailed(message)
            })
        let input = PrimerSurfaceInput(installationID: installationID, rootView: rootView, onDismiss: onDismiss)
        _ = try showSurface(.analysis(.primerOrder), input: input, as: PrimerOrderSurface.self)
    }

    /// Hides the primer analysis or primer order viewer, a shim that other display
    /// routes and every content mode change call until the hide list goes in Phase 3.2.
    func hidePrimerAnalysisView() {
        clearSurface(ifShowing: .bundle(.primerAnalysis), .analysis(.primerOrder))
    }
}
