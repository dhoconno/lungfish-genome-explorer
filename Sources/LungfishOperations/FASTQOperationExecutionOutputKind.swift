import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

package enum FASTQOperationExecutionOutputKind: Sendable, Equatable {
    case fastqFile
    case directory
    case jsonReport
}
