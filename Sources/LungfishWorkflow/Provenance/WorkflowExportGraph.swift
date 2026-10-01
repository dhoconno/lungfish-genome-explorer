// WorkflowExportGraph.swift - The file DAG behind the Nextflow and Snakemake exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// An export plan is a flat list of steps whose inputs and outputs are file
// records. Two things about that list break a workflow engine when it is
// transcribed one step per process or rule:
//
// 1. A wrapper step and the tool it ran both record the same output
//    (`lungfish-cli import fastq` and the clumpify it launched both claim
//    the bundle's FASTQ), so a file has several producers. Snakemake
//    refuses an ambiguous producer; Nextflow does not care, but chaining
//    processes positionally hands a two-input process one channel, which
//    fails to compile.
// 2. A step can record its own input among its outputs (samtools flagstat
//    on a sorted BAM lists the BAM), which is a cycle to Snakemake.
//
// This graph settles both once, for both renderers, over the plan's
// portable paths: inputs and outputs are deduplicated, a step's own inputs
// are dropped from its outputs, every input is traced to the most recent
// earlier producer of that file (or to a pipeline parameter when nothing
// earlier wrote it), and for Snakemake a path keeps its earliest producer
// only (a `ruleorder` does not settle two wildcard-free rules with the same
// output in Snakemake 9).

import Foundation

struct WorkflowExportGraph {
    typealias MappedPath = ProvenanceExportPlan.MappedPath

    struct Node {
        /// The recorded 1-based number of the step (the first, for a pipe).
        let index: Int
        let step: ProvenanceExportPlan.Step
        /// Input file names, once each, in recorded order.
        let inputFilenames: [String]
        /// Output file names, once each, minus the step's own inputs.
        let outputFilenames: [String]
        /// Portable input paths, once each, in recorded order, minus the
        /// files an in-app step made (the export cannot produce them).
        let inputPaths: [MappedPath]
        /// Inputs an in-app step made, named in a comment instead.
        let inAppInputPaths: [MappedPath]
        /// Portable output paths, once each, minus the step's own inputs.
        let outputPaths: [MappedPath]
        /// ``outputPaths`` minus the paths an earlier step already claims,
        /// so every path has one producing rule.
        let uniqueOutputPaths: [MappedPath]

        var nextflowProcessName: String {
            "\(WorkflowExportGraph.sanitize(step.toolName).uppercased())_\(index)"
        }

        var snakemakeRuleName: String {
            "\(WorkflowExportGraph.sanitize(step.toolName))_\(index)"
        }
    }

    enum InputSource {
        /// An earlier process wrote the file as its output at this index.
        case process(Node, outputIndex: Int)
        /// No earlier process wrote the file; it is a pipeline parameter.
        case parameter

        var isParameter: Bool {
            if case .parameter = self { return true }
            return false
        }
    }

    let nodes: [Node]
    /// File names read by some step that no earlier step wrote, once each,
    /// in first-use order. These are the pipeline's parameters.
    let parameterFilenames: [String]
    private let parameterPaths: [String: MappedPath]

    /// The graph of the replayable steps of `run`.
    init(run: WorkflowRun) {
        self.init(plan: ProvenanceExportPlan(run: run, replayArguments: { $0.durableReplayArgv ?? $0.command }))
    }

    /// The graph of the plan's replayable steps. Nodes keep the step's
    /// recorded number, so a skipped step leaves a gap rather than
    /// renumbering the steps after it.
    init(plan: ProvenanceExportPlan) {
        var nodes: [Node] = []
        var producedFilenames = Set<String>()
        var parameterFilenames: [String] = []
        var parameterPaths: [String: MappedPath] = [:]
        var claimedPaths: [MappedPath] = []
        let inAppOutputs = Set(plan.inAppSteps.flatMap { $0.outputs.map { plan.map($0.path) } })

        for step in plan.replayableSteps {
            let allInputs = step.inputs.filter { !$0.path.hasPrefix("pipe:") }
            let inputs = allInputs.filter { !inAppOutputs.contains(plan.map($0.path)) }
            let inAppInputPaths = Self.unique(allInputs.map { plan.map($0.path) }.filter { inAppOutputs.contains($0) })
            let outputs = step.outputs.filter { !$0.path.hasPrefix("pipe:") }
            let inputFilenames = Self.unique(inputs.map(\.filename))
            let inputPaths = Self.unique(inputs.map { plan.map($0.path) })
            let inputFilenameSet = Set(inputFilenames)
            let outputFilenames = Self.unique(outputs.map(\.filename)).filter { !inputFilenameSet.contains($0) }
            let outputPaths = Self.unique(outputs.map { plan.map($0.path) }).filter { !inputPaths.contains($0) }
            let uniqueOutputPaths = outputPaths.filter { !claimedPaths.contains($0) }
            let node = Node(
                index: step.number,
                step: step,
                inputFilenames: inputFilenames,
                outputFilenames: outputFilenames,
                inputPaths: inputPaths,
                inAppInputPaths: inAppInputPaths,
                outputPaths: outputPaths,
                uniqueOutputPaths: uniqueOutputPaths
            )

            for input in inputs where !producedFilenames.contains(input.filename) {
                if parameterPaths[input.filename] == nil {
                    parameterFilenames.append(input.filename)
                    parameterPaths[input.filename] = plan.map(input.path)
                }
            }
            for output in outputFilenames {
                producedFilenames.insert(output)
            }
            claimedPaths += uniqueOutputPaths
            nodes.append(node)
        }

        self.nodes = nodes
        self.parameterFilenames = parameterFilenames
        self.parameterPaths = parameterPaths
    }

    /// Where `node` reads the file named `filename` from.
    func source(of filename: String, before node: Node) -> InputSource {
        for candidate in nodes.reversed() where candidate.index < node.index {
            if let outputIndex = candidate.outputFilenames.firstIndex(of: filename) {
                return .process(candidate, outputIndex: outputIndex)
            }
        }
        return .parameter
    }

    /// The `params` key for a file name (`reads.fastq.gz` becomes
    /// `reads_fastq_gz`).
    func parameterName(for filename: String) -> String {
        Self.sanitize(filename.replacingOccurrences(of: ".", with: "_"))
    }

    /// The portable path behind a parameter file name.
    func parameterPath(for filename: String) -> MappedPath? {
        parameterPaths[filename]
    }

    /// The paths a Snakemake `rule all` asks for: every produced path that
    /// no later step reads, so the whole chain is planned.
    var finalOutputPaths: [MappedPath] {
        var terminal: [MappedPath] = []
        for node in nodes {
            for path in node.uniqueOutputPaths {
                let consumedLater = nodes.contains { $0.index > node.index && $0.inputPaths.contains(path) }
                if !consumedLater {
                    terminal.append(path)
                }
            }
        }
        return terminal.isEmpty ? Self.unique(nodes.flatMap(\.uniqueOutputPaths)) : terminal
    }

    static func sanitize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: " ", with: "_")
        s = s.replacingOccurrences(of: "-", with: "_")
        s = s.replacingOccurrences(of: "|", with: "_")
        s = s.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        while s.contains("__") { s = s.replacingOccurrences(of: "__", with: "_") }
        if let first = s.first, first.isNumber {
            s = "_" + s
        }
        return s.lowercased()
    }

    private static func unique<T: Equatable>(_ values: [T]) -> [T] {
        var result: [T] = []
        for value in values where !result.contains(value) {
            result.append(value)
        }
        return result
    }
}
