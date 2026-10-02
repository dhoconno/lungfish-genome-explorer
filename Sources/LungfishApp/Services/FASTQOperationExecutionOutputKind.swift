import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum FASTQOperationExecutionOutputKind: Sendable, Equatable {
    case fastqFile
    case directory
    case jsonReport
}
