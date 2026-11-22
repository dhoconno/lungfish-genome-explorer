import Foundation

enum DatasetOperationSection: CaseIterable, Sendable {
    case overview
    case inputs
    case primarySettings
    case advancedSettings
    case output

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .inputs:
            return "Inputs"
        case .primarySettings:
            return "Primary settings"
        case .advancedSettings:
            return "Advanced settings"
        case .output:
            return "Output"
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
    /// The card's help tag, or nil for the dialog's general sidebar help.
    let help: String?

    init(
        id: String,
        title: String,
        subtitle: String,
        availability: DatasetOperationAvailability,
        help: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.availability = availability
        self.help = help
    }
}
