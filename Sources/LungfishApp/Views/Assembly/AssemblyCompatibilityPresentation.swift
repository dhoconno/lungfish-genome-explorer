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
        blockingMessage: String?,
        warningMessage: String? = nil
    ) {
        if let blockingMessage {
            self.state = .blocked
            self.fillStyle = .attention
            self.message = blockingMessage
            return
        }

        // A read class the tool does not suit is a warning: the run uses the
        // tool's own read-type settings (AssemblyCompatibility.effectiveReadType).
        let warning = warningMessage ?? (AssemblyCompatibility.isSupported(tool: tool, for: readType)
            ? nil
            : "\(tool.displayName) is designed for other reads than \(readType.displayName). The run uses \(tool.displayName) as chosen.")

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
        self.fillStyle = warning == nil ? .success : .attention
        self.message = warning.map { "\(tool.displayName) is ready. \($0)" } ?? "\(tool.displayName) is ready for \(readType.displayName)."
    }
}
