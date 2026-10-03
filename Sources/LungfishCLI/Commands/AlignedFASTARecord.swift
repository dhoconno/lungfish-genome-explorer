import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct AlignedFASTARecord: Equatable {
    let name: String
    let sequence: String
}
