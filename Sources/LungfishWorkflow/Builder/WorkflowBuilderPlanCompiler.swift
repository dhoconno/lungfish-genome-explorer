// WorkflowBuilderPlanCompiler.swift - Compile builder graphs into native FASTQ run plans
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct WorkflowBuilderExecutablePlan: Sendable, Codable, Equatable {
    public let graphID: UUID
    public let workflowName: String
    public let inputBundleNodeID: UUID
    public let inputBundleURL: URL
    public let projectURL: URL
    public let runDirectoryURL: URL
    public let recipe: Recipe
    public let argv: [String]
    public let steps: [WorkflowBuilderExecutableStep]
}

public struct WorkflowBuilderExecutableStep: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let nodeID: UUID
    public let nodeType: WorkflowNodeType
    public let label: String
    public let operation: String
    public let parameters: [String: String]
    public let inputBundleURL: URL
    public let outputBundleURL: URL
    public let argv: [String]
}

public enum WorkflowBuilderPlanCompilerError: Error, LocalizedError, Sendable, Equatable {
    case validationFailed([WorkflowValidationIssue])
    case missingFastqBundleInput
    case multipleFastqBundleInputs([UUID])
    case unsupportedNode(nodeID: UUID, type: WorkflowNodeType)
    case nonLinearGraph(nodeID: UUID, reason: String)
    case missingProjectOutput
    case inputBundleOutsideProject(String)
    case inputBundleNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .validationFailed(let issues):
            return "Workflow validation failed: \(issues.map(\.description).joined(separator: "; "))"
        case .missingFastqBundleInput:
            return "Workflow requires one explicit FASTQ bundle input node."
        case .multipleFastqBundleInputs(let ids):
            return "Workflow has multiple FASTQ bundle inputs: \(ids.map(\.uuidString).joined(separator: ", "))"
        case .unsupportedNode(_, let type):
            return "Workflow Builder runner does not support node type \(type.displayName)."
        case .nonLinearGraph(_, let reason):
            return "Workflow Builder runner requires a single linear FASTQ chain: \(reason)"
        case .missingProjectOutput:
            return "Workflow must connect the final FASTQ operation to Project output."
        case .inputBundleOutsideProject(let path):
            return "FASTQ bundle input is outside the active project: \(path)"
        case .inputBundleNotFound(let path):
            return "FASTQ bundle input was not found: \(path)"
        }
    }
}

public struct WorkflowBuilderPlanCompiler: Sendable {
    public init() {}

