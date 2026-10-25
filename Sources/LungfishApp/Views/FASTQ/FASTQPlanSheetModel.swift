// FASTQPlanSheetModel.swift - The words, defaults and command of the sheet that writes a plan (CHTC C4 lane U, C4-12)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// What the plan sheet shows and the `import fastq --write-plan` command it runs. The sheet writes the files that
/// pre-process reads on a Linux machine or cluster through the command line's own route, so the folder is the one
/// `ExecutorPlanBatchWriter.write` writes for that command, and the Operations row records the same command.
///
/// The clumping defaults are the plan's own (C4-12): Optimize storage is on with BBTools clumpify for every batch, and
/// neither comes from the Import sheet's size test against this Mac's clumpify memory budget. The sheet offers no
/// Automatic and sends the tool it shows (UX-XC26), so the plan records the tool with source `option`.
nonisolated enum FASTQPlanSheetModel {
    static let title = "Plan for a Linux Machine"
    /// UX's C3 sentence for a build with no executor folder (UX-r2:129-130, UX-XC26 item 2).
    static let noExecutorSentence = "This build of Lungfish has no Linux executor, so it cannot write a plan for a run "
        + "on another machine. Release builds include it."
    /// The line under the popup with BBTools clumpify (UX-XC26 item 3).
    static let bbtoolsLine = "On the run machine, clumpify splits a large sample into more groups to fit the memory "
        + "the plan gives it."
    static let stagingHelp = "The absolute path of the folder on the Linux machine that the jobs read the image, the "
        + "executor and the reads from."
    static let writeButtonTitle = "Write Plan\u{2026}"
    static let chooserMessage = "Name a new folder for the plan. Nothing is imported and nothing is submitted."
    static let clumpingToolChoices: [ClumpingTool] = [.bbtools, .trimGalore]
    static let defaultOptimizeStorage = true
    static let defaultClumpingTool: ClumpingTool = .bbtools
    static let defaultThreads = 8
    static let defaultClumpifyHeapGB = 16
    /// The executor's folder in the app's resources (C4 lane B): `lungfish-executor` with `manifest.json` beside it.
    static let executorFolderPath = "LinuxExecutor/x86_64"
    static let executorManifestName = "manifest.json"

    /// The executor folder of the running app, which a build with `--without-linux-executor` lacks.
    static func bundledExecutorFolder(resourceURL: URL? = Bundle.main.resourceURL) -> URL? {
        resourceURL?.appendingPathComponent(executorFolderPath, isDirectory: true)
    }

    /// The manifest the plan names, or nil when the folder holds no executor or no manifest beside it.
    static func executorManifest(inFolder folder: URL?) -> URL? {
        guard let folder else { return nil }
        let manifest = folder.appendingPathComponent(executorManifestName)
        let executor = folder.appendingPathComponent(ExecutorPlanExecutorManifest.executorFileName)
        let fileManager = FileManager.default
        guard fileManager.isReadableFile(atPath: manifest.path), fileManager.isReadableFile(atPath: executor.path) else {
            return nil
        }
        return manifest
    }

    /// The image record and the tool manifest it pins, from the LungfishWorkflow resources (C4 lane I).
    static func bundledImageFiles() -> (image: URL, toolManifest: URL)? {
        guard let image = RuntimeResourceLocator.path("CHTCImage/image.json", in: .workflow),
              let toolManifest = RuntimeResourceLocator.path("CHTCImage/image-manifest.json", in: .workflow) else {
            return nil
        }
        return (image, toolManifest)
    }

    /// The line under the popup: none with the box clear, the BBTools line, or the Import sheet's Trim Galore words.
    static func lineUnderPopup(optimizeStorage: Bool, tool: ClumpingTool) -> String? {
        guard optimizeStorage else { return nil }
        return tool == .bbtools ? bbtoolsLine : tool.importSheetDisclosure
    }

    /// The tool the plan asks for: the one the popup shows, or none with the box clear. Never `auto`.
    static func requestedClumpingTool(optimizeStorage: Bool, tool: ClumpingTool) -> ClumpingTool {
        optimizeStorage && tool != .auto ? tool : (optimizeStorage ? defaultClumpingTool : .none)
    }

    /// Whether the staging folder is one the command takes: an absolute path.
    static func isStagingFolder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 1 && trimmed.hasPrefix("/")
    }

    /// A whole number of at least 1 from a field, or nil.
    static func positiveWholeNumber(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), value >= 1 else { return nil }
        return value
    }

    /// The argv after `lungfish-cli` of `import fastq --write-plan`, which the row records and the runner runs.
    static func cliArguments(
        inputs: [URL], planFolder: URL, executorManifest: URL, image: URL, imageToolManifest: URL,
        stagingFolder: String, threads: Int, clumpifyHeapGB: Int, optimizeStorage: Bool, tool: ClumpingTool,
        eventsOn: Bool = true
    ) -> [String] {
        var arguments = ["import", "fastq"] + inputs.map(\.standardizedFileURL.path)
        arguments += [
            "--write-plan", planFolder.standardizedFileURL.path,
            "--executor-manifest", executorManifest.standardizedFileURL.path,
            "--image", image.standardizedFileURL.path,
            "--image-tool-manifest", imageToolManifest.standardizedFileURL.path,
            "--staging-folder", stagingFolder.trimmingCharacters(in: .whitespacesAndNewlines),
            "--threads", String(threads), "--clumpify-heap-gb", String(clumpifyHeapGB),
        ]
        let requested = requestedClumpingTool(optimizeStorage: optimizeStorage, tool: tool)
        if requested == .none {
            arguments.append("--no-optimize-storage")
        } else {
            arguments += ["--clumping-tool", requested.rawValue]
        }
        if eventsOn { arguments += ["--format", "json"] }
        return arguments
    }
}
