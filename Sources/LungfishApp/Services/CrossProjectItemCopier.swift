// CrossProjectItemCopier.swift - One copy path for Lungfish items dropped into a project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Every Lungfish bundle and every analysis result folder can be copied between
// projects: sidebar to sidebar across two project windows, or Finder into a
// project. Before this service existed, a dropped result folder such as
// `kraken2-<timestamp>` had no extension, so the import planner exploded it
// into loose files and copied those into the project root, where nothing
// recognised them. This service keeps the item whole, lands it in the folder
// the target project expects, rewrites the source-project links it can
// resolve, and records the rest so the Inspector can say what is missing.

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let copierLogger = Logger(subsystem: "com.lungfish.app", category: "CrossProjectItemCopier")

enum CrossProjectItemCopier {

    // MARK: - Kinds

    /// What kind of project item is being copied. Decided from the item alone.
    enum ItemKind: Equatable, Sendable {
        case fastqBundle
        case referenceBundle
        case multipleSequenceAlignmentBundle
        case phylogeneticTreeBundle
        case primerSchemeBundle
        case primerAnalysisBundle
        case genotypeResultBundle
        case twelveSResultBundle
        case czIdResult
        case workflowBundle
        case otherNativeBundle
        case analysisResult(tool: String, isBatch: Bool)

        /// Items that carry `analysis-metadata.json` are hidden by the sidebar
        /// anywhere except under `Analyses/`, so they must land there.
        var mustLiveUnderAnalyses: Bool {
            switch self {
            case .analysisResult, .genotypeResultBundle: return true
            default: return false
            }
        }

        /// Where a Finder drop of this kind lands when the source gives no hint.
        var defaultRelativeFolder: String {
            switch self {
            case .fastqBundle: return "Imports"
            case .referenceBundle: return ReferenceSequenceFolder.folderName
            case .multipleSequenceAlignmentBundle: return "\(AnalysesFolder.directoryName)/Multiple Sequence Alignments"
            case .phylogeneticTreeBundle: return "Phylogenetic Trees"
            case .primerSchemeBundle: return PrimerSchemesFolder.folderName
            case .czIdResult: return "Classifications"
            case .workflowBundle: return WorkflowLibraryStore.workflowsDirectoryName
            case .analysisResult, .genotypeResultBundle, .primerAnalysisBundle, .twelveSResultBundle:
                return AnalysesFolder.directoryName
            case .otherNativeBundle: return ""
            }
        }

        var displayName: String {
            switch self {
            case .fastqBundle: return "read bundle"
            case .referenceBundle: return "reference bundle"
            case .multipleSequenceAlignmentBundle: return "multiple sequence alignment"
            case .phylogeneticTreeBundle: return "tree bundle"
            case .primerSchemeBundle: return "primer scheme"
            case .primerAnalysisBundle: return "primer analysis"
            case .genotypeResultBundle: return "genotype result"
            case .twelveSResultBundle: return "12S result"
            case .czIdResult: return "CZ ID result"
            case .workflowBundle: return "workflow"
            case .otherNativeBundle: return "bundle"
            case .analysisResult(let tool, _): return "\(AnalysesFolder.displayName(for: tool)) result"
            }
        }
    }

