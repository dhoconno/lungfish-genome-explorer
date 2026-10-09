import AppKit
import Combine
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

@MainActor
protocol GenotypeMatrixAnnotationRetryScheduling: AnyObject {
    func schedule(
        _ action: @escaping @MainActor () -> Void
    ) -> GenotypeMatrixAnnotationRetryCancellation
}
