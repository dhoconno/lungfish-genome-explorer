import Foundation
import LungfishKit

extension MainSplitViewController {
    func displayPrimerAnalysisBundleFromSidebar(
        at url: URL,
        identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil
    ) {
        let displayIdentity = identity ?? contentSelectionIdentity(url: url, kind: "primerAnalysisBundle")
        let displayToken = token ?? beginDisplayRequest(identity: displayIdentity)
        guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
        inspectorController.clearSelection()
        viewerController.displayPrimerAnalysisBundle(at: url)
    }
}
