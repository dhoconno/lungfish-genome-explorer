// AnalysisTemplateRenderer.swift - Turns a template plus run inputs into CLI steps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

// MARK: - Request and result types

/// Per-run values a template does not pin.
public struct AnalysisTemplateRenderRequest: Sendable, Equatable {
    /// One file (single-end or interleaved) or R1 then R2 (paired).
    public var inputs: [URL]
    /// The `.lungfish` project the outputs go into.
    public var projectURL: URL
    /// Sample/bundle name; nil derives it from the first input's file name.
    public var sampleName: String?
    /// Threads for both steps; nil leaves each CLI default in place.
    public var threads: Int?
    /// The Kraken2 output directory. Nil renders a placeholder under
    /// `Analyses/`, which dry runs and shell export use.
    public var analysisDirectoryURL: URL?
    /// Overrides the Kraken2 input, used once the import bundle is known.
    public var classificationInputs: [URL]?

    public init(
        inputs: [URL],
        projectURL: URL,
        sampleName: String? = nil,
        threads: Int? = nil,
        analysisDirectoryURL: URL? = nil,
        classificationInputs: [URL]? = nil
    ) {
        self.inputs = inputs
        self.projectURL = projectURL
        self.sampleName = sampleName
        self.threads = threads
        self.analysisDirectoryURL = analysisDirectoryURL
        self.classificationInputs = classificationInputs
    }
}

/// The kind of a rendered step, matching ``AnalysisTemplate/Step``.
public enum RenderedTemplateStepKind: String, Sendable, Codable {
    case importFASTQ
    case kraken2
}

/// One CLI invocation the run will execute, in order.
public struct RenderedTemplateStep: Sendable, Equatable, Codable {
    /// 1-based position in the chain.
    public let index: Int
    public let kind: RenderedTemplateStepKind
    public let title: String
    public let settingsSummary: String
    /// `lungfish-cli` arguments without the executable name.
    public let arguments: [String]
    /// Where the step's main output will be.
    public let expectedOutputURL: URL

    public init(
        index: Int,
        kind: RenderedTemplateStepKind,
        title: String,
        settingsSummary: String,
        arguments: [String],
        expectedOutputURL: URL
    ) {
        self.index = index
        self.kind = kind
        self.title = title
        self.settingsSummary = settingsSummary
        self.arguments = arguments
        self.expectedOutputURL = expectedOutputURL
    }

    /// A copy-pasteable `lungfish-cli …` command line.
    public var commandLine: String {
        ([CLICommandIdentity.executableName] + arguments).map(shellEscape).joined(separator: " ")
    }
}

/// Rendering refusals.
public enum AnalysisTemplateRenderError: Error, LocalizedError, Equatable, Sendable {
    case inputCountMismatch(expected: Int, found: Int)
    case pairedInputsUnavailable
    case missingStep(String)

    public var errorDescription: String? {
        switch self {
        case .inputCountMismatch(let expected, let found):
            return "This template expects \(expected) FASTQ file\(expected == 1 ? "" : "s") per run but \(found) were given."
        case .pairedInputsUnavailable:
            return "The Kraken2 step classifies two separate files, which a single imported bundle does not provide."
        case .missingStep(let name):
            return "The template has no \(name) step."
        }
    }
}

// MARK: - AnalysisTemplateRenderer

/// Pure rendering: template + run values → ordered CLI steps.
public enum AnalysisTemplateRenderer {

    /// Placeholder tokens used by ``placeholderSteps(for:)``.
    public enum Placeholder {
        public static let project = "<project.lungfish>"
        public static let sample = "<sample>"
        public static let read1 = "<reads_R1.fastq.gz>"
        public static let read2 = "<reads_R2.fastq.gz>"
        public static let reads = "<reads.fastq.gz>"
        public static let analysisDirectory = "kraken2-<timestamp>"
    }

    /// The bundle name a run will create: the explicit sample name, or the
    /// name the importer derives from the input file names.
    public static func resolvedSampleName(inputs: [URL], sampleName: String?) -> String {
        if let sampleName = sampleName?.trimmingCharacters(in: .whitespacesAndNewlines), !sampleName.isEmpty {
            return sampleName
        }
        if let detected = FASTQBatchImporter.detectPairs(from: inputs).first?.sampleName, !detected.isEmpty {
            return detected
        }
        return inputs.first?.deletingPathExtension().lastPathComponent ?? "sample"
    }

    /// Where `import fastq --name <sampleName>` publishes the bundle.
    public static func expectedBundleURL(projectURL: URL, sampleName: String) -> URL {
        projectURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("\(sampleName).\(FASTQBundle.directoryExtension)", isDirectory: true)
    }

