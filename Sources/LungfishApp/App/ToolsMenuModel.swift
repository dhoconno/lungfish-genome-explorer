import Foundation
import LungfishWorkflow

struct ToolsMenuModel: Equatable, Sendable {
    struct WorkflowEntry: Equatable, Sendable {
        let id: String
        let toolID: FASTQOperationToolID?
        let title: String
        let isEnabled: Bool
        let isInstallable: Bool

        /// What the menu item carries so its action can find the catalog item.
        /// `ToolsMenuModel.catalogItem(forRepresentedObject:)` reads it back.
        var representedObject: Any {
            toolID ?? id
        }

        /// The item's title. A workflow that is not enabled offers to enable
        /// itself, in the same type as every other item.
        var menuTitle: String {
            isEnabled ? "\(title)\u{2026}" : "Enable \(title)\u{2026}"
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
        /// Whether this build can run the package. A command-runner package
        /// can only be shown in the Workflow Library, never enabled.
        let canRun: Bool

        init(manifestID: String, title: String, isEnabled: Bool, canRun: Bool = true) {
            self.manifestID = manifestID
            self.title = title
            self.isEnabled = isEnabled
            self.canRun = canRun
        }

        /// The tool ID the Workflow Operations window uses for this package.
        var workflowOperationToolID: String {
            "package.\(manifestID)"
        }

        /// An enabled package launches. One that can run but is not enabled
        /// offers to enable itself. One this build cannot run only opens its
        /// card in the Workflow Library, so its title names that and nothing
        /// it cannot do.
        var menuTitle: String {
            if isEnabled { return "\(title)\u{2026}" }
            return canRun ? "Enable \(title)\u{2026}" : "Show \(title) in Workflow Library"
        }
    }

    let categories: [Category]
    let linkedPackages: [LinkedPackageEntry]

    /// The catalog item a Tools menu workflow item stands for, from the
    /// represented object `WorkflowEntry` gives it (a tool ID or a catalog item
    /// ID). The enable prompt names the workflow from the catalog item and
    /// never from the item's title.
    static func catalogItem(forRepresentedObject representedObject: Any?) -> WorkflowLibraryItem? {
        if let toolID = representedObject as? FASTQOperationToolID {
            return WorkflowLibraryCatalog.item(for: toolID)
        }
        if let id = representedObject as? String {
            return WorkflowLibraryCatalog.item(id: id)
        }
        return nil
    }

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
                title: categoryID.displayName,
                workflows: workflows
            )
        }
        let packages = linkedPackages
            .map { package in
                LinkedPackageEntry(
                    manifestID: package.manifest.id,
                    title: package.manifest.name,
                    // A package that cannot execute is never enabled, whatever the store says.
                    isEnabled: package.supportsWorkflowLibraryExecution && isPackageEnabled(package),
                    canRun: package.supportsWorkflowLibraryExecution
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
