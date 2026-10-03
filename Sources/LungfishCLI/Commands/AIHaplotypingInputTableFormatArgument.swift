import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum AIHaplotypingInputTableFormatArgument: String, CaseIterable, ExpressibleByArgument {
    case auto
    case csv
    case tsv
    case json

    var tableFormat: AIHaplotypingInputTableFormat {
        switch self {
        case .auto: return .auto
        case .csv: return .csv
        case .tsv: return .tsv
        case .json: return .json
        }
    }
}
