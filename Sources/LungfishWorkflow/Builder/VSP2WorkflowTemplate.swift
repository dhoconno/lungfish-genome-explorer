// VSP2WorkflowTemplate.swift - Expanded Workflow Builder graph for VSP2 FASTQ processing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

public enum VSP2WorkflowTemplateError: Error, LocalizedError, Sendable, Equatable {
    case recipeNotFound(String)
    case unsupportedRecipeStep(String)

    public var errorDescription: String? {
        switch self {
        case .recipeNotFound(let id):
            return "Built-in recipe '\(id)' was not found"
        case .unsupportedRecipeStep(let type):
            return "Recipe step '\(type)' cannot be represented in the Workflow Builder"
        }
    }
}

public enum VSP2WorkflowTemplate {
    public static let recipeID = "vsp2-target-enrichment"

    public static func makeGraph(
        name: String = "VSP2 FASTQ Workflow",
        inputBundleRelativePath: String? = nil
    ) throws -> WorkflowGraph {
        let recipe = try bundledRecipe()

        var graph = WorkflowGraph(
            name: name,
            description: "Expanded VSP2 FASTQ bundle workflow",
            version: WorkflowVersion.defaultVersion
        )

        let input = try graph.addStableNode(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000501")!,
            type: .fastqBundleInput,
            label: "FASTQ bundle input",
            position: CGPoint(x: 120, y: 180),
            parameters: inputBundleRelativePath.map { ["bundle_path": $0] } ?? [:]
        )

        var previous = WorkflowStepEndpoint(node: input, outputPortID: "reads")
        for (index, step) in recipe.steps.enumerated() {
            let templateStep = try makeTemplateStep(for: step)
            let node = try graph.addStableNode(
                id: templateStep.id,
                type: templateStep.nodeType,
                label: step.label,
                position: CGPoint(x: 360 + (240 * index), y: 180),
                parameters: templateStep.parameters
            )

            try graph.addConnection(
                sourceNodeId: previous.node.id,
                sourcePortId: previous.outputPortID,
                targetNodeId: node.id,
                targetPortId: "reads"
            )
            previous = WorkflowStepEndpoint(node: node, outputPortID: templateStep.outputPortID)
        }

        var projectOutput = graph.projectOutput
        projectOutput.position = CGPoint(x: 360 + (240 * recipe.steps.count), y: 180)
        try graph.updateNode(projectOutput)

        try graph.addConnection(
            sourceNodeId: previous.node.id,
            sourcePortId: previous.outputPortID,
            targetNodeId: projectOutput.id,
            targetPortId: "input"
        )

        return graph
    }

    static func bundledRecipe() throws -> Recipe {
        guard let recipe = RecipeRegistryV2.builtinRecipes().first(where: { $0.id == recipeID }) else {
            throw VSP2WorkflowTemplateError.recipeNotFound(recipeID)
        }
        return recipe
    }

    private static func makeTemplateStep(for step: RecipeStep) throws -> TemplateStep {
        switch step.type {
        case "fastp-dedup":
            return TemplateStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000502")!,
                nodeType: .fastpDedup,
                outputPortID: "deduplicated",
                parameters: recipeParameters(step.params)
            )
        case "fastp-trim":
            return TemplateStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000503")!,
                nodeType: .fastpTrim,
                outputPortID: "trimmed",
                parameters: recipeParameters(step.params)
            )
        case "deacon-scrub":
            return TemplateStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000504")!,
                nodeType: .deaconHumanScrub,
                outputPortID: "scrubbed",
                parameters: recipeParameters(step.params)
            )
        case "fastp-merge":
            return TemplateStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000505")!,
                nodeType: .fastpMerge,
                outputPortID: "merged",
                parameters: recipeParameters(step.params)
            )
        case "seqkit-length-filter":
            return TemplateStep(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000506")!,
                nodeType: .seqkitLengthFilter,
                outputPortID: "filtered",
                parameters: recipeParameters(step.params)
            )
        default:
            throw VSP2WorkflowTemplateError.unsupportedRecipeStep(step.type)
        }
    }

    private static func recipeParameters(_ params: [String: AnyCodableValue]?) -> [String: String] {
        guard let params else { return [:] }
        return Dictionary(uniqueKeysWithValues: params.map { key, value in
            (key, stringValue(for: value))
        })
    }

    private static func stringValue(for value: AnyCodableValue) -> String {
        switch value {
        case .bool(let bool):
            return bool ? "true" : "false"
        case .int(let int):
            return String(int)
        case .double(let double):
            return String(double)
        case .string(let string):
            return string
        }
    }

    private struct WorkflowStepEndpoint {
        var node: WorkflowNode
        var outputPortID: String
    }

    private struct TemplateStep {
        var id: UUID
        var nodeType: WorkflowNodeType
        var outputPortID: String
        var parameters: [String: String]
    }
}
