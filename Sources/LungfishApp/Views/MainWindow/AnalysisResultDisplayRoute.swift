import Foundation
import LungfishWorkflow

enum AnalysisResultDisplayRoute: Equatable {
    case assembly
    case mapping
    case naoMgs
    case nvd
    case czId
    case unknown

    static func route(forToolID toolID: String) -> AnalysisResultDisplayRoute {
        let normalized = toolID.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.hasPrefix("naomgs") {
            return .naoMgs
        }
        if normalized.hasPrefix("nvd") {
            return .nvd
        }
        if normalized.hasPrefix("cz-id") {
            return .czId
        }
        if AssemblyTool.allCases.contains(where: { normalized.hasPrefix($0.rawValue) }) {
            return .assembly
        }
        if MappingTool(rawValue: normalized) != nil {
            return .mapping
        }
        return .unknown
    }
}
