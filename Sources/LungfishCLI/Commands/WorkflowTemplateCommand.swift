// WorkflowTemplateCommand.swift - `lungfish workflow template` create, list, show and run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// `workflow template`: save a finished Kraken2 analysis as a reusable
/// workflow template and run it on new FASTQ files.
struct WorkflowTemplateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "template",
        abstract: "Save a finished Kraken2 analysis as a workflow template and run it on new FASTQ files",
        discussion: """
            A workflow template records the chain from FASTQ import (including the
            import recipe) through Kraken2 (and Bracken) with every setting pinned.
            Running it on new files repeats the same steps with the same settings.
            Templates live in the app-wide library unless --output is given.
            """,
        subcommands: [
            WorkflowTemplateCreateSubcommand.self,
            WorkflowTemplateListSubcommand.self,
            WorkflowTemplateShowSubcommand.self,
            WorkflowTemplateRunSubcommand.self,
        ]
    )
}

// MARK: - Shared options

/// `--library` lets scripts and tests point at another template folder.
struct WorkflowTemplateLibraryOption: ParsableArguments {
    @Option(
        name: .customLong("library"),
        help: "Template library folder (default: the app's Workflow Templates folder in Application Support)"
    )
    var library: String?

    var resolved: AnalysisTemplateLibrary {
        if let library {
            return AnalysisTemplateLibrary(directoryURL: URL(fileURLWithPath: (library as NSString).expandingTildeInPath))
        }
        return AnalysisTemplateLibrary()
    }
}

// MARK: - create

struct WorkflowTemplateCreateSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a workflow template from a Kraken2 analysis folder"
    )

    @Option(name: .customLong("from"), help: "Kraken2 analysis folder (<project>/Analyses/kraken2-…)")
    var from: String

    @Option(name: .customLong("project"), help: "Project folder (default: derived from the analysis path)")
    var project: String?

    @Option(name: .customLong("name"), help: "Template name (default: \"Kraken2 from <sample>\")")
    var name: String?

    @Option(name: .customLong("output"), help: "Write the template to this file instead of the library")
    var output: String?

    @OptionGroup var libraryOption: WorkflowTemplateLibraryOption

    @Option(name: .customLong("format"), help: "Output format: text, json (default: text)")
    var format: TextAndJSONOutputFormat = .text

    func run() async throws {
        let analysisURL = URL(fileURLWithPath: (from as NSString).expandingTildeInPath)
        let projectURL = project.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        let extraction: AnalysisTemplateExtractor.Extraction
        do {
            extraction = try AnalysisTemplateExtractor().extract(analysisURL: analysisURL, projectURL: projectURL, name: name)
        } catch let error as AnalysisTemplateExtractionError {
            throw CLIError.validationFailed(errors: [error.errorDescription ?? "\(error)"])
        }

        let fileURL: URL
        if let output {
            fileURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            do {
                try extraction.template.save(to: fileURL)
            } catch {
                throw CLIError.outputWriteFailed(path: fileURL.path, reason: error.localizedDescription)
            }
        } else {
            do {
                fileURL = try libraryOption.resolved.save(extraction.template)
            } catch {
                throw CLIError.outputWriteFailed(path: libraryOption.resolved.directoryURL.path, reason: error.localizedDescription)
            }
        }

        switch format {
        case .json:
            print(try WorkflowTemplatePresentation.json([
                "file": fileURL.path,
                "sourceBundle": extraction.sourceBundleURL.path,
                "template": try WorkflowTemplatePresentation.jsonObject(extraction.template),
            ]))
        case .text:
            print("Saved workflow template \"\(extraction.template.name)\"")
            print("  File: \(fileURL.path)")
            print(WorkflowTemplatePresentation.describe(extraction.template, indent: "  "))
        }
    }
}

// MARK: - list