    public func compile(
        graph: WorkflowGraph,
        projectURL: URL,
        runDirectoryURL: URL,
        lungfishCLIExecutable: String = "lungfish-cli"
    ) throws -> WorkflowBuilderExecutablePlan {
        let blockingIssues = graph.validate().filter { $0.severity == .error }
        guard blockingIssues.isEmpty else {
            throw WorkflowBuilderPlanCompilerError.validationFailed(blockingIssues)
        }

        let inputNode = try fastqBundleInputNode(in: graph)
        let inputBundleURL = try resolveInputBundleURL(for: inputNode, projectURL: projectURL)
        try validateSupportedNodes(in: graph)

        var currentNode = inputNode
        var currentBundleURL = inputBundleURL
        var executableSteps: [WorkflowBuilderExecutableStep] = []
        var recipeSteps: [RecipeStep] = []
        var visitedExecutableNodeIDs = Set<UUID>()

        while true {
            let outgoing = graph.outgoingConnections(from: currentNode.id)
            if outgoing.isEmpty {
                throw WorkflowBuilderPlanCompilerError.missingProjectOutput
            }
            guard outgoing.count == 1 else {
                throw WorkflowBuilderPlanCompilerError.nonLinearGraph(
                    nodeID: currentNode.id,
                    reason: "Node '\(currentNode.label)' must have exactly one outgoing connection."
                )
            }

            let connection = outgoing[0]
            guard let targetNode = graph.getNode(connection.targetNodeId) else {
                throw WorkflowBuilderPlanCompilerError.nonLinearGraph(
                    nodeID: currentNode.id,
                    reason: "Connection target is missing."
                )
            }

            if targetNode.type == .projectOutput {
                let incoming = graph.incomingConnections(to: targetNode.id)
                guard incoming.count == 1,
                      incoming[0].sourceNodeId == currentNode.id else {
                    throw WorkflowBuilderPlanCompilerError.nonLinearGraph(
                        nodeID: targetNode.id,
                        reason: "Project output must receive exactly one input from the executable chain."
                    )
                }
                break
            }

            guard let operation = Self.recipeOperation(for: targetNode.type) else {
                throw WorkflowBuilderPlanCompilerError.unsupportedNode(nodeID: targetNode.id, type: targetNode.type)
            }

            let incoming = graph.incomingConnections(to: targetNode.id)
            guard incoming.count == 1 else {
                throw WorkflowBuilderPlanCompilerError.nonLinearGraph(
                    nodeID: targetNode.id,
                    reason: "Node '\(targetNode.label)' must have exactly one input."
                )
            }

            let stepIndex = executableSteps.count + 1
            let parameters = try resolvedStringParameters(for: targetNode)
            let outputBundleURL = outputBundleURL(
                for: targetNode,
                stepIndex: stepIndex,
                runDirectoryURL: runDirectoryURL
            )
            let argv = stepArgv(
                executable: lungfishCLIExecutable,
                operation: operation,
                inputBundleURL: currentBundleURL,
                outputBundleURL: outputBundleURL,
                parameters: parameters
            )
            let step = WorkflowBuilderExecutableStep(
                id: targetNode.id,
                nodeID: targetNode.id,
                nodeType: targetNode.type,
                label: targetNode.label,
                operation: operation,
                parameters: parameters,
                inputBundleURL: currentBundleURL,
                outputBundleURL: outputBundleURL,
                argv: argv
            )
            executableSteps.append(step)
            recipeSteps.append(RecipeStep(
                type: operation,
                label: targetNode.label,
                params: try recipeParameters(for: targetNode)
            ))
            visitedExecutableNodeIDs.insert(targetNode.id)
            currentNode = targetNode
            currentBundleURL = outputBundleURL
        }

        let expectedExecutableNodeIDs = Set(graph.allNodes.filter { node in
            Self.recipeOperation(for: node.type) != nil
        }.map(\.id))
        if let unvisited = expectedExecutableNodeIDs.subtracting(visitedExecutableNodeIDs).first,
           let node = graph.getNode(unvisited) {
            throw WorkflowBuilderPlanCompilerError.nonLinearGraph(
                nodeID: node.id,
                reason: "Node '\(node.label)' is not on the executable chain."
            )
        }

        let planArgv = [
            lungfishCLIExecutable,
            "workflow",
            "builder-run",
            "--project",
            projectURL.standardizedFileURL.path,
            "--run-directory",
            runDirectoryURL.standardizedFileURL.path,
            "--graph-id",
            graph.id.uuidString,
            "--input-bundle",
            inputBundleURL.path,
        ]
        let metadataRecipe = Self.matchingBuiltinRecipe(for: recipeSteps)
        let recipe = Recipe(
            formatVersion: metadataRecipe?.formatVersion ?? 1,
            id: "workflow-builder-\(graph.id.uuidString)",
            name: graph.name,
            description: graph.description ?? metadataRecipe?.description,
            author: metadataRecipe?.author,
            tags: metadataRecipe?.tags ?? [],
            platforms: metadataRecipe?.platforms ?? [.illumina],
            requiredInput: metadataRecipe?.requiredInput ?? .any,
            qualityBinning: metadataRecipe?.qualityBinning,
            steps: recipeSteps
        )

        return WorkflowBuilderExecutablePlan(
            graphID: graph.id,
            workflowName: graph.name,
            inputBundleNodeID: inputNode.id,
            inputBundleURL: inputBundleURL,
            projectURL: projectURL.standardizedFileURL,
            runDirectoryURL: runDirectoryURL.standardizedFileURL,
            recipe: recipe,
            argv: planArgv,
            steps: executableSteps
        )
    }

    private func fastqBundleInputNode(in graph: WorkflowGraph) throws -> WorkflowNode {
        let inputs = graph.allNodes.filter { $0.type == .fastqBundleInput }
        guard let input = inputs.first else {
            throw WorkflowBuilderPlanCompilerError.missingFastqBundleInput
        }
        guard inputs.count == 1 else {
            throw WorkflowBuilderPlanCompilerError.multipleFastqBundleInputs(inputs.map(\.id))
        }
        return input
    }

    private func resolveInputBundleURL(for node: WorkflowNode, projectURL: URL) throws -> URL {
        let resolved = try node.resolvedParameters()
        guard case .string(let rawPath)? = resolved["bundle_path"] else {
            throw WorkflowBuilderPlanCompilerError.validationFailed([
                .missingNodeParameter(nodeId: node.id, nodeName: node.label, parameter: "bundle_path")
            ])
        }
        let project = projectURL.standardizedFileURL
        let url: URL
        if rawPath.hasPrefix("@/") {
            url = project.appendingPathComponent(String(rawPath.dropFirst(2))).standardizedFileURL
        } else {
            url = URL(fileURLWithPath: rawPath).standardizedFileURL
        }

        try validateProjectContainment(url: url, projectURL: project)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              url.pathExtension.lowercased() == "lungfishfastq" else {
            throw WorkflowBuilderPlanCompilerError.inputBundleNotFound(url.path)
        }
        return url
    }

