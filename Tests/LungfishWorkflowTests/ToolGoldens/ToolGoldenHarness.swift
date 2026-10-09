// ToolGoldenHarness.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Runs one ToolGoldenCase through the LGE runner that serves the tool today,
// in a per-test scratch folder, and turns the result into the golden files
// that Tests/Fixtures/golden/tools/<case-id>/ holds.

import Foundation
import LungfishCore
@testable import LungfishWorkflow

/// Where the managed tools live for this run. The suite only reads from it.
struct ToolGoldenStorage: Sendable {
    let storageRoot: URL
    let condaRoot: URL

    static func resolve() -> ToolGoldenStorage {
        let store = ManagedStorageConfigStore()
        return ToolGoldenStorage(
            storageRoot: store.currentLocation().rootURL.standardizedFileURL,
            condaRoot: store.currentCondaRootURL().standardizedFileURL
        )
    }

    var micromamba: URL { condaRoot.appendingPathComponent("bin/micromamba") }

    func executable(environment: String, name: String) -> URL {
        condaRoot.appendingPathComponent("envs/\(environment)/bin/\(name)")
    }
}

/// What one runner call produced, before normalization.
struct ToolGoldenRawResult: Sendable {
    var argv: [[String]]
    var exitCodes: [Int32]
    var stdout: Data
    var stderr: Data
}

enum ToolGoldenHarnessError: Error, CustomStringConvertible {
    case unavailable(String)
    case setupFailed(String)

    var description: String {
        switch self {
        case .unavailable(let reason): return reason
        case .setupFailed(let reason): return reason
        }
    }
}

struct ToolGoldenHarness {
    /// Text larger than this is stored as a SHA-256 plus a summary.
    static let inlineLimit = 32 * 1024

    /// Staged inputs get this modification time, so formats that record an
    /// input's mtime (the gzip header pigz writes) do not change between runs.
    static let fixedInputDate = Date(timeIntervalSince1970: 1_577_836_800)  // 2020-01-01T00:00:00Z

    static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ToolGoldens/
            .deletingLastPathComponent()  // LungfishWorkflowTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    let goldenCase: ToolGoldenCase
    let storage: ToolGoldenStorage
    let scratch: URL

    var inputDirectory: URL { scratch.appendingPathComponent("in", isDirectory: true) }
    var workDirectory: URL { scratch.appendingPathComponent("work", isDirectory: true) }

    // MARK: Availability

    /// Throws `unavailable` when a tool or database the case needs is missing.
    static func checkAvailability(_ goldenCase: ToolGoldenCase, storage: ToolGoldenStorage) async throws {
        var missing: [String] = []
        let runners = [goldenCase.runner] + goldenCase.setup.map(\.runner)
        for runner in runners {
            switch runner {
            case .nativeTool(let tool), .nativeFileOutput(let tool, _):
                if !(await NativeToolRunner.shared.isToolAvailable(tool)) { missing.append(tool.rawValue) }
            case .pipeline(let tools):
                for tool in tools where !(await NativeToolRunner.shared.isToolAvailable(tool)) {
                    missing.append(tool.rawValue)
                }
            case .nativeProcess(let environment, let executable):
                let url = storage.executable(environment: environment, name: executable)
                if !FileManager.default.isExecutableFile(atPath: url.path) { missing.append("\(environment)/\(executable)") }
            case .conda(let environment, let executable):
                if !FileManager.default.isExecutableFile(atPath: storage.micromamba.path) { missing.append("micromamba") }
                let url = storage.executable(environment: environment, name: executable)
                if !FileManager.default.isExecutableFile(atPath: url.path) { missing.append("\(environment)/\(executable)") }
            case .processManager(let engine):
                do {
                    _ = try WorkflowEngineLaunch.resolveManaged(
                        executableName: engine,
                        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                    )
                } catch {
                    missing.append(engine)
                }
            }
        }
        for database in goldenCase.databases {
            let url = storage.storageRoot.appendingPathComponent(database)
            if !FileManager.default.fileExists(atPath: url.path) { missing.append("database \(database)") }
        }
        if !missing.isEmpty {
            throw ToolGoldenHarnessError.unavailable(
                "\(goldenCase.id): not installed under \(storage.storageRoot.path): " + missing.joined(separator: ", ")
            )
        }
    }

    // MARK: Staging

