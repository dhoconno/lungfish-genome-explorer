import Foundation
import LungfishWorkflow

enum AnalysisResultDisplayRoute: Equatable {
    case assembly
    case mapping
    case naoMgs
    case nvd
    case czId
    case viralRecon
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
        // Checked before the assembly and mapping prefixes so a Viral Recon
        // run cannot be mistaken for either.
        if normalized.hasPrefix("viralrecon") {
            return .viralRecon
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