    /// Renders the ordered steps for a run.
    public static func render(
        _ template: AnalysisTemplate,
        request: AnalysisTemplateRenderRequest
    ) throws -> [RenderedTemplateStep] {
        guard request.inputs.count == template.input.fileCount else {
            throw AnalysisTemplateRenderError.inputCountMismatch(
                expected: template.input.fileCount,
                found: request.inputs.count
            )
        }
        let sampleName = resolvedSampleName(inputs: request.inputs, sampleName: request.sampleName)
        let bundleURL = expectedBundleURL(projectURL: request.projectURL, sampleName: sampleName)
        let analysisURL = request.analysisDirectoryURL
            ?? request.projectURL
                .appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
                .appendingPathComponent(Placeholder.analysisDirectory, isDirectory: true)

        var rendered: [RenderedTemplateStep] = []
        for step in template.steps {
            switch step {
            case .importFASTQ(let spec):
                let invocation = FASTQImportCLIInvocationBuilder.build(
                    spec: spec,
                    inputs: request.inputs,
                    projectURL: request.projectURL,
                    bundleName: sampleName,
                    threads: request.threads
                )
                rendered.append(RenderedTemplateStep(
                    index: rendered.count + 1,
                    kind: .importFASTQ,
                    title: step.title,
                    settingsSummary: step.settingsSummary,
                    arguments: invocation.arguments,
                    expectedOutputURL: bundleURL
                ))
            case .kraken2(let spec):
                let classificationInputs = request.classificationInputs ?? [bundleURL]
                if spec.readFormat == .paired, classificationInputs.count != 2 {
                    throw AnalysisTemplateRenderError.pairedInputsUnavailable
                }
                let config = spec.classificationConfig(
                    inputFiles: classificationInputs,
                    outputDirectory: analysisURL,
                    threads: request.threads ?? 4
                )
                var arguments = ClassificationCLIInvocationBuilder.build(for: config).arguments
                if request.threads == nil {
                    // The template does not pin threads; let the CLI default apply.
                    arguments = removingOption("--threads", from: arguments)
                }
                rendered.append(RenderedTemplateStep(
                    index: rendered.count + 1,
                    kind: .kraken2,
                    title: step.title,
                    settingsSummary: step.settingsSummary,
                    arguments: arguments,
                    expectedOutputURL: analysisURL
                ))
            }
        }
        return rendered
    }

    /// Renders the steps with placeholder inputs, for display and shell export.
    public static func placeholderSteps(for template: AnalysisTemplate) -> [RenderedTemplateStep] {
        let inputs: [URL]
        switch template.input.pairing {
        case .paired:
            inputs = [URL(fileURLWithPath: "/" + Placeholder.read1), URL(fileURLWithPath: "/" + Placeholder.read2)]
        case .single, .interleaved:
            inputs = [URL(fileURLWithPath: "/" + Placeholder.reads)]
        }
        let request = AnalysisTemplateRenderRequest(
            inputs: inputs,
            projectURL: URL(fileURLWithPath: "/" + Placeholder.project),
            sampleName: Placeholder.sample,
            threads: nil
        )
        // Placeholder inputs always satisfy the count check and never ask for
        // two loose classification files, so rendering cannot fail here.
        let steps = (try? render(template, request: request)) ?? []
        return steps.map { step in
            RenderedTemplateStep(
                index: step.index,
                kind: step.kind,
                title: step.title,
                settingsSummary: step.settingsSummary,
                arguments: step.arguments.map(stripPlaceholderRoot),
                expectedOutputURL: URL(fileURLWithPath: stripPlaceholderRoot(step.expectedOutputURL.path))
            )
        }
    }

    /// A shell script that runs the rendered steps in order.
    public static func shellScript(for template: AnalysisTemplate, steps: [RenderedTemplateStep]) -> String {
        var lines = [
            "#!/bin/sh",
            "# Workflow template: \(template.name)",
            "# Created \(ISO8601DateFormatter().string(from: template.createdAt)) by \(template.origin.appVersion)",
            "# Runs the same steps with the same settings. Replace the <placeholders> before running.",
            "set -e",
            "",
        ]
        for step in steps {
            lines.append("# Step \(step.index): \(step.title)")
            lines.append("# \(step.settingsSummary)")
            lines.append(step.commandLine)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func removingOption(_ option: String, from arguments: [String]) -> [String] {
        var result: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if argument == option {
                skipNext = true
                continue
            }
            result.append(argument)
        }
        return result
    }

    private static func stripPlaceholderRoot(_ value: String) -> String {
        value.hasPrefix("/<") ? String(value.dropFirst()) : value
    }
}