struct WorkflowTemplateListSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the workflow templates in the library"
    )

    @OptionGroup var libraryOption: WorkflowTemplateLibraryOption

    @Option(name: .customLong("format"), help: "Output format: text, json (default: text)")
    var format: TextAndJSONOutputFormat = .text

    func run() async throws {
        let library = libraryOption.resolved
        let entries = library.list()
        switch format {
        case .json:
            let items: [[String: Any]] = try entries.map { entry in
                var item: [String: Any] = ["file": entry.url.path, "name": entry.name]
                if let template = entry.template {
                    item["template"] = try WorkflowTemplatePresentation.jsonObject(template)
                }
                if let loadError = entry.loadError {
                    item["error"] = loadError
                }
                return item
            }
            print(try WorkflowTemplatePresentation.json(["library": library.directoryURL.path, "templates": items]))
        case .text:
            if entries.isEmpty {
                print("No workflow templates in \(library.directoryURL.path)")
                print("Create one with: lungfish workflow template create --from <project>/Analyses/kraken2-…")
                return
            }
            print("Workflow templates in \(library.directoryURL.path)")
            for entry in entries {
                if let template = entry.template {
                    let stepTitles = template.steps.map(\.title).joined(separator: " → ")
                    print("  \(template.name)")
                    print("    File: \(entry.url.lastPathComponent)")
                    print("    Input: \(template.input.summary)")
                    print("    Steps: \(stepTitles)")
                    print("    Created: \(ISO8601DateFormatter().string(from: template.createdAt)) by \(template.origin.appVersion)")
                } else {
                    print("  \(entry.name) (cannot be read)")
                    print("    File: \(entry.url.lastPathComponent)")
                    print("    Problem: \(entry.loadError ?? "unknown")")
                }
            }
        }
    }
}

// MARK: - show

struct WorkflowTemplateShowSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show a workflow template's pinned steps as text, JSON or (--shell) a shell script"
    )

    @Argument(help: "Template file, or the name of a template in the library")
    var template: String

    @OptionGroup var libraryOption: WorkflowTemplateLibraryOption

    @Option(name: .customLong("format"), help: "Output format: text, json (default: text)")
    var format: TextAndJSONOutputFormat = .text

    /// A flag rather than a `--format shell` value: the root command's
    /// `--format` (text, json, tsv) is parsed first and would reject `shell`.
    @Flag(name: .customLong("shell"), help: "Print the steps as a shell script with <placeholders> instead of text or JSON")
    var shell: Bool = false

    func run() async throws {
        let (loaded, url) = try WorkflowTemplatePresentation.loadTemplate(reference: template, library: libraryOption.resolved)
        if shell {
            let steps = AnalysisTemplateRenderer.placeholderSteps(for: loaded)
            print(AnalysisTemplateRenderer.shellScript(for: loaded, steps: steps))
            return
        }
        switch format {
        case .json:
            print(String(decoding: try loaded.jsonData(), as: UTF8.self))
        case .text:
            print("Workflow template \"\(loaded.name)\"")
            print("  File: \(url.path)")
            print(WorkflowTemplatePresentation.describe(loaded, indent: "  "))
        }
    }
}

// MARK: - run

