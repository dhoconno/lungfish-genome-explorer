import Foundation

enum DatasetOperationSection: CaseIterable, Sendable {
    case overview
    case inputs
    case primarySettings
    case advancedSettings
    case output
    case readiness

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .inputs:
            return "Inputs"
        case .primarySettings:
            return "Primary Settings"
        case .advancedSettings:
            return "Advanced Settings"
        case .output:
            return "Output"
        case .readiness:
            return "Readiness"
        }
    }
}

enum DatasetOperationAvailability: Equatable, Sendable {
    case available
    case disabled(reason: String)

    var badgeText: String? {
        switch self {
        case .available:
            return nil
        case .disabled(let reason):
            return reason
        }
    }
}

struct DatasetOperationToolSidebarItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let availability: DatasetOperationAvailability

    init(
        id: String,
        title: String,
        subtitle: String,
        availability: DatasetOperationAvailability
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.availability = availability
    }
}
