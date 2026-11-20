// RNASeqCellMapCompute+Run.swift - The launch of rnaseq cell-map compute and its hand-off to the writer (Phase 5.5 lane CM-COMPUTE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The run checks everything it can before the launch, runs `embed.py` through `CondaManager.runTool` in a temporary
// folder of its own, checks the route's record, turns the route's table into LGE's table and hands it to the import's
// checker and the one writer, which copies it under `source/compute/` and writes all of 5.5 L3. It writes nothing of its
// own. The temporary folder is removed on every path, a cancel included, and the writer discards its stage on any error.

import Foundation
import LungfishCore
import LungfishIO

extension RNASeqCellMapCompute {
    public static let keptTable = "source/compute/embedding.tsv"

    public struct Options: Sendable {
        public var parent: URL
        public var threads: Int
        public var seed: Int

        public init(parent: URL, threads: Int = 1, seed: Int = 0) {
            (self.parent, self.threads, self.seed) = (parent, threads, seed)
        }
    }

    /// Runs `python` in the route's environment with the given arguments and variables, and hands each stderr line on.
    public typealias Launch = @Sendable (
        _ arguments: [String], _ environment: [String: String], _ stderr: @escaping @Sendable (String) -> Void
    ) async throws -> (stdout: String, stderr: String, exitCode: Int32)

    /// The launch through `CondaManager.runTool`, which runs `micromamba run -n sc-embed python ...` on `ToolProcess`
    /// with the hermetic environment plus the given variables. A cancel stops the process group and every descendant.
    public static func condaLaunch(_ manager: CondaManager = .shared) -> Launch {
        { arguments, environment, stderr in
            guard FileManager.default.fileExists(atPath: await manager.environmentURL(named: environmentName).path) else {
                throw RNASeqCellMapComputeRefusal.notInstalled
            }
            return try await manager.runTool(name: "python", arguments: arguments, environment: environmentName,
                                             environmentVariables: environment, stdoutHandler: nil, stderrHandler: stderr)
        }
    }

    /// What the checks before the launch found.
    public struct Prepared: Sendable {
        public var parent: URL
        public var parentName: String
        public var inputs: [Input]
        public var memory: MemoryPrediction
        public var threads: Int
        public var seed: Int
    }

    /// The facts of a finished route run, which the record names.
    public struct Run: Sendable {
        public var prepared: Prepared
        /// The route's `record.json`, checked by ``checkRecord(_:)``.
        public var record: Data
        public var packages: Data
        public var tableSHA256: String
        public var checked: RNASeqCellMapImport.Checked
        public var exitCode: Int32
    }