struct WorkflowTemplateRunSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a workflow template on new FASTQ files: the same steps with the same settings",
        discussion: """
            Each step runs as its own lungfish-cli command (import fastq, then conda
            classify) and writes its normal provenance. A run-level record beside the
            Kraken2 output links the new bundle and analysis and stores the template
            SHA-256 and any drift warnings.

            The run refuses when the pinned recipe or database differs from the
            record. Pass --allow-drift to run anyway; the differences are then
            recorded as warnings. Results can differ if a tool or database version
            differs from when the template was created.
            """
    )

    @Argument(help: "Template file, or the name of a template in the library")
    var template: String

    @Argument(help: "FASTQ input file(s): one file, or R1 and R2 for a paired template")
    var inputs: [String] = []

    @Option(name: [.customLong("project"), .customShort("p")], help: "Path to the .lungfish project directory")
    var project: String

    @Option(name: .customLong("name"), help: "Sample (bundle) name (default: derived from the input file names)")
    var name: String?

    @Flag(name: .customLong("dry-run"), help: "Check readiness and print the commands without running them")
    var dryRun: Bool = false

    @Flag(name: .customLong("allow-drift"), help: "Run even when the installed recipe or database differs from the template, and record the difference")
    var allowDrift: Bool = false

    @OptionGroup var libraryOption: WorkflowTemplateLibraryOption

    @OptionGroup var globalOptions: GlobalOptions

    /// Test seams, following `RunSubcommand.localWorkflowProcessRunner`: tests
    /// replace the registry lookup and the child-process executor.
    nonisolated(unsafe) static var databaseResolver: AnalysisTemplateRunner.DatabaseResolver = AnalysisTemplateRunner.registryDatabaseResolver
    nonisolated(unsafe) static var stepExecutorFactory: @Sendable (_ outputHandler: ProcessAnalysisTemplateStepExecutor.OutputHandler?) -> any AnalysisTemplateStepExecuting = { outputHandler in
        ProcessAnalysisTemplateStepExecutor(
            executableURL: WorkflowTemplateRunSubcommand.currentExecutableURL(),
            outputHandler: outputHandler
        )
    }

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let (loaded, templateURL) = try WorkflowTemplatePresentation.loadTemplate(reference: template, library: libraryOption.resolved)
        let projectURL = URL(fileURLWithPath: (project as NSString).expandingTildeInPath).standardizedFileURL
        let inputURLs = inputs.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        let isJSON = globalOptions.outputFormat == .json

        let request = AnalysisTemplateRunRequest(
            template: loaded,
            templateURL: templateURL,
            inputs: inputURLs,
            projectURL: projectURL,
            sampleName: name,
            threads: globalOptions.threads,
            allowDrift: allowDrift
        )

        var outputHandler: ProcessAnalysisTemplateStepExecutor.OutputHandler?
        var progress: AnalysisTemplateRunner.ProgressHandler?
        if !isJSON {
            let useColors = globalOptions.useColors
            outputHandler = { line, isError in
                if isError {
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                } else {
                    print("    \(line)")
                }
            }
            progress = { event in
                let formatter = TerminalFormatter(useColors: useColors)
                switch event {
                case .stepStarted(let step):
                    print(formatter.info("Step \(step.index): \(step.title)"))
                    print("  \(step.commandLine)")
                case .stepCompleted(let step):
                    print(formatter.success("Step \(step.index) finished: \(step.expectedOutputURL.path)"))
                }
            }
        }
        let runner = AnalysisTemplateRunner(
            executor: Self.stepExecutorFactory(outputHandler),
            databaseResolver: Self.databaseResolver,
            progress: progress
        )

        if dryRun {
            let (report, steps): (AnalysisTemplatePreflightReport, [RenderedTemplateStep])
            do {
                (report, steps) = try await runner.dryRun(request)
            } catch let error as AnalysisTemplateRenderError {
                throw CLIError.validationFailed(errors: [error.errorDescription ?? "\(error)"])
            }
            if isJSON {
                print(try WorkflowTemplatePresentation.json([
                    "dryRun": true,
                    "template": try WorkflowTemplatePresentation.jsonObject(loaded),
                    "templateFile": templateURL.path,
                    "runnable": report.isRunnable,
                    "blockingIssues": report.blockingIssues,
                    "warnings": report.warnings,
                    "steps": steps.map { ["index": $0.index, "kind": $0.kind.rawValue, "title": $0.title, "arguments": $0.arguments, "expectedOutput": $0.expectedOutputURL.path] },
                ]))
            } else {
                print(formatter.header("Workflow template dry run: \(loaded.name)"))
                print("")
                for step in steps {
                    print("Step \(step.index): \(step.title)")
                    print("  \(step.settingsSummary)")
                    print("  \(step.commandLine)")
                    print("  Output: \(step.expectedOutputURL.path)")
                }
                print("")
                Self.printReadiness(report, formatter: formatter)
            }
            if !report.isRunnable {
                throw CLIExitCode.dependency.exitCode
            }
            return
        }

        if !isJSON {
            print(formatter.header("Workflow template: \(loaded.name)"))
            print("")
            let report = await runner.preflight(request)
            Self.printReadiness(report, formatter: formatter)
            print("")
        }

        let result: AnalysisTemplateRunResult
        do {
            result = try await runner.run(request)
        } catch let error as AnalysisTemplateRunError {
            switch error {
            case .preflightFailed(let issues):
                if isJSON {
                    print(try WorkflowTemplatePresentation.json(["status": "refused", "blockingIssues": issues]))
                } else {
                    print(formatter.error(error.errorDescription ?? "\(error)"))
                }
                throw CLIExitCode.dependency.exitCode
            case .cancelled:
                throw CLIError.cancelled
            case .stepFailed, .outputMissing:
                if isJSON {
                    print(try WorkflowTemplatePresentation.json(["status": "failed", "error": error.errorDescription ?? "\(error)"]))
                } else {
                    print(formatter.error(error.errorDescription ?? "\(error)"))
                }
                throw CLIExitCode.workflowError.exitCode
            }
        }

        if isJSON {
            print(try WorkflowTemplatePresentation.json([
                "status": "completed",
                "runID": result.runID.uuidString,
                "importBundle": result.importBundleURL.path,
                "analysisDirectory": result.analysisDirectoryURL.path,
                "runRecord": result.runRecordURL.path,
                "warnings": result.warnings,
                "steps": result.steps.map { ["index": $0.index, "kind": $0.kind.rawValue, "arguments": $0.arguments] },
            ]))
        } else {
            print("")
            print(formatter.header("Workflow template run complete"))
            print(formatter.keyValueTable([
                ("Bundle", result.importBundleURL.path),
                ("Analysis", result.analysisDirectoryURL.path),
                ("Run record", result.runRecordURL.path),
            ]))
            if !result.warnings.isEmpty {
                print("")
                print(formatter.warning("Warnings recorded with this run:"))
                for warning in result.warnings {
                    print("  - \(warning)")
                }
            }
        }
    }

    static func printReadiness(_ report: AnalysisTemplatePreflightReport, formatter: TerminalFormatter) {
        if report.isRunnable {
            print(formatter.success("Ready: recipe and database match the template."))
        } else {
            print(formatter.error("Not ready:"))
            for issue in report.blockingIssues {
                print("  - \(issue)")
            }
        }
        for warning in report.warnings {
            print(formatter.warning("  - \(warning)"))
        }
    }

    /// The running `lungfish-cli`, so each step launches the same binary.
    static func currentExecutableURL() -> URL {
        if let url = Bundle.main.executableURL {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    }
}

