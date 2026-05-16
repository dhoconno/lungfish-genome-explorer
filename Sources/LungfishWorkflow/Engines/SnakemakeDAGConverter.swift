// SnakemakeDAGConverter.swift - Graphviz conversion for Snakemake DAG output
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

struct SnakemakeDAGConverter: Sendable {
    typealias GraphvizRunner = @Sendable (
        _ executable: URL,
        _ arguments: [String],
        _ workingDirectory: URL
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String)

    var temporaryDirectoryProvider: @Sendable () -> URL
    var dotExecutableProvider: @Sendable () -> URL?
    var runGraphviz: GraphvizRunner

    init(
        temporaryDirectoryProvider: @escaping @Sendable () -> URL = { FileManager.default.temporaryDirectory },
        dotExecutableProvider: @escaping @Sendable () -> URL?,
        runGraphviz: @escaping GraphvizRunner
    ) {
        self.temporaryDirectoryProvider = temporaryDirectoryProvider
        self.dotExecutableProvider = dotExecutableProvider
        self.runGraphviz = runGraphviz
    }

    func convert(dotData: Data, format: DAGFormat) async throws -> Data {
        guard let dotPath = dotExecutableProvider() else {
            return dotData
        }

        let formatArg: String
        switch format {
        case .svg:
            formatArg = "-Tsvg"
        case .png:
            formatArg = "-Tpng"
        default:
            return dotData
        }

        let tempDir = temporaryDirectoryProvider()
            .appendingPathComponent("lungfish-snakemake-dag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dotFile = tempDir.appendingPathComponent("dag.dot")
        try dotData.write(to: dotFile)

        let outputFile = tempDir.appendingPathComponent("dag.\(format.rawValue)")
        let (exitCode, _, _) = try await runGraphviz(
            dotPath,
            [formatArg, "-o", outputFile.path, dotFile.path],
            tempDir
        )

        guard exitCode == 0 else {
            return dotData
        }

        return try Data(contentsOf: outputFile)
    }
}
