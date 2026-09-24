import Foundation
import LungfishWorkflow

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

    /// One linked user workflow package (a `.lungfishflowpkg` registered in the Workflow Library).
    struct LinkedPackageEntry: Equatable, Sendable {
        /// The package manifest ID, which the Workflow Library uses to identify a card.
        let manifestID: String
        let title: String
        let isEnabled: Bool

        /// The tool ID the Workflow Operations window uses for this package.
        var workflowOperationToolID: String {
            "package.\(manifestID)"
        }

        var menuTitle: String {
            isEnabled ? "\(title)\u{2026}" : "\(title) (not enabled)"
        }
    }

    let categories: [Category]
    let linkedPackages: [LinkedPackageEntry]

    @MainActor
    static func build(
        catalog: [WorkflowLibraryItem] = WorkflowLibraryCatalog.builtIn,
        isEnabled: (WorkflowLibraryItem) -> Bool = { WorkflowLibraryEnablementStore.shared.isWorkflowEnabled($0) },
        linkedPackages: [WorkflowPackageValidationResult] = [],
        isPackageEnabled: (WorkflowPackageValidationResult) -> Bool = {
            WorkflowLibraryEnablementStore.shared.isUserWorkflowEnabled($0)
        }
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
        let packages = linkedPackages
            .map { package in
                LinkedPackageEntry(
                    manifestID: package.manifest.id,
                    title: package.manifest.name,
                    // A package that cannot execute is never enabled, whatever the store says.
                    isEnabled: package.supportsWorkflowLibraryExecution && isPackageEnabled(package)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isEnabled != rhs.isEnabled {
                    return lhs.isEnabled && !rhs.isEnabled
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        return ToolsMenuModel(categories: categories, linkedPackages: packages)
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
