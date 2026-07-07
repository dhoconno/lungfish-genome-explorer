import Foundation

struct ToolsMenuModel: Equatable, Sendable {
    struct WorkflowEntry: Equatable, Sendable {
        let id: String
        let toolID: FASTQOperationToolID?
        let title: String
        let isEnabled: Bool
        let isInstallable: Bool

        var representedObject: Any {
            toolID ?? id
        }
    }

    struct Category: Equatable, Sendable {
        let id: FASTQOperationCategoryID
        let title: String
        let workflows: [WorkflowEntry]
    }

    let categories: [Category]

    @MainActor
    static func build(
        catalog: [WorkflowLibraryItem] = WorkflowLibraryCatalog.builtIn,
        isEnabled: (WorkflowLibraryItem) -> Bool = { WorkflowLibraryEnablementStore.shared.isWorkflowEnabled($0) }
    ) -> ToolsMenuModel {
        let workflowItems = catalog
            .filter { $0.capabilities.contains(.workflowOperations) }
        let categories = FASTQOperationCategoryID.allCases.map { categoryID in
            let workflows = workflowItems
                .filter { $0.categoryID == categoryID }
                .map { item in
                    let enabled = isEnabled(item)
                    return WorkflowEntry(
                        id: item.id,
                        toolID: item.toolID,
                        title: item.title,
                        isEnabled: enabled,
                        isInstallable: !enabled
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isEnabled != rhs.isEnabled {
                        return lhs.isEnabled && !rhs.isEnabled
                    }
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            return Category(
                id: categoryID,
                title: categoryID.menuTitle,
                workflows: workflows
            )
        }
        return ToolsMenuModel(categories: categories)
    }
}

extension FASTQOperationCategoryID {
    var menuTitle: String {
        switch self {
        case .qcReporting: return "QC & Reporting"
        case .demultiplexing: return "Demultiplexing"
        case .trimmingFiltering: return "Trimming & Filtering"
        case .decontamination: return "Decontamination"
        case .readProcessing: return "Read Processing"
        case .searchSubsetting: return "Search & Subsetting"
        case .alignment: return "Multiple Sequence Alignment"
        case .mapping: return "Mapping"
        case .assembly: return "Assembly"
        case .clustering: return "Clustering"
        case .classification: return "Classification"
        case .genotyping: return "Genotyping"
        }
    }
}
