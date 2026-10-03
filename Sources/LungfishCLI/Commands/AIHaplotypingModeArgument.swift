import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum AIHaplotypingModeArgument: String, CaseIterable, ExpressibleByArgument {
    case aiDiscovery = "ai-discovery"
    case aiRefinement = "ai-refinement"

    var promptMode: AIHaplotypingPromptMode {
        switch self {
        case .aiDiscovery: return .aiDiscovery
        case .aiRefinement: return .aiRefinement
        }
    }
}
