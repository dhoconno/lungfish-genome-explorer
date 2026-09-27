// WorkflowExportGraph.swift - The file-name DAG behind the Nextflow and Snakemake exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A provenance chain is a flat list of steps whose inputs and outputs are
// file records. Two things about that list break a workflow engine when it
// is transcribed one step per process or rule:
//
// 1. A wrapper step and the tool it ran both record the same output
//    (`lungfish-cli import fastq` and the clumpify it launched both claim
//    the bundle's FASTQ), so a file has several producers. Snakemake
//    refuses an ambiguous producer; Nextflow does not care, but the
//    previous renderer chained processes positionally (`NEXT(PREV.out)`)
//    and so handed a two-input process one channel, which fails to compile.
// 2. A step can record its own input among its outputs (samtools flagstat
//    on a sorted BAM lists the BAM), which is a cycle to Snakemake.
//
// This graph settles both once, for both renderers: inputs and outputs are
// deduplicated, a step's own inputs are dropped from its outputs, every
// input is traced to the most recent earlier producer of that file (or to
// a pipeline parameter when nothing earlier wrote it), and for Snakemake a
// path keeps its earliest producer only (a `ruleorder` does not settle
// two wildcard-free rules with the same output in Snakemake 9).

import Foundation

struct WorkflowExportGraph {
    struct Node {
        let index: Int
        let step: StepExecution
        /// Input file names, once each, in recorded order.
        let inputFilenames: [String]
        /// Output file names, once each, minus the step's own inputs.
        let outputFilenames: [String]
        /// Input paths, once each, in recorded order.
        let inputPaths: [String]
        /// Output paths, once each, minus the step's own inputs.
        let outputPaths: [String]
        /// ``outputPaths`` minus the paths an earlier step already claims,
        /// so every path has one producing rule.
        let uniqueOutputPaths: [String]

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
    }

    let nodes: [Node]
    /// File names read by some step that no earlier step wrote, once each,
    /// in first-use order. These are the pipeline's parameters.
    let parameterFilenames: [String]
    private let parameterPaths: [String: String]

    init(run: WorkflowRun) {
        var nodes: [Node] = []
        var producedFilenames = Set<String>()
        var parameterFilenames: [String] = []
        var parameterPaths: [String: String] = [:]
        var claimedPaths = Set<String>()

        for (offset, step) in run.steps.enumerated() {
            let inputFilenames = Self.unique(step.inputs.map(\.filename))
            let inputPaths = Self.unique(step.inputs.map(\.path))
            let inputFilenameSet = Set(inputFilenames)
            let inputPathSet = Set(inputPaths)
            let outputFilenames = Self.unique(step.outputs.map(\.filename)).filter { !inputFilenameSet.contains($0) }
            let outputPaths = Self.unique(step.outputs.map(\.path)).filter { !inputPathSet.contains($0) }
            let uniqueOutputPaths = outputPaths.filter { !claimedPaths.contains($0) }
            let node = Node(
                index: offset + 1,
                step: step,
                inputFilenames: inputFilenames,
                outputFilenames: outputFilenames,
                inputPaths: inputPaths,
                outputPaths: outputPaths,
                uniqueOutputPaths: uniqueOutputPaths
            )

            for input in step.inputs where !producedFilenames.contains(input.filename) {
                if parameterPaths[input.filename] == nil {
                    parameterFilenames.append(input.filename)
                    parameterPaths[input.filename] = input.path
                }
            }
            for output in outputFilenames {
                producedFilenames.insert(output)
            }
            for path in uniqueOutputPaths {
                claimedPaths.insert(path)
            }
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

    /// The recorded path behind a parameter file name.
    func parameterPath(for filename: String) -> String? {
        parameterPaths[filename]
    }

    /// The paths a Snakemake `rule all` asks for: every produced path that
    /// no later step reads, so the whole chain is planned.
    var finalOutputPaths: [String] {
        var terminal: [String] = []
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
        s = s.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        if let first = s.first, first.isNumber {
            s = "_" + s
        }
        return s.lowercased()
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
