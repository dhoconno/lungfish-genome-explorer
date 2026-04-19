import SwiftUI
import LungfishWorkflow

enum AssemblyCompatibilityPresentationState: Equatable {
    case blocked
    case installationRequired
    case ready
}

enum AssemblyCompatibilityFillStyle: Equatable {
    case card
    case attention
    case success

    var fillColor: Color {
        switch self {
        case .card:
            return .lungfishCardBackground
        case .attention:
            return .lungfishAttentionFill
        case .success:
            return .lungfishSuccessFill
        }
    }
}

struct AssemblyCompatibilityPresentation: Equatable {
    let state: AssemblyCompatibilityPresentationState
    let fillStyle: AssemblyCompatibilityFillStyle
    let message: String

    init(
        tool: AssemblyTool,
        readType: AssemblyReadType,
        packReady: Bool,
        toolReady: Bool,
        blockingMessage: String?
    ) {
        if let blockingMessage {
            self.state = .blocked
            self.fillStyle = .attention
            self.message = blockingMessage
            return
        }

        guard AssemblyCompatibility.isSupported(tool: tool, for: readType) else {
            self.state = .blocked
            self.fillStyle = .attention
            self.message = "\(tool.displayName) is not available for \(readType.displayName) in v1."
            return
        }

        guard packReady else {
            self.state = .installationRequired
            self.fillStyle = .attention
            self.message = "Install the Genome Assembly pack to enable \(tool.displayName)."
            return
        }

        guard toolReady else {
            self.state = .installationRequired
            self.fillStyle = .attention
            self.message = "\(tool.displayName) is not ready in the Genome Assembly pack yet."
            return
        }

        self.state = .ready
        self.fillStyle = .success
        self.message = "\(tool.displayName) is ready for \(readType.displayName)."
    }
}