    /// Every check that needs no launch, in this order: the seed and threads, the output, the parent, the memory
    /// prediction from the manifest, and the sha256 of each matrix file the route will read.
    public static func prepare(_ options: Options, output: URL, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws -> Prepared {
        guard options.threads >= 1 else { throw RNASeqCellMapComputeRefusal.threads(options.threads) }
        guard options.seed == 0 else { throw RNASeqCellMapComputeRefusal.seed(options.seed) }
        try RNASeqPseudobulk.checkOutput(output)
        var ancestor = output.deletingLastPathComponent()
        while ancestor.path != "/" && !ancestor.path.isEmpty {
            if RNASeqResultBundle.isBundleURL(ancestor) { throw RNASeqCellMapImportRefusal.outputInsideResult(result: ancestor.lastPathComponent) }
            ancestor = ancestor.deletingLastPathComponent()
        }
        let manifest = try RNASeqResultBundle.loadManifest(from: options.parent)
        guard manifest.modality == .singleCell else {
            throw RNASeqCellMapError.parentNotSingleCell(name: manifest.name, isCellMap: manifest.modality == .cellMap)
        }
        let matrices = manifest.matrices ?? []
        let memory = MemoryPrediction(cells: matrices.reduce(0) { $0 + $1.cellCount }, entries: matrices.reduce(0) { $0 + $1.entryCount },
                                      physicalMemory: physicalMemory)
        try checkMemory(memory)
        return Prepared(parent: options.parent.standardizedFileURL, parentName: manifest.name, inputs: try inputs(of: options.parent, manifest: manifest),
                        memory: memory, threads: options.threads, seed: options.seed)
    }

    /// The bundled `embed.py`.
    public static func bundledScript() throws -> URL {
        guard let url = RuntimeResourceLocator.path("ManagedTools/sc-embed/\(scriptName)", in: .workflow)
            ?? Bundle.module.url(forResource: "embed", withExtension: "py", subdirectory: "ManagedTools/sc-embed") else {
            throw RNASeqCellMapComputeRefusal.scriptChanged(found: "missing")
        }
        return url
    }

    /// The bundled explicit lock of the route's environment.
    public static func bundledLock() throws -> URL {
        guard let url = RuntimeResourceLocator.path("ManagedTools/\(lockResource)", in: .workflow)
            ?? Bundle.module.url(forResource: "sc-embed-osx-arm64-explicit", withExtension: "txt", subdirectory: "ManagedTools") else {
            throw RNASeqCellMapComputeRefusal.notInstalled
        }
        return url
    }

    /// Runs the route on `options.parent` and writes the cell map `output` through `writer`. `step` gets LGE's own
    /// lines and `log` each line the script writes to stderr.
    @discardableResult
    public static func compute(
        _ options: Options, output: URL, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        launch: Launch, writer: RNASeqResultWriter, script: URL? = nil,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        step: (String) -> Void = { _ in }, log: @escaping @Sendable (String) -> Void = { _ in },
        makeEnvelope: (Run, RNASeqResultWriter.CellMapSummary) throws -> ProvenanceEnvelope
    ) async throws -> (run: Run, summary: RNASeqResultWriter.CellMapSummary) {
        let startedAt = Date()
        let prepared = try prepare(options, output: output, physicalMemory: physicalMemory)
        let script = try script ?? bundledScript()
        let found = try RNASeqResultBundle.sha256Hex(fileAt: script)
        guard found == scriptSHA256 else { throw RNASeqCellMapComputeRefusal.scriptChanged(found: found) }

        let fileManager = FileManager.default
        let temporary = temporaryRoot.appendingPathComponent("lungfish-cell-map-compute-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }
        for (_, folder) in cacheVariables {
            try fileManager.createDirectory(at: temporary.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: false)
        }
        let lock = temporary.appendingPathComponent(lockName)
        try fileManager.copyItem(at: try bundledLock(), to: lock)
        let out = temporary.appendingPathComponent("out", isDirectory: true)

        // Vote S-2 condition 7: the step line names the cell count and "exact", with no bar.
        step("Computing a cell map of \(RNASeqCellMapImportRefusal.count(prepared.memory.cells, "cell")) with exact nearest neighbours "
             + "at \(prepared.threads) \(prepared.threads == 1 ? "thread" : "threads").")
        let argv = arguments(script: script, inputs: prepared.inputs, output: out, lock: lock, threads: prepared.threads, seed: prepared.seed)
        let result = try await launch(argv, environment(threads: prepared.threads, temporary: temporary), log)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            // macOS ends a process that runs the Mac out of memory with SIGKILL, and `micromamba run` reports its killed
            // child as 137. `ToolProcessMemoryStop` is the one route that words it.
            if result.exitCode == SIGKILL || result.exitCode == ToolProcessMemoryStop.killedExitCode,
               let stop = ToolProcessMemoryStop(tool: "The cell-map route", exitCode: ToolProcessMemoryStop.killedExitCode) {
                throw RNASeqCellMapComputeRefusal.memoryStop(message: stop.message(
                    nextStep: "Close other apps and run it again, or compute the embedding elsewhere and bring it in with Import Embedding."))
            }
            let last = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw RNASeqCellMapComputeRefusal.scriptFailed(exitCode: result.exitCode, line: last)
        }
        guard let record = try? Data(contentsOf: out.appendingPathComponent("record.json")) else {
            throw RNASeqCellMapComputeRefusal.recordUnreadable
        }
        try checkRecord(record)
        let packages = (try? Data(contentsOf: out.appendingPathComponent("packages.tsv"))) ?? Data()
        let table = try lgeTable(fromRouteCells: try Data(contentsOf: out.appendingPathComponent("cells.tsv")))
        let tableURL = temporary.appendingPathComponent("embedding.tsv")
        try table.write(to: tableURL)

        step("Checking the route's table and writing the cell map.")
        var checked = try RNASeqCellMapImport.check(
            .init(parent: options.parent, coordinates: [tableURL], labelColumns: [labelSetName], methods: ["\(embeddingName)=\(embeddingMethod)"],
                  tool: tool, toolVersion: toolVersion),
            output: output, createdAt: startedAt)
        checked.request = computedRequest(checked.request, table: tableURL, seed: prepared.seed, threads: prepared.threads)
        let run = Run(prepared: prepared, record: record, packages: packages, tableSHA256: RNASeqResultBundle.sha256Hex(table),
                      checked: checked, exitCode: result.exitCode)
        try Task.checkCancellation()
        let summary = try writer.writeCellMap(checked.request, to: output) { summary in
            guard summary.outputs.contains(where: { $0.path == keptTable && $0.sha256 == run.tableSHA256 }) else {
                throw RNASeqCellMapImportRefusal.changedWhileRead(file: tableURL.lastPathComponent)
            }
            return try makeEnvelope(run, summary)
        }
        return (run, summary)
    }

    /// The checker's request as a compute run's: origin `computed` by scanpy 1.11.5 with the run's `seed` and `threads` as
    /// its settings, no given file, the table kept as `source/compute/embedding.tsv`, and the embedding and label set marked
    /// `computed` (`docs/formats/rnaseq-cell-map.md`).
    static func computedRequest(_ request: RNASeqResultWriter.CellMapRequest, table: URL, seed: Int, threads: Int)
        -> RNASeqResultWriter.CellMapRequest {
        var request = request
        request.origin = .init(kind: .computed, tool: tool, toolVersion: toolVersion,
                               settings: ["seed": String(seed), "threads": String(threads)])
        request.givenFiles = []
        request.computedTable = table
        request.embeddings = request.embeddings.map { embedding in
            var embedding = embedding
            (embedding.source, embedding.sourceFile) = (.computed, keptTable)
            return embedding
        }
        request.labelSets = request.labelSets.map { set in
            var set = set
            (set.source, set.sourceFile) = (.computed, keptTable)
            return set
        }
        return request
    }
}
