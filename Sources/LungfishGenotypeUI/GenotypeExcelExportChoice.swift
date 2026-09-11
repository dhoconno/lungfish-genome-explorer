import Foundation

public enum GenotypeExcelExportRole: String, CaseIterable, Identifiable, Sendable {
    case filteredView
    case editableWorkbook

    public var id: Self { self }

    public var title: String {
        switch self {
        case .filteredView: "Filtered view"
        case .editableWorkbook: "Editable workbook — current.xlsx"
        }
    }

    public var explanation: String {
        switch self {
        case .filteredView:
            "Share what you see in LGE, with the current filters, haplotype calls, and annotations. Changes in this file do not return to LGE."
        case .editableWorkbook:
            "Work with all evidence in Excel, including reads hidden by LGE filters. Supported edits can be reviewed and imported back into LGE."
        }
    }
}

@MainActor
public final class GenotypeExcelExportChoiceModel {
    public var role: GenotypeExcelExportRole

    public init(role: GenotypeExcelExportRole = .filteredView) {
        self.role = role
    }

    public var primaryActionTitle: String {
        role == .filteredView ? "Export…" : "Open in Excel"
    }
}
