// MarkdupCommand.swift - CLI command for running samtools markdup on BAM files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO

struct MarkdupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "markdup",
        abstract: "Mark PCR duplicates in BAM files using samtools markdup"
    )

    struct ExecutionInput: Sendable {
        let path: String
        let force: Bool
        let sortThreads: Int
        let quiet: Bool
    }

    struct Runtime {
        typealias Execute = (ExecutionInput, @escaping (String) -> Void) async throws -> [MarkdupResult]

        let execute: Execute

        static func live() -> Runtime {
            Runtime(execute: MarkdupCommand.runLive)
        }
    }

    @Argument(help: "Path to a BAM file or a directory containing BAMs")
    var path: String

    @Flag(name: .long, help: "Re-run markdup even if already marked")
    var force: Bool = false

    @Option(name: .customLong("sort-threads"), help: "Threads for samtools sort (default 4)")
    var sortThreads: Int = 4

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        _ = try await executeForTesting(runtime: .live()) { print($0) }
    }

    func executeForTesting(
        runtime: Runtime = .live(),
        emit: @escaping (String) -> Void
    ) async throws -> [MarkdupResult] {
        try await Self.execute(input: makeExecutionInput(), runtime: runtime, emit: emit)
    }

    static func execute(
        input: ExecutionInput,
        runtime: Runtime = .live(),
        emit: @escaping (String) -> Void
    ) async throws -> [MarkdupResult] {
        try await runtime.execute(input, emit)
    }

    private func makeExecutionInput() -> ExecutionInput {
        ExecutionInput(
            path: path,
            force: force,
            sortThreads: sortThreads,
            quiet: globalOptions.quiet
        )
    }

    private static func runLive(
        input: ExecutionInput,
        emit: @escaping (String) -> Void
    ) async throws -> [MarkdupResult] {
        let inputURL = URL(fileURLWithPath: input.path)
        let fm = FileManager.default

        guard let samtoolsPath = locateSamtools() else {
            throw ValidationError("samtools binary not found")
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inputURL.path, isDirectory: &isDir) else {
            throw ValidationError("Path does not exist: \(inputURL.path)")
        }

        if isDir.boolValue {
            try materializeNaoMgsBamsIfNeeded(
                at: inputURL,
                samtoolsPath: samtoolsPath,
                force: input.force,
                quiet: input.quiet,
                emit: emit
            )

            emitIfNeeded(input.quiet, line: "Scanning \(inputURL.path) for BAM files...", emit: emit)
            let results = try MarkdupService.markdupDirectory(
                inputURL,
                samtoolsPath: samtoolsPath,
                threads: input.sortThreads,
                force: input.force
            )
            if !input.quiet {
                emitSummary(results, emit: emit)
            }
            return results
        }

        guard inputURL.pathExtension == "bam" else {
            throw ValidationError("File is not a .bam: \(inputURL.path)")
        }

        let result = try MarkdupService.markdup(
            bamURL: inputURL,
            samtoolsPath: samtoolsPath,
            threads: input.sortThreads,
            force: input.force
        )
        if !input.quiet {
            emitSummary([result], emit: emit)
        }
        return [result]
    }

    private static func materializeNaoMgsBamsIfNeeded(
        at inputURL: URL,
        samtoolsPath: String,
        force: Bool,
        quiet: Bool,
        emit: @escaping (String) -> Void
    ) throws {
        let naoMgsDbURL = inputURL.appendingPathComponent("hits.sqlite")
        guard FileManager.default.fileExists(atPath: naoMgsDbURL.path) else {
            return
        }

        emitIfNeeded(
            quiet,
            line: "Detected NAO-MGS result directory; materializing BAMs from SQLite...",
            emit: emit
        )

        do {
            let materialized = try NaoMgsBamMaterializer.materializeAll(
                dbPath: naoMgsDbURL.path,
                resultURL: inputURL,
                samtoolsPath: samtoolsPath,
                force: force
            )
            emitIfNeeded(quiet, line: "Materialized \(materialized.count) BAM file(s)", emit: emit)
        } catch {
            emitIfNeeded(
                quiet,
                line: "Warning: NAO-MGS BAM materialization failed: \(error.localizedDescription)",
                emit: emit
            )
        }
    }

    private static func emitSummary(
        _ results: [MarkdupResult],
        emit: @escaping (String) -> Void
    ) {
        let processed = results.count
        let skipped = results.filter { $0.wasAlreadyMarkduped }.count
        let totalReads = results.reduce(0) { $0 + $1.totalReads }
        let totalDups = results.reduce(0) { $0 + $1.duplicateReads }
        let totalTime = results.reduce(0.0) { $0 + $1.durationSeconds }

        emit("Processed \(processed) BAM file\(processed == 1 ? "" : "s") (\(skipped) already marked)")
        emit("Total reads: \(totalReads), duplicates: \(totalDups)")
        emit(String(format: "Elapsed: %.1fs", totalTime))
    }

    private static func emitIfNeeded(
        _ quiet: Bool,
        line: String,
        emit: @escaping (String) -> Void
    ) {
        guard !quiet else {
            return
        }
        emit(line)
    }

    static func locateSamtools(homeDirectory: URL = currentHomeDirectory()) -> String? {
        SamtoolsLocator.locate(homeDirectory: homeDirectory, searchPath: nil)
    }

    private static func currentHomeDirectory() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
