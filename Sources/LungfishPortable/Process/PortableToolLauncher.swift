// PortableToolLauncher.swift - How a portable tool step starts its tools and records each launch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A tool the storage step starts. Each platform's launcher maps it to an executable, the managed environments on the
/// Mac and the image manifest on the node.
package enum PortableStorageTool: String, Sendable, Equatable, CaseIterable {
    case clumpify
    case reformat
    case trimGalore
    case bgzip
    case pigz
}

/// The compressor a storage step writes gzip with. The caller names it, so the step never asks what is installed.
package enum PortableCompressor: String, Sendable, Equatable, CaseIterable {
    case bgzip
    case pigz

    /// The tool the launcher starts for this compressor.
    package var tool: PortableStorageTool {
        switch self {
        case .bgzip: return .bgzip
        case .pigz: return .pigz
        }
    }

    /// The argv that compresses stdin to stdout with `threads` threads. No level is passed, so the tool's default
    /// takes effect.
    package func streamArguments(threads: Int) -> [String] {
        switch self {
        case .bgzip: return ["-@", String(threads), "-c"]
        case .pigz: return ["-p", String(threads), "-c"]
        }
    }

    /// The argv that compresses `input` to stdout with `threads` threads.
    package func arguments(threads: Int, input: URL) -> [String] {
        streamArguments(threads: threads) + [input.path]
    }

    /// The first compressor of the Mac's order, bgzip and then pigz, that `isInstalled` accepts, or nil when it
    /// accepts neither. A user who leaves the compressor to the import gets this order on every Mac import.
    package static func firstInstalled(
        _ isInstalled: (PortableCompressor) async -> Bool
    ) async -> PortableCompressor? {
        for compressor in [PortableCompressor.bgzip, .pigz] {
            if await isInstalled(compressor) { return compressor }
        }
        return nil
    }
}

/// One launch of a tool step, as the step builds it.
package struct PortableToolLaunch: Sendable, Equatable {
    package var tool: PortableStorageTool
    package var arguments: [String]
    /// The folder the tool runs in, nil for the launcher's own.
    package var workingDirectory: URL?
    /// The variables the step sets over the launcher's environment, nil when it sets none.
    package var environment: [String: String]?
    /// The seconds the launcher waits before it stops the tool.
    package var timeout: Double
    /// The file the tool's stdout goes to, published only when the tool succeeds. Nil keeps stdout as text.
    package var standardOutput: URL?
    /// The executable to start in place of the launcher's own for `tool`, such as the `bgzip` the writer probe finds
    /// on a step's `PATH`. Nil starts the launcher's own.
    package var executable: URL?

    package init(
        tool: PortableStorageTool,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: Double,
        standardOutput: URL? = nil,
        executable: URL? = nil
    ) {
        self.tool = tool
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.standardOutput = standardOutput
        self.executable = executable
    }
}

/// How a launch ended, with the clock the launcher read around it.
package struct PortableToolOutcome: Sendable, Equatable {
    package var exitCode: Int32
    /// Whether the launcher counts the run a success.
    package var isSuccess: Bool
    package var stdout: String
    package var stderr: String
    package var startTime: Date
    package var endTime: Date

    package init(exitCode: Int32, isSuccess: Bool, stdout: String, stderr: String, startTime: Date, endTime: Date) {
        self.exitCode = exitCode
        self.isSuccess = isSuccess
        self.stdout = stdout
        self.stderr = stderr
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// A launch the step accepted. The step hands it to the launcher's recorder at once, while its inputs and outputs
/// still exist, because the step deletes each scratch half as soon as it is processed.
package struct PortableToolRun: Sendable {
    package var launch: PortableToolLaunch
    /// The executable the record names.
    package var executableURL: URL
    package var outcome: PortableToolOutcome
    package var inputs: [URL]
    /// The files the launch wrote, or for a Trim Galore call the folder it wrote into.
    package var outputs: [URL]
    /// The trimming report of a Trim Galore call, which the record states with the reads the call removed.
    package var report: TrimGaloreReport?

    package init(
        launch: PortableToolLaunch, executableURL: URL, outcome: PortableToolOutcome, inputs: [URL], outputs: [URL],
        report: TrimGaloreReport? = nil
    ) {
        self.launch = launch
        self.executableURL = executableURL
        self.outcome = outcome
        self.inputs = inputs
        self.outputs = outputs
        self.report = report
    }
}

/// Starts the tools of a portable step and records each launch, so the step names no launcher of one platform. On the
/// Mac the launcher is `NativeToolStorageLauncher` in `Sources/LungfishWorkflow/Ingestion/`, which starts every tool
/// through `NativeToolRunner` and records a `StepExecution`. The Linux executor brings its own.
package protocol PortableToolLauncher: Sendable {
    /// What the launcher keeps for each accepted launch.
    associatedtype Record: Sendable

    /// The executable the launcher starts for `tool`, the path the record names. Throws when the tool is missing.
    func executableURL(for tool: PortableStorageTool) async throws -> URL

    /// Runs one launch to its end. Throws only when the tool could not be started or waited for, so a tool that
    /// exits nonzero returns an outcome.
    func run(_ launch: PortableToolLaunch) async throws -> PortableToolOutcome

    /// The record of a launch the step accepted.
    func record(_ run: PortableToolRun) async -> Record
}