    static func makeScratch(for goldenCase: ToolGoldenCase) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-tool-golden-\(goldenCase.id)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Hand tools the canonical spelling (/private/var/...), the one getcwd
        // reports, so argv and cwd agree. Foundation's resolvingSymlinksInPath
        // drops the /private prefix, so ask realpath(3) instead.
        guard let resolved = realpath(base.path, nil) else { return base }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    func stage() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        for relative in goldenCase.inputs {
            let source = Self.fixturesRoot.appendingPathComponent(relative)
            let destination = inputDirectory.appendingPathComponent(source.lastPathComponent)
            try fm.copyItem(at: source, to: destination)
        }
        for input in goldenCase.generated {
            try input.contents(inputDirectory).write(to: inputDirectory.appendingPathComponent(input.name))
        }
        for name in try fm.contentsOfDirectory(atPath: inputDirectory.path) {
            try fm.setAttributes(
                [.modificationDate: Self.fixedInputDate],
                ofItemAtPath: inputDirectory.appendingPathComponent(name).path
            )
        }
    }

    func resolve(_ value: String) -> String {
        value
            .replacingOccurrences(of: "{in}", with: inputDirectory.path)
            .replacingOccurrences(of: "{work}", with: workDirectory.path)
            .replacingOccurrences(of: "{storage}", with: storage.storageRoot.path)
    }

    // MARK: Execution

    func execute(_ runner: ToolGoldenRunner, stages: [[String]]) async throws -> ToolGoldenRawResult {
        let argvs = stages.map { $0.map(resolve) }
        let environment = goldenCase.environment.isEmpty
            ? nil
            : goldenCase.environment.mapValues(resolve)
        let timeout = goldenCase.timeout
        let native = NativeToolRunner.shared

        switch runner {
        case .nativeTool(let tool):
            let result = try await native.run(
                tool, arguments: argvs[0], workingDirectory: workDirectory,
                environment: environment, timeout: timeout
            )
            return ToolGoldenRawResult(
                argv: [result.arguments], exitCodes: [result.exitCode],
                stdout: Data(result.stdout.utf8), stderr: Data(result.stderr.utf8)
            )

        case .nativeProcess(let environmentName, let executable):
            let url = storage.executable(environment: environmentName, name: executable)
            let result = try await native.runProcess(
                executableURL: url, arguments: argvs[0], workingDirectory: workDirectory,
                environment: environment, timeout: timeout, toolName: executable
            )
            return ToolGoldenRawResult(
                argv: [result.arguments], exitCodes: [result.exitCode],
                stdout: Data(result.stdout.utf8), stderr: Data(result.stderr.utf8)
            )

        case .nativeFileOutput(let tool, let outputFile):
            let output = URL(fileURLWithPath: resolve(outputFile))
            let result = try await native.runWithFileOutput(
                tool, arguments: argvs[0], outputFile: output, workingDirectory: workDirectory,
                environment: environment, timeout: timeout
            )
            return ToolGoldenRawResult(
                argv: [result.arguments + [">", output.path]], exitCodes: [result.exitCode],
                stdout: Data(result.stdout.utf8), stderr: Data(result.stderr.utf8)
            )

        case .pipeline(let tools):
            precondition(tools.count == argvs.count, "\(goldenCase.id): one argv per pipeline stage")
            var declared: [[String]] = []
            for (tool, arguments) in zip(tools, argvs) {
                declared.append([try await native.findTool(tool).path] + arguments)
            }
            let result = try await native.runPipeline(
                zip(tools, argvs).map { NativePipelineStage($0, arguments: $1) },
                workingDirectory: workDirectory, environment: environment, timeout: timeout
            )
            let stderr = result.stderrByStage.enumerated()
                .map { "--- stage \($0.offset + 1) ---\n\($0.element)" }
                .joined(separator: "\n")
            return ToolGoldenRawResult(
                argv: declared, exitCodes: result.exitCodes,
                stdout: Data(result.stdout.utf8), stderr: Data(stderr.utf8)
            )

        case .conda(let environmentName, let executable):
            // Same runTool code as CondaManager.shared, on an instance that
            // never replaces the installed micromamba with the test bundle's
            // copy and never writes the shared package cache's .mambarc, so
            // the storage root is only read.
            let manager = CondaManager(
                rootPrefix: storage.condaRoot,
                bundledMicromambaProvider: { nil },
                bundledMicromambaVersionProvider: { nil }
            )
            let result = try await manager.runTool(
                name: executable, arguments: argvs[0], environment: environmentName,
                workingDirectory: workDirectory, environmentVariables: environment, timeout: timeout
            )
            let declared = [storage.micromamba.path, "run", "-n", environmentName, executable] + argvs[0]
            return ToolGoldenRawResult(
                argv: [declared], exitCodes: [result.exitCode],
                stdout: Data(result.stdout.utf8), stderr: Data(result.stderr.utf8)
            )

        case .processManager(let engine):
            let launch = try WorkflowEngineLaunch.resolveManaged(
                executableName: engine,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ).overridingEnvironment(set: environment ?? [:])
            let arguments = launch.arguments(argvs[0])
            let result = try await ProcessManager.shared.runAndWait(
                executable: launch.executableURL, arguments: arguments,
                workingDirectory: workDirectory, environment: launch.environment
            )
            return ToolGoldenRawResult(
                argv: [[launch.executableURL.path] + arguments], exitCodes: [result.exitCode],
                stdout: Data(result.stdout.utf8), stderr: Data(result.stderr.utf8)
            )
        }
    }

    // MARK: Normalization

    /// Replaces the scratch folder and the storage root with fixed tokens,
    /// then applies the case's listed masks. Nothing else changes.
    func normalize(_ text: String) -> String {
        var result = text
        for spelling in Self.spellings(of: scratch) {
            result = result.replacingOccurrences(of: spelling, with: "<SCRATCH>")
        }
        for spelling in Self.spellings(of: storage.storageRoot) {
            result = result.replacingOccurrences(of: spelling, with: "<STORAGE_ROOT>")
        }
        for mask in goldenCase.masks {
            result = mask.apply(to: result)
        }
        return result
    }

    /// The spellings one folder can appear under: as given, and with or
    /// without the /private prefix macOS hides behind /var and /tmp.
    private static func spellings(of url: URL) -> [String] {
        var values = [url.path]
        if let resolved = realpath(url.path, nil) {
            values.append(String(cString: resolved))
            free(resolved)
        }
        for value in values {
            if value.hasPrefix("/private/") {
                values.append(String(value.dropFirst("/private".count)))
            } else if value.hasPrefix("/var/") || value.hasPrefix("/tmp/") {
                values.append("/private" + value)
            }
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }.sorted { $0.count > $1.count }
    }

    private func normalizedData(_ data: Data) -> (data: Data, isText: Bool) {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return (data, false)
        }
        return (Data(normalize(text).utf8), true)
    }

    // MARK: Golden files

    /// Runs the setup steps and the case, and returns the golden files keyed
    /// by their path inside the case's golden folder.
    func produceGoldenFiles() async throws -> [String: Data] {
        try stage()
        for (index, step) in goldenCase.setup.enumerated() {
            let result = try await execute(step.runner, stages: [step.argv])
            guard result.exitCodes.allSatisfy({ $0 == 0 }) else {
                throw ToolGoldenHarnessError.setupFailed(
                    "\(goldenCase.id): setup step \(index + 1) exited \(result.exitCodes): "
                        + String(decoding: result.stderr, as: UTF8.self)
                )
            }
        }

        let raw = try await execute(goldenCase.runner, stages: goldenCase.stages)
        var files: [String: Data] = [:]
        files["case.txt"] = Data(goldenCase.descriptor.utf8)
        let argvText = raw.argv
            .map { $0.joined(separator: "\n") }
            .joined(separator: "\n|\n") + "\n"
        files["argv.txt"] = Data(normalize(argvText).utf8)
        files["exit.txt"] = Data((raw.exitCodes.map(String.init).joined(separator: " ") + "\n").utf8)
        store(raw.stdout, as: "stdout", into: &files)
        if goldenCase.compareStderr {
            store(raw.stderr, as: "stderr", into: &files, inlineAlways: true)
        }

        for output in goldenCase.outputs {
            switch output {
            case .file(let path, let name):
                let url = URL(fileURLWithPath: resolve(path))
                guard let data = FileManager.default.contents(atPath: url.path) else {
                    files["outputs/\(name).missing"] = Data("missing\n".utf8)
                    continue
                }
                store(data, as: "outputs/\(name)", into: &files)
            case .bam(let path, let name):
                let bamPath = resolve(path)
                let records = try await NativeToolRunner.shared.run(.samtools, arguments: ["view", "--no-PG", bamPath])
                let header = try await NativeToolRunner.shared.run(.samtools, arguments: ["view", "-H", "--no-PG", bamPath])
                let recordText = normalize(records.stdout)
                let recordCount = recordText.split(separator: "\n", omittingEmptySubsequences: true).count
                files["outputs/\(name).records.sha256"] = Data(
                    "\(Self.sha256(Data(recordText.utf8)))  records=\(recordCount) exit=\(records.exitCode)\n".utf8
                )
                files["outputs/\(name).header"] = Data(normalize(header.stdout).utf8)
            case .absent(let path, let name):
                let exists = FileManager.default.fileExists(atPath: resolve(path))
                files["outputs/\(name).absent"] = Data((exists ? "present\n" : "absent\n").utf8)
            }
        }
        return files
    }

    private func store(_ data: Data, as name: String, into files: inout [String: Data], inlineAlways: Bool = false) {
        let (normalized, isText) = normalizedData(data)
        if inlineAlways || normalized.count <= Self.inlineLimit {
            files[name] = normalized
            return
        }
        files["\(name).sha256"] = Data("\(Self.sha256(normalized))\n".utf8)
        var summary = "bytes: \(normalized.count)\n"
        if isText {
            let text = String(decoding: normalized, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let lineCount = text.hasSuffix("\n") ? lines.count - 1 : lines.count
            summary += "lines: \(lineCount)\n"
            summary += "first: \(lines.first.map(String.init) ?? "")\n"
            let last = text.hasSuffix("\n") ? lines.dropLast().last : lines.last
            summary += "last: \(last.map(String.init) ?? "")\n"
        } else {
            summary += "binary\n"
        }
        files["\(name).summary"] = Data(summary.utf8)
    }

    static func sha256(_ data: Data) -> String {
        ToolGoldenStore.sha256Hex(data)
    }
}