// MARK: - Presentation helpers

enum WorkflowTemplatePresentation {
    static func loadTemplate(reference: String, library: AnalysisTemplateLibrary) throws -> (AnalysisTemplate, URL) {
        guard let url = library.resolve(reference) else {
            throw CLIError.inputFileNotFound(path: reference)
        }
        do {
            return (try AnalysisTemplate.load(from: url), url)
        } catch let error as AnalysisTemplateError {
            throw CLIError.validationFailed(errors: [error.errorDescription ?? "\(error)"])
        }
    }

    static func describe(_ template: AnalysisTemplate, indent: String) -> String {
        var lines: [String] = []
        lines.append("\(indent)Input: \(template.input.summary)")
        lines.append("\(indent)Steps:")
        for (index, step) in template.steps.enumerated() {
            lines.append("\(indent)  \(index + 1). \(step.title)")
            lines.append("\(indent)     \(step.settingsSummary)")
        }
        if let kraken2 = template.kraken2Step {
            lines.append("\(indent)Fixed resource: Kraken2 database \(kraken2.database.summary)")
        }
        lines.append("\(indent)Per run: input files, project, sample name, threads")
        if !template.creationWarnings.isEmpty {
            lines.append("\(indent)Warnings:")
            for warning in template.creationWarnings {
                lines.append("\(indent)  - \(warning)")
            }
        }
        lines.append("\(indent)Created: \(ISO8601DateFormatter().string(from: template.createdAt)) by \(template.origin.appVersion) from \(template.origin.sourceAnalysisRelativePath)")
        return lines.joined(separator: "\n")
    }

    static func jsonObject(_ template: AnalysisTemplate) throws -> Any {
        try JSONSerialization.jsonObject(with: try template.jsonData())
    }

    static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
