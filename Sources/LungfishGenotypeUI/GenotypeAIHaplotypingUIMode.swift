import AppKit
import Combine
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

public enum GenotypeAIHaplotypingUIMode: String, CaseIterable, Sendable {
    case aiDiscovery
    case aiRefinement

    public var displayName: String {
        switch self {
        case .aiDiscovery: return "AI Discovery"
        case .aiRefinement: return "AI Refinement"
        }
    }
}