    /// Decides whether `url` is a Lungfish item this copier handles.
    ///
    /// Projects, workflow packages and MHC reference databases keep their own
    /// dedicated import paths and return nil here.
    static func kind(of url: URL, fileManager: FileManager = .default) -> ItemKind? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        switch url.pathExtension.lowercased() {
        case "lungfish", "lungfishflowpkg":
            return nil
        case MHCAmpliconReferenceBundle.directoryExtension:
            return nil
        case WorkflowLibraryStore.workflowBundleExtension:
            return .workflowBundle
        default:
            break
        }
        if let classification = SidebarProjectScanner.bundleClassification(for: url, fileManager: fileManager) {
            switch classification.type {
            case .fastqBundle: return .fastqBundle
            case .referenceBundle: return .referenceBundle
            case .multipleSequenceAlignmentBundle: return .multipleSequenceAlignmentBundle
            case .phylogeneticTreeBundle: return .phylogeneticTreeBundle
            case .primerSchemeBundle: return .primerSchemeBundle
            case .primerAnalysisBundle: return .primerAnalysisBundle
            case .genotypeResultBundle: return .genotypeResultBundle
            case .twelveSAmpliconResultBundle: return .twelveSResultBundle
            case .czIdResult: return .czIdResult
            default: return .otherNativeBundle
            }
        }
        if let info = AnalysesFolder.analysisInfo(for: url) {
            return .analysisResult(tool: info.tool, isBatch: info.isBatch)
        }
        return nil
    }

    static func isCopyableProjectItem(_ url: URL) -> Bool {
        kind(of: url) != nil
    }

    // MARK: - Outcome

    struct Outcome: Sendable {
        let sourceURL: URL
        let destinationURL: URL
        let kind: ItemKind
        let record: ProjectItemCopyRecord
    }

    enum CopyError: Error, LocalizedError {
        case notAProjectItem(URL)
        case destinationInsideSource(URL)

        var errorDescription: String? {
            switch self {
            case .notAProjectItem(let url):
                return "\(url.lastPathComponent) is not a Lungfish bundle or analysis result."
            case .destinationInsideSource(let url):
                return "\(url.lastPathComponent) cannot be copied into itself."
            }
        }
    }

    // MARK: - Destination

    /// Where the copy lands inside `targetProjectURL`.
    ///
    /// - A folder the user dropped onto wins, unless the item must live under
    ///   `Analyses/` and that folder is elsewhere.
    /// - Otherwise an item that came from another project keeps its
    ///   project-relative parent folder, so `Analyses/Reviewed/` stays grouped
    ///   and `Reference Sequences/` stays where references go.
    /// - A Finder drop from outside any project uses the kind's convention.
    static func destinationFolder(
        for kind: ItemKind,
        sourceURL: URL,
        sourceProjectURL: URL?,
        targetProjectURL: URL,
        requestedFolder: URL?
    ) -> URL {
        let target = targetProjectURL.standardizedFileURL
        let analysesURL = target.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)

        if let requestedFolder {
            let requested = requestedFolder.standardizedFileURL
            let underAnalyses = ProjectItemLinkRewriter.relative(
                path: requested.path,
                toAny: ProjectItemLinkRewriter.pathVariants(of: analysesURL)
            ) != nil
            if !kind.mustLiveUnderAnalyses || underAnalyses {
                return requested
            }
            copierLogger.info("Retargeting \(sourceURL.lastPathComponent, privacy: .public) to Analyses/ because analysis results are only shown there")
            return analysesURL
        }

        if let sourceProjectURL,
           let relativeParent = ProjectItemLinkRewriter.relative(
               path: sourceURL.standardizedFileURL.deletingLastPathComponent().path,
               toAny: ProjectItemLinkRewriter.pathVariants(of: sourceProjectURL)
           ) {
            let components = relativeParent.split(separator: "/").map(String.init)
            let crossesBundle = components.contains { URL(fileURLWithPath: $0).pathExtension.lowercased().hasPrefix("lungfish") }
            let mirrored = components.reduce(target) { $0.appendingPathComponent($1, isDirectory: true) }
            let mirroredUnderAnalyses = components.first == AnalysesFolder.directoryName
            if !crossesBundle, !kind.mustLiveUnderAnalyses || mirroredUnderAnalyses {
                return mirrored
            }
        }

        let relative = kind.defaultRelativeFolder
        return relative.isEmpty ? target : target.appendingPathComponent(relative, isDirectory: true)
    }

    /// `name.ext`, then `name-2.ext`, `name-3.ext`, ... until free.
    static func uniqueDestinationURL(for sourceURL: URL, in folder: URL, fileManager: FileManager = .default) -> URL {
        let ext = sourceURL.pathExtension
        let base = ext.isEmpty ? sourceURL.lastPathComponent : sourceURL.deletingPathExtension().lastPathComponent
        var counter = 1
        while true {
            let name = counter == 1 ? base : "\(base)-\(counter)"
            let candidate = folder.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)", isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    // MARK: - Copy

    /// Copies one item into the target project and returns where it landed
    /// together with its missing-source record.
    static func copy(
        itemAt sourceURL: URL,
        intoProject targetProjectURL: URL,
        requestedFolder: URL? = nil,
        now: Date = Date()
    ) throws -> Outcome {
        let fileManager = FileManager.default
        let source = sourceURL.standardizedFileURL
        guard let kind = kind(of: source, fileManager: fileManager) else {
            throw CopyError.notAProjectItem(source)
        }
        let sourceProjectURL = ProjectTempDirectory.findProjectRoot(source.deletingLastPathComponent())
        let folder = destinationFolder(
            for: kind,
            sourceURL: source,
            sourceProjectURL: sourceProjectURL,
            targetProjectURL: targetProjectURL,
            requestedFolder: requestedFolder
        )
        let destination = uniqueDestinationURL(for: source, in: folder, fileManager: fileManager)
        let sourcePath = source.resolvingSymlinksInPath().path
        if destination.resolvingSymlinksInPath().path.hasPrefix(sourcePath + "/") {
            throw CopyError.destinationInsideSource(source)
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        try copyBytes(kind: kind, from: source, to: destination, sourceProjectURL: sourceProjectURL)

        let links = try ProjectItemLinkRewriter.rewrite(context: .init(
            sourceItemURL: source,
            destinationItemURL: destination,
            sourceProjectURL: sourceProjectURL,
            targetProjectURL: targetProjectURL
        ))
        let record = ProjectItemCopyRecord(
            copiedAt: now,
            sourceItemPath: source.path,
            sourceProjectPath: sourceProjectURL?.standardizedFileURL.path,
            targetProjectPath: targetProjectURL.standardizedFileURL.path,
            links: links
        )
        try record.save(to: destination)

        if case .analysisResult(let tool, _) = kind {
            registerInSourceBundleHistory(
                tool: tool,
                analysisURL: destination,
                targetProjectURL: targetProjectURL,
                record: record,
                now: now
            )
        }

        copierLogger.info(
            "Copied \(kind.displayName, privacy: .public) '\(source.lastPathComponent, privacy: .public)' to \(destination.path, privacy: .public); \(record.unresolvedLinks.count) unresolved source link(s)"
        )
        return Outcome(sourceURL: source, destinationURL: destination, kind: kind, record: record)
    }

    /// Read bundles go through the FASTQ copy workflow, which materialises
    /// symlinked reads and rewrites bundle provenance. Everything else uses
    /// the native copy service, which clones the tree and writes a receipt.
    /// A read bundle without provenance falls back to the native copy rather
    /// than refusing the drop.
    private static func copyBytes(kind: ItemKind, from source: URL, to destination: URL, sourceProjectURL: URL?) throws {
        if kind == .fastqBundle {
            do {
                _ = try FASTQBundleCopyImportWorkflow().importBundle(
                    sourceBundleURL: source,
                    outputURL: destination,
                    context: fastqCopyContext(source: source, destination: destination, sourceProjectURL: sourceProjectURL)
                )
                return
            } catch FASTQBundleCopyImportError.sourceProvenanceMissing {
                copierLogger.info("Read bundle \(source.lastPathComponent, privacy: .public) has no provenance; using native copy")
            }
        }
        _ = try NativeProjectCopyImportService.copy(from: source, to: destination, sourceProjectURL: sourceProjectURL)
    }

    private static func fastqCopyContext(source: URL, destination: URL, sourceProjectURL: URL?) -> FASTQBundleCopyImportWorkflow.CommandContext {
        let argv = [CLICommandIdentity.executableName, "fastq", "import-ont", source.path, "--output", destination.path]
        var resolved: [String: ParameterValue] = [
            "input": .file(source),
            "output": .file(destination),
            "destinationBundle": .file(destination),
            "sourceKind": .string("existing-fastq-bundle"),
            "copyMode": .string("atomic-bundle-copy"),
            "caller": .string("app-cross-project-copy"),
        ]
        if let sourceProjectURL {
            resolved["sourceProject"] = .file(sourceProjectURL)
        }
        return FASTQBundleCopyImportWorkflow.CommandContext(
            workflowName: "lungfish fastq import-ont",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "lungfish fastq import-ont",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            explicitOptions: ["input": .file(source), "output": .file(destination)],
            defaultOptions: ["sourceKind": .string("raw-ont-directory"), "copyMode": .string("none")],
            resolvedOptions: resolved,
            runtimeIdentity: ProvenanceRuntimeIdentity()
        )
    }

    /// When the reads a result came from are present in the target project,
    /// add the copied result to that bundle's analysis history so it shows
    /// up in the bundle's Inspector like a run made here.
    private static func registerInSourceBundleHistory(
        tool: String,
        analysisURL: URL,
        targetProjectURL: URL,
        record: ProjectItemCopyRecord,
        now: Date
    ) {
        let resolvedReadPaths = record.links.compactMap { link -> String? in
            guard link.isResolved, link.pointsIntoReadBundle else { return nil }
            return link.resolvedPath
        }
        var seenBundles = Set<String>()
        for path in resolvedReadPaths {
            guard let bundleURL = enclosingReadBundle(of: URL(fileURLWithPath: path)),
                  seenBundles.insert(bundleURL.path).inserted else { continue }
            let info = AnalysesFolder.analysisInfo(for: analysisURL)
            let entry = AnalysisManifestEntry(
                tool: tool,
                timestamp: info?.timestamp ?? now,
                analysisDirectoryName: AnalysisManifestStore.analysisDirectoryPath(for: analysisURL, projectURL: targetProjectURL)
                    ?? analysisURL.lastPathComponent,
                displayName: "\(AnalysesFolder.displayName(for: tool)) (copied)",
                parameters: [:],
                summary: record.sourceProjectName.map { "Copied from project \($0)" } ?? "Copied from another project",
                status: .completed
            )
            do {
                try AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL)
            } catch {
                copierLogger.warning("Could not record copied analysis in \(bundleURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func enclosingReadBundle(of url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.pathComponents.count > 1 {
            if current.pathExtension.lowercased() == FASTQBundle.directoryExtension {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }
}
