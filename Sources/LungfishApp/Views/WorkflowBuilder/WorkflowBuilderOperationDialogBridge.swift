import Foundation
import LungfishIO
import LungfishWorkflow

@MainActor
enum WorkflowBuilderOperationDialogBridge {
    static let toolIDParameter = "workflow_builder_tool_id"
    static let operationSummaryParameter = "workflow_builder_operation_summary"

    static func availableToolIDs(for nodeType: WorkflowNodeType) -> [FASTQOperationToolID] {
        switch nodeType {
        case .qualityControl:
            return FASTQOperationDialogState.toolIDs(for: .qcReporting)
        case .trimming:
            return FASTQOperationDialogState.toolIDs(for: .trimmingFiltering)
        case .fastpDedup:
            return [.removeDuplicates]
        case .fastpTrim:
            return [.fastpTrim]
        case .deaconHumanScrub:
            return [.removeHumanReads]
        case .fastpMerge:
            return [.mergeOverlappingPairs]
        case .seqkitLengthFilter:
            return [.filterByReadLength]
        case .alignment, .variantCalling, .quantification, .assembly:
            return FASTQOperationToolID.allCases
        case .sampleInput, .fastqInput, .fastqBundleInput, .fastaInput, .bamInput, .sampleSheet, .report, .export, .projectOutput:
            return []
        }
    }

    static func defaultToolID(for nodeType: WorkflowNodeType) -> FASTQOperationToolID? {
        switch nodeType {
        case .qualityControl:
            return .refreshQCSummary
        case .trimming:
            return .fastpTrim
        case .fastpDedup:
            return .removeDuplicates
        case .fastpTrim:
            return .fastpTrim
        case .deaconHumanScrub:
            return .removeHumanReads
        case .fastpMerge:
            return .mergeOverlappingPairs
        case .seqkitLengthFilter:
            return .filterByReadLength
        case .alignment:
            return .minimap2
        case .variantCalling:
            return .viralRecon
        case .quantification:
            return .mafft
        case .assembly:
            return .spades
        case .sampleInput, .fastqInput, .fastqBundleInput, .fastaInput, .bamInput, .sampleSheet, .report, .export, .projectOutput:
            return nil
        }
    }

    static func selectedToolID(for node: WorkflowNode) -> FASTQOperationToolID? {
        if let rawValue = node.parameters[toolIDParameter],
           let toolID = FASTQOperationToolID(rawValue: rawValue),
           availableToolIDs(for: node.type).contains(toolID) {
            return toolID
        }
        return defaultToolID(for: node.type)
    }

    static func configureDialogToolIDs(for node: WorkflowNode) -> [FASTQOperationToolID] {
        guard let selectedToolID = selectedToolID(for: node) else { return [] }
        return [selectedToolID]
    }

    static func apply(state: FASTQOperationDialogState, to node: inout WorkflowNode) {
        switch node.type {
        case .fastpTrim where state.selectedToolID == .fastpTrim:
            node.parameters["detectAdapter"] = state.adapterRemovalMode == .autoDetect ? "true" : "false"
            node.parameters["quality"] = String(state.qualityTrimThreshold)
            node.parameters["window"] = String(state.qualityTrimWindowSize)
            node.parameters["cutMode"] = cutModeParameter(for: state.qualityTrimMode)
        case .fastpMerge where state.selectedToolID == .mergeOverlappingPairs:
            node.parameters["minOverlap"] = String(state.mergeOverlappingPairsMinOverlap)
        case .seqkitLengthFilter where state.selectedToolID == .filterByReadLength:
            node.parameters["minLength"] = state.filterByReadLengthMin.map(String.init) ?? "0"
            if let max = state.filterByReadLengthMax {
                node.parameters["maxLength"] = String(max)
            } else {
                node.parameters.removeValue(forKey: "maxLength")
            }
        case .deaconHumanScrub where state.selectedToolID == .removeHumanReads:
            node.parameters["database"] = "deacon-panhuman"
        case .fastpDedup where state.selectedToolID == .removeDuplicates:
            break
        case .alignment, .variantCalling, .quantification, .assembly, .qualityControl, .trimming:
            node.parameters[toolIDParameter] = state.selectedToolID.rawValue
            node.parameters[operationSummaryParameter] = state.selectedToolSummary
            node.label = state.selectedToolID.title
        default:
            break
        }
    }

    private static func cutModeParameter(for mode: FASTQQualityTrimMode) -> String {
        switch mode {
        case .cutRight:
            return "right"
        case .cutFront:
            return "front"
        case .cutTail:
            return "tail"
        case .cutBoth:
            return "both"
        }
    }
}
