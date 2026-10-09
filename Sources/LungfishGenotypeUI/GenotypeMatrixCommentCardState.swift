import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

public struct GenotypeMatrixCommentCardState: Equatable, Sendable {
    public typealias Target = GenotypeAnnotationSidecar.MatrixTarget
    public typealias Comment = GenotypeAnnotationSidecar.MatrixComment

    public let scope: GenotypeMatrixCommentScope
    public let targets: [Target]
    public let valueState: GenotypeMatrixValueState<String>
    public let currentComments: [Comment]

    public var targetCount: Int { targets.count }
    public var currentComment: Comment? {
        currentComments.count == 1 ? currentComments[0] : nil
    }

    public var authorState: GenotypeMatrixValueState<String> {
        Self.valueState(currentComments.map(\.author))
    }

    public var timestampState: GenotypeMatrixValueState<String> {
        Self.valueState(currentComments.map(\.timestamp))
    }

    public var metadataSummary: String {
        guard !currentComments.isEmpty else { return "" }
        return "\(Self.metadataValue(authorState, mixed: "Multiple authors"))"
            + " · \(Self.metadataValue(timestampState, mixed: "Multiple timestamps"))"
    }

    public var displayBody: String {
        guard case let .uniform(body) = valueState else { return "" }
        return body
    }

    public var currentValueSummary: String {
        switch valueState {
        case .none:
            return "No comment"
        case .uniform:
            return targetCount == 1 ? "Current comment" : "\(targetCount) comments"
        case .mixed:
            return "Multiple comments"
        }
    }

    public var requiresExplicitReplace: Bool {
        targetCount > 1 && valueState != .none
    }

    public var actionTitle: String {
        if requiresExplicitReplace {
            return "Replace Comments on \(targetCount) Targets"
        }
        switch valueState {
        case .none:
            return "Add Comment"
        case .uniform, .mixed:
            return "Save Changes"
        }
    }

    public var hasAnyComment: Bool {
        !currentComments.isEmpty
    }

    private static func valueState(
        _ values: [String]
    ) -> GenotypeMatrixValueState<String> {
        guard let first = values.first else { return .none }
        guard values.dropFirst().allSatisfy({ $0 == first }) else { return .mixed }
        return .uniform(first)
    }

    private static func metadataValue(
        _ state: GenotypeMatrixValueState<String>,
        mixed: String
    ) -> String {
        switch state {
        case .none:
            return ""
        case let .uniform(value):
            return value
        case .mixed:
            return mixed
        }
    }
}
