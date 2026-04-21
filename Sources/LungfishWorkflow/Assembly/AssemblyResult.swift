// AssemblyResult.swift - Generic managed assembly result wrapper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public enum AssemblyOutcome: String, Sendable, Codable, Equatable {
    case completed
    case completedWithNoContigs
}

public struct AssemblyResult: Sendable, Codable, Equatable {
    public let tool: AssemblyTool
    public let readType: AssemblyReadType
    public let outcome: AssemblyOutcome
    public let contigsPath: URL
    public let graphPath: URL?
    public let logPath: URL?
    public let assemblerVersion: String?
    public let commandLine: String
    public let outputDirectory: URL
    public let statistics: AssemblyStatistics
    public let wallTimeSeconds: TimeInterval
    public let scaffoldsPath: URL?
    public let paramsPath: URL?

    public init(
        tool: AssemblyTool,
        readType: AssemblyReadType,
        outcome: AssemblyOutcome = .completed,
        contigsPath: URL,
        graphPath: URL?,
        logPath: URL?,
        assemblerVersion: String?,
        commandLine: String,
        outputDirectory: URL,
        statistics: AssemblyStatistics,
        wallTimeSeconds: TimeInterval,
        scaffoldsPath: URL? = nil,
        paramsPath: URL? = nil
    ) {
        self.tool = tool
        self.readType = readType
        self.outcome = outcome
        self.contigsPath = contigsPath
        self.graphPath = graphPath
        self.logPath = logPath
        self.assemblerVersion = assemblerVersion
        self.commandLine = commandLine
        self.outputDirectory = outputDirectory
        self.statistics = statistics
        self.wallTimeSeconds = wallTimeSeconds
        self.scaffoldsPath = scaffoldsPath
        self.paramsPath = paramsPath
    }
}

private let assemblyResultSidecarFilename = "assembly-result.json"

private struct PersistedManagedAssemblyResult: Codable {
    let schemaVersion: Int
    let tool: AssemblyTool
    let readType: AssemblyReadType
    let outcome: AssemblyOutcome?
    let contigsPath: String
    let graphPath: String?
    let logPath: String?
    let scaffoldsPath: String?
    let paramsPath: String?
    let assemblerVersion: String?
    let commandLine: String
    let outputDirectory: String
    let statistics: AssemblyStatistics
    let wallTimeSeconds: TimeInterval
}

public extension AssemblyResult {
    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            PersistedManagedAssemblyResult(
                schemaVersion: 3,
                tool: tool,
                readType: readType,
                outcome: outcome,
                contigsPath: contigsPath.lastPathComponent,
                graphPath: graphPath?.lastPathComponent,
                logPath: logPath?.lastPathComponent,
                scaffoldsPath: scaffoldsPath?.lastPathComponent,
                paramsPath: paramsPath?.lastPathComponent,
                assemblerVersion: assemblerVersion,
                commandLine: commandLine,
                outputDirectory: outputDirectory.path,
                statistics: statistics,
                wallTimeSeconds: wallTimeSeconds
            )
        )
        try data.write(
            to: directory.appendingPathComponent(assemblyResultSidecarFilename),
            options: .atomic
        )
    }

    static func load(from directory: URL) throws -> AssemblyResult {
        let fileURL = directory.appendingPathComponent(assemblyResultSidecarFilename)
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let persisted = try? decoder.decode(PersistedManagedAssemblyResult.self, from: data) {
            return AssemblyResult(
                tool: persisted.tool,
                readType: persisted.readType,
                outcome: persisted.outcome ?? .completed,
                contigsPath: directory.appendingPathComponent(persisted.contigsPath),
                graphPath: persisted.graphPath.map { directory.appendingPathComponent($0) },
                logPath: persisted.logPath.map { directory.appendingPathComponent($0) },
                assemblerVersion: persisted.assemblerVersion,
                commandLine: persisted.commandLine,
                outputDirectory: URL(fileURLWithPath: persisted.outputDirectory),
                statistics: persisted.statistics,
                wallTimeSeconds: persisted.wallTimeSeconds,
                scaffoldsPath: persisted.scaffoldsPath.map { directory.appendingPathComponent($0) },
                paramsPath: persisted.paramsPath.map { directory.appendingPathComponent($0) }
            )
        }

        return AssemblyResult.fromLegacy(try SPAdesAssemblyResult.load(from: directory))
    }

    static func fromLegacy(_ result: SPAdesAssemblyResult) -> AssemblyResult {
        AssemblyResult(
            tool: .spades,
            readType: .illuminaShortReads,
            outcome: .completed,
            contigsPath: result.contigsPath,
            graphPath: result.graphPath,
            logPath: result.logPath,
            assemblerVersion: result.spadesVersion,
            commandLine: result.commandLine,
            outputDirectory: result.contigsPath.deletingLastPathComponent(),
            statistics: result.statistics,
            wallTimeSeconds: result.wallTimeSeconds,
            scaffoldsPath: result.scaffoldsPath,
            paramsPath: result.paramsPath
        )
    }
}
