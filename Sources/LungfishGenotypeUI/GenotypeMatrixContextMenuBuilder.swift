import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

struct GenotypeMatrixContextMenuBuilder {
    static func make(snapshot: GenotypeMatrixContextMenuSnapshot) -> GenotypeMatrixContextMenuState {
        let selectionTargets = snapshot.selectionTargets
        let capability = snapshot.capability
        let visibilityCapability = snapshot.visibilityCapability
        var visibilityItems: [GenotypeMatrixContextMenuItemState] = []
        var visibilitySubmenus: [GenotypeMatrixContextMenuSubmenuState] = []
        let rowItems = rowVisibilityItems(
            capability: visibilityCapability,
            selectedRowCallSampleCount: snapshot.selectedRowCallSampleCount
        )
        let columnItems = columnVisibilityItems(capability: visibilityCapability)
        switch visibilityCapability.selectionShape {
        case .rows:
            visibilityItems.append(contentsOf: rowItems)
        case .columns:
            visibilityItems.append(contentsOf: columnItems)
        case .cellRectangle, .sparseCells, .mixed:
            if !rowItems.isEmpty {
                visibilitySubmenus.append(.init(
                    kind: .rowVisibility,
                    title: "Row Visibility",
                    items: rowItems
                ))
            }
            if !columnItems.isEmpty {
                visibilitySubmenus.append(.init(
                    kind: .columnVisibility,
                    title: "Column Visibility",
                    items: columnItems
                ))
            }
        case .none:
            break
        }
        if visibilityCapability.canResetVisibility {
            visibilityItems.append(.init(
                title: visibilityCapability.showAllTitle,
                command: .resetVisibility,
                availability: .enabled,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ))
        }
        var items: [GenotypeMatrixContextMenuItemState] = [
            GenotypeMatrixContextMenuItemState(
                title: "Mark False Positive",
                command: .markFalsePositive,
                availability: capability.falsePositive,
                keyEquivalent: "p",
                keyModifierRawValue: snapshot.keyModifierRawValue
            ),
            GenotypeMatrixContextMenuItemState(
                title: "Mark False Negative",
                command: .markFalseNegative,
                availability: capability.falseNegative,
                // ⌥⌘X, not ⌥⌘N: ⌥⌘N is Window > New Window for Current
                // Project, and the matrix's key-equivalent handler would
                // pre-empt that menu item whenever the matrix had focus.
                keyEquivalent: "x",
                keyModifierRawValue: snapshot.keyModifierRawValue
            ),
            GenotypeMatrixContextMenuItemState(
                title: "Clear Review",
                command: .clearReview,
                availability: capability.clearReview,
                keyEquivalent: "r",
                keyModifierRawValue: snapshot.keyModifierRawValue
            ),
            GenotypeMatrixContextMenuItemState(
                title: commentMenuTitle(
                    capability: capability,
                    targetCount: selectionTargets.count
                ),
                command: .editComment,
                availability: capability.upsertComment,
                // No chord: ⌥⌘M is macOS's Minimize All.
                keyEquivalent: "",
                keyModifierRawValue: 0
            ),
            GenotypeMatrixContextMenuItemState(
                title: selectionTargets.count == 1 ? "Remove Comment" : "Remove Comments",
                command: .removeComments,
                availability: capability.removeComments,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ),
        ]
        if snapshot.manualHaplotypeEditSample != nil {
            items.insert(
                GenotypeMatrixContextMenuItemState(
                    title: "Edit Haplotype Assignments…",
                    command: .editManualHaplotypeAssignments,
                    availability: .enabled,
                    keyEquivalent: "",
                    keyModifierRawValue: 0
                ),
                at: 0
            )
        }
        if capability.selectionShape == .rows || capability.selectionShape == .columns {
            items.append(GenotypeMatrixContextMenuItemState(
                title: "Select Supported Cells (≥ 1 read)",
                command: .selectSupportedCells,
                availability: .enabled,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ))
        }
        return GenotypeMatrixContextMenuState(
            selectionTargets: selectionTargets,
            visibilityItems: visibilityItems,
            visibilitySubmenus: visibilitySubmenus,
            items: items,
            inspectedTargetCount: selectionTargets.count
        )
    }

    private static func rowVisibilityItems(
        capability: GenotypeMatrixVisibilityCapabilitySnapshot,
        selectedRowCallSampleCount: Int?
    ) -> [GenotypeMatrixContextMenuItemState] {
        guard capability.canHideSelectedRows else { return [] }
        var items: [GenotypeMatrixContextMenuItemState] = [
            .init(
                title: capability.hideSelectedRowsTitle,
                command: .hideSelectedRows,
                availability: .enabled,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ),
            .init(
                title: capability.showOnlySelectedRowsTitle,
                command: .showOnlySelectedRows,
                availability: .enabled,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ),
        ]
        if case .rows(count: 1) = capability.selectionShape,
           let selectedRowCallSampleCount {
            items.append(.init(
                title: "Show Only Columns with Calls in This Row",
                command: .showOnlyColumnsWithSelectedRowCalls,
                availability: selectedRowCallSampleCount > 0
                    ? .enabled
                    : .disabled(reason: "This row has no genotype calls with read support."),
                keyEquivalent: "",
                keyModifierRawValue: 0
            ))
        }
        return items
    }

    private static func columnVisibilityItems(
        capability: GenotypeMatrixVisibilityCapabilitySnapshot
    ) -> [GenotypeMatrixContextMenuItemState] {
        guard capability.canHideSelectedColumns else { return [] }
        return [
            .init(
                title: capability.hideSelectedColumnsTitle,
                command: .hideSelectedColumns,
                availability: .enabled,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ),
            .init(
                title: capability.showOnlySelectedColumnsTitle,
                command: .showOnlySelectedColumns,
                availability: .enabled,
                keyEquivalent: "",
                keyModifierRawValue: 0
            ),
        ]
    }

    private static func commentMenuTitle(
        capability: GenotypeMatrixReviewCapabilityState,
        targetCount: Int
    ) -> String {
        switch capability.commentState {
        case .none:
            return "Add Comment…"
        case .uniform:
            return targetCount == 1 ? "Edit Comment…" : "Replace Comments…"
        case .mixed:
            return "Replace Comments…"
        }
    }
}
