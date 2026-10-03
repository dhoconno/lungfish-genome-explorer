import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum AIHaplotypingInputTableFormat: Equatable {
    case auto
    case csv
    case tsv
    case json
}