    private func validateProjectContainment(url: URL, projectURL: URL) throws {
        let root = projectURL.standardizedFileURL.path
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(normalizedRoot) else {
            throw WorkflowBuilderPlanCompilerError.inputBundleOutsideProject(target)
        }

        let resolvedRoot = projectURL.resolvingSymlinksInPath().standardizedFileURL.path
        let normalizedResolvedRoot = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        let resolvedTarget = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedTarget.hasPrefix(normalizedResolvedRoot) else {
            throw WorkflowBuilderPlanCompilerError.inputBundleOutsideProject(target)
        }
    }

    private func validateSupportedNodes(in graph: WorkflowGraph) throws {
        for node in graph.allNodes where !node.isPinned && node.type != .fastqBundleInput {
            guard Self.recipeOperation(for: node.type) != nil else {
                throw WorkflowBuilderPlanCompilerError.unsupportedNode(nodeID: node.id, type: node.type)
            }
        }
    }

    private func outputBundleURL(
        for node: WorkflowNode,
        stepIndex: Int,
        runDirectoryURL: URL
    ) -> URL {
        let directory = runDirectoryURL
            .standardizedFileURL
            .appendingPathComponent("intermediates", isDirectory: true)
        let filename = "\(String(format: "%02d", stepIndex))-\(slug(for: node.type.rawValue)).lungfishfastq"
        return directory.appendingPathComponent(filename, isDirectory: true)
    }

    private func stepArgv(
        executable: String,
        operation: String,
        inputBundleURL: URL,
        outputBundleURL: URL,
        parameters: [String: String]
    ) -> [String] {
        var argv = [
            executable,
            "workflow",
            "builder-step",
            "run",
            "--operation",
            operation,
            "--input-bundle",
            inputBundleURL.path,
            "--output-bundle",
            outputBundleURL.path,
        ]
        for key in parameters.keys.sorted() {
            argv.append("--param")
            argv.append("\(key)=\(parameters[key] ?? "")")
        }
        return argv
    }

    private func resolvedStringParameters(for node: WorkflowNode) throws -> [String: String] {
        try node.resolvedParameters().reduce(into: [:]) { result, pair in
            result[pair.key] = stringValue(for: pair.value)
        }
    }

    private func recipeParameters(for node: WorkflowNode) throws -> [String: AnyCodableValue] {
        try node.resolvedParameters().reduce(into: [:]) { result, pair in
            result[pair.key] = anyCodableValue(for: pair.value)
        }
    }

    private func stringValue(for value: ParameterValue) -> String {
        switch value {
        case .string(let string):
            return string
        case .integer(let integer):
            return String(integer)
        case .number(let number):
            return String(number)
        case .boolean(let boolean):
            return boolean ? "true" : "false"
        case .file(let url):
            return url.path
        case .array(let values):
            return values.map { stringValue(for: $0) }.joined(separator: ",")
        case .dictionary, .null:
            return ""
        }
    }

    private func anyCodableValue(for value: ParameterValue) -> AnyCodableValue {
        switch value {
        case .string(let string):
            return .string(string)
        case .integer(let integer):
            return .int(integer)
        case .number(let number):
            return .double(number)
        case .boolean(let boolean):
            return .bool(boolean)
        case .file(let url):
            return .string(url.path)
        case .array(let values):
            return .string(values.map { stringValue(for: $0) }.joined(separator: ","))
        case .dictionary, .null:
            return .string("")
        }
    }

    private func slug(for value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
    }

    public static func recipeOperation(for nodeType: WorkflowNodeType) -> String? {
        switch nodeType {
        case .fastpDedup:
            return "fastp-dedup"
        case .fastpTrim:
            return "fastp-trim"
        case .deaconHumanScrub:
            return "deacon-scrub"
        case .fastpMerge:
            return "fastp-merge"
        case .seqkitLengthFilter:
            return "seqkit-length-filter"
        case .sampleInput, .fastqInput, .fastqBundleInput, .fastaInput, .bamInput, .sampleSheet, .qualityControl, .trimming, .alignment, .variantCalling, .quantification, .assembly, .report, .export, .projectOutput:
            return nil
        }
    }

    private static func matchingBuiltinRecipe(for recipeSteps: [RecipeStep]) -> Recipe? {
        let stepTypes = recipeSteps.map(\.type)
        return RecipeRegistryV2.builtinRecipes().first { recipe in
            recipe.steps.map(\.type) == stepTypes
        }
    }
}
