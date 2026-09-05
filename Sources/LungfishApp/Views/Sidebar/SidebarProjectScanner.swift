// SidebarProjectScanner.swift - nonisolated recursive project scan (F5, F7)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The recursive project walk that builds the sidebar tree. Every function here
// is `nonisolated` and touches only `Foundation` + the nonisolated `LungfishIO`
// / `LungfishCore` / `LungfishWorkflow` readers, so the whole scan can run off
// the main actor. It produces a `SidebarScanNode` value tree; turning that into
// the `SidebarItem` graph (and rendering badge images) is the main actor's job.
//
// This is a behavior-preserving extraction of what used to live inline in
// `SidebarViewController`. The tree it produces is pinned by
// `SidebarScanSnapshotParityTests`.

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

/// Recursive, main-actor-free project directory scanner.
///
/// All members are `static` and `nonisolated`; the type is a namespace, never
/// instantiated. It holds no state, so concurrent scans cannot interfere.
enum SidebarProjectScanner {

    // MARK: - Directory listing

    /// One directory entry plus the directory-ness we already resolved.
    ///
    /// Captured up front so sort comparators never re-probe the filesystem
    /// (an O(n log n) `fileExists` storm), which `SidebarDirectoryScanSnapshotTests`
    /// guards against.
    struct DirectoryEntry: Sendable {
        let url: URL
        let isDirectory: Bool
    }

    private static let directoryEntryResourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isHiddenKey,
        .isSymbolicLinkKey,
    ]

    /// Lists a directory's visible entries, resolving directory-ness once per entry.
    ///
    /// Symbolic links are followed for the directory test so that a symlinked
    /// folder still sorts and scans as a directory.
    static func directoryEntries(in directoryURL: URL) throws -> [DirectoryEntry] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(directoryEntryResourceKeys),
            options: [.skipsHiddenFiles]
        )

        return contents.compactMap { url in
            let values = try? url.resourceValues(forKeys: directoryEntryResourceKeys)
            guard values?.isHidden != true else { return nil }
            let isDirectory: Bool
            if values?.isSymbolicLink == true {
                var isDirectoryValue: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectoryValue)
                isDirectory = isDirectoryValue.boolValue
            } else if let resourceValue = values?.isDirectory {
                isDirectory = resourceValue
            } else {
                var isDirectoryValue: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectoryValue)
                isDirectory = isDirectoryValue.boolValue
            }
            return DirectoryEntry(url: url, isDirectory: isDirectory)
        }
    }

    /// Directories first, then files, each alphabetically (case-insensitive).
    private static func sortedEntries(_ entries: [DirectoryEntry]) -> [DirectoryEntry] {
        entries.sorted { entry1, entry2 in
            if entry1.isDirectory != entry2.isDirectory {
                return entry1.isDirectory // Directories first
            }
            return entry1.url.lastPathComponent
                .localizedCaseInsensitiveCompare(entry2.url.lastPathComponent) == .orderedAscending
        }
    }

    // MARK: - Root scan

    /// Scans a project directory and returns its contents as root-level nodes.
    ///
    /// The project folder's *contents* appear at the sidebar root (Finder-style),
    /// with a synthetic "Analyses" group prepended when the project has results.
    static func scanRootNodes(from projectURL: URL) -> [SidebarScanNode] {
        do {
            let sorted = sortedEntries(try directoryEntries(in: projectURL))

            var nodes: [SidebarScanNode] = []
            for entry in sorted {
                guard shouldIncludeEntry(
                    entry.url,
                    isDirectory: entry.isDirectory,
                    context: .projectRoot
                ) else { continue }

                nodes.append(scanTree(from: entry.url, isRoot: false))
            }

            // Insert a top-level "Analyses" group if the project has any results.
            let analysesChildren = collectAnalyses(in: projectURL)
            if !analysesChildren.isEmpty {
                var analysesGroup = SidebarScanNode(
                    title: "Analyses",
                    type: .folder,
                    badge: .symbol("flask"),
                    url: projectURL.appendingPathComponent(AnalysesFolder.directoryName),
                    children: analysesChildren
                )
                analysesGroup.userInfo["accessibilityIdentifier"] = SidebarAccessibilityIdentifier.analysesGroup
                nodes.insert(analysesGroup, at: 0)
            }

            return nodes
        } catch {
            sidebarLogger.error("scanRootNodes: Failed to scan directory: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Recursive tree scan

    /// Builds a node tree for a single filesystem entry.
    ///
    /// - Parameters:
    ///   - url: The file or directory to describe.
    ///   - isRoot: Whether this is the project folder itself.
    static func scanTree(from url: URL, isRoot: Bool = false) -> SidebarScanNode {
        let fileManager = FileManager.default
        let filename = url.lastPathComponent

        // Determine item type and icon.
        let itemType: SidebarItemType
        let icon: String

        if isRoot {
            itemType = .project
            icon = "folder.badge.gearshape"
        } else {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                if let bundleClassification = bundleClassification(for: url, fileManager: fileManager) {
                    itemType = bundleClassification.type
                    icon = bundleClassification.icon
                } else {
                    itemType = .folder
                    icon = "folder"
                }
            } else {
                let (type, iconName) = detectFileType(url: url)
                itemType = type
                icon = iconName
            }
        }

        // Bundles display without their directory extension.
        let displayName = (itemType == .referenceBundle
            || itemType == .mhcReferenceBundle
            || itemType == .multipleSequenceAlignmentBundle
            || itemType == .phylogeneticTreeBundle
            || itemType == .fastqBundle
            || itemType == .primerSchemeBundle
            || itemType == .genotypeResultBundle
            || itemType == .twelveSAmpliconResultBundle
            || itemType == .czIdResult)
            ? url.deletingPathExtension().lastPathComponent
            : filename

        // Composition subtitle for FASTQ bundles with mixed read types,
        // materialization state badge for virtual derivatives, and processing state.
        var subtitle: String?
        if itemType == .fastqBundle {
            // Check processing state first — overrides other badges.
            if case .processing(let detail) = FASTQBundle.processingState(of: url) {
                subtitle = detail
            } else if let manifest = FASTQBundle.loadDerivedManifest(in: url) {
                if let classification = manifest.readClassification {
                    subtitle = classification.compositionLabel
                }
                if case .virtual = manifest.resolvedState {
                    subtitle = (subtitle.map { $0 + " · " } ?? "") + "Virtual"
                }
            } else if let readManifest = ReadManifest.load(from: url) {
                subtitle = readManifest.classification.compositionLabel
            }
        } else if itemType == .czIdResult {
            subtitle = czIdResultTitle(for: url)
        }

        var node = SidebarScanNode(
            title: displayName,
            type: itemType,
            badge: .symbol(icon),
            url: url,
            subtitle: subtitle
        )

        // For FASTQ bundles, scan for demultiplexed child bundles inside demux/.
        if itemType == .fastqBundle {
            let demuxDir = url.appendingPathComponent("demux", isDirectory: true)

            // Load batch manifest first to build exclusion set (prevents duplicate nodes).
            let batchManifest = FASTQBatchManifest.load(from: demuxDir)
            var batchOutputURLs = Set<URL>()
            if let manifest = batchManifest {
                for record in manifest.operations {
                    for relativePath in record.outputBundlePaths {
                        batchOutputURLs.insert(
                            demuxDir.appendingPathComponent(relativePath).standardizedFileURL
                        )
                    }
                }
            }

            // Collect demux child bundles, excluding batch operation outputs.
            for childURL in collectDemuxChildBundles(in: url, excluding: batchOutputURLs) {
                node.children.append(scanTree(from: childURL, isRoot: false))
            }

            // Virtual batch group nodes from batch-operations.json.
            if let manifest = batchManifest {
                node.children.append(contentsOf: buildBatchGroupNodes(manifest: manifest, baseDirectory: demuxDir))
            }

            // Scan derivatives/ for non-demux child bundles, labelled by operation.
            for deriv in FASTQBundle.scanDerivatives(in: url) {
                var childNode = scanTree(from: deriv.url, isRoot: false)
                childNode.title = deriv.manifest.operation.displaySummary
                node.children.append(childNode)
            }

            // Analysis results (classification, EsViritu, TaxTriage, etc.) are now
            // collected from the project-level Analyses/ folder rather than from
            // inside each FASTQ bundle's derivatives/ directory.

            // Extracted read bundles (.lungfishfastq) written at the bundle's top level
            // by taxonomy extraction; these do not live in derivatives/.
            if let topLevelContents = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for childURL in topLevelContents where childURL.pathExtension == FASTQBundle.directoryExtension {
                    if FASTQBundle.isProcessing(childURL) { continue }
                    node.children.append(scanTree(from: childURL, isRoot: false))
                }
            }
        }

        // Directories recurse, except bundles which show as single items.
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue,
           !itemType.isBundle {
            do {
                let sorted = sortedEntries(try directoryEntries(in: url))

                for entry in sorted {
                    guard shouldIncludeEntry(
                        entry.url,
                        isDirectory: entry.isDirectory,
                        context: .regularDirectory
                    ) else { continue }

                    node.children.append(scanTree(from: entry.url, isRoot: false))
                }
            } catch {
                sidebarLogger.error("scanTree: Failed to scan directory: \(error.localizedDescription, privacy: .public)")
            }

            // NAO-MGS and NVD result bundles are standalone (in Analyses/ or legacy
            // Imports/), unlike classification results which live inside FASTQ bundles.
            node.children.append(contentsOf: collectNaoMgsResults(in: url))
            node.children.append(contentsOf: collectNvdResults(in: url))
        }

        return node
    }

    // MARK: - Classification and filtering

    enum ScanContext {
        case projectRoot
        case regularDirectory
        case analysesDirectory
    }

    /// Package boundaries are recognized before content validation. Even an invalid
    /// native package must never be traversed as a folder of independent inputs.
    static func isNativePackage(_ url: URL) -> Bool {
        bundleClassification(for: url) != nil
    }

    static func bundleClassification(
        for url: URL,
        fileManager: FileManager = .default
    ) -> (type: SidebarItemType, icon: String)? {
        switch url.pathExtension.lowercased() {
        case FASTQBundle.directoryExtension:
            return (.fastqBundle, "doc.text")
        case "lungfishref":
            return (.referenceBundle, "cylinder.split.1x2")
        case MHCAmpliconReferenceBundle.directoryExtension:
            return (.mhcReferenceBundle, "cylinder.split.1x2")
        case MultipleSequenceAlignmentBundle.directoryExtension:
            return (.multipleSequenceAlignmentBundle, "rectangle.grid.1x2")
        case "lungfishtree":
            return (.phylogeneticTreeBundle, "point.3.connected.trianglepath.dotted")
        case "lungfishprimers":
            return (.primerSchemeBundle, "line.horizontal.3.decrease.circle")
        case ONTGenotypeResultBundle.directoryExtension:
            return (.genotypeResultBundle, "tablecells.badge.ellipsis")
        case TwelveSAmpliconResultBundle.directoryExtension:
            return (.twelveSAmpliconResultBundle, "tablecells")
        case "lungfishtax":
            let manifestURL = url.appendingPathComponent("cz-id-manifest.json")
            if fileManager.fileExists(atPath: manifestURL.path) {
                return (.czIdResult, "c.circle")
            }
            return (.document, "shippingbox")
        default:
            if FASTQBundle.isBundleURL(url) {
                return (.fastqBundle, "doc.text")
            }
            // Native packages without a dedicated viewport remain atomic and use
            // the existing document preview, never a tree of their private files.
            if url.pathExtension.lowercased().hasPrefix("lungfish") {
                return (.document, "shippingbox")
            }
            return nil
        }
    }

    static func shouldIncludeEntry(
        _ url: URL,
        isDirectory: Bool,
        context: ScanContext
    ) -> Bool {
        if isInternalSidecarFile(url) {
            return false
        }

        guard isDirectory else {
            return true
        }

        if context == .projectRoot, url.lastPathComponent == AnalysesFolder.directoryName {
            return false
        }
        if context == .projectRoot, url.lastPathComponent == "provenance" {
            return false
        }
        if OperationMarker.isInProgress(url) {
            return false
        }
        if FASTQBundle.isBundleURL(url), FASTQBundle.isProcessing(url) {
            return false
        }
        if isFASTQOperationStagingDirectory(url) {
            return false
        }
        if context == .regularDirectory, isMetagenomicsResultDirectory(url) {
            return false
        }
        if isDirectory, isWorkflowInternalDirectory(url) {
            return false
        }

        return true
    }

    /// Returns true for the pipeline's own working artefacts, which are never
    /// shown even though they sit in `Analyses/` beside the real analysis.
    ///
    /// A Viral Recon run leaves the raw nf-core output tree and a
    /// `.lungfishrun` run bundle next to the ingested analysis it produced.
    /// Neither has an `analysisInfo`, so the scanner fell through to
    /// `scanTree(from:)` and walked the raw tree with no depth limit: the user
    /// saw the intended node plus thousands of files of pipeline internals.
    ///
    /// The raw tree is matched on the wizard's own `viralrecon-results-<token>`
    /// naming, so a user folder merely named after the tool stays visible.
    static func isWorkflowInternalDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if url.pathExtension == NFCoreRunBundleStore.directoryExtension {
            return true
        }
        return name.hasPrefix("viralrecon-results-")
    }

    /// Detects the file type and appropriate icon for a URL, via the unified
    /// `FileTypeUtility` so detection matches the rest of the app.
    static func detectFileType(url: URL) -> (SidebarItemType, String) {
        let fileInfo = FileTypeUtility.detect(url: url)
        return (SidebarItemType(from: fileInfo.category), fileInfo.iconName)
    }

    /// Returns true for internal sidecar/metadata files hidden from the sidebar.
    ///
    /// Hides known app sidecars and indexes. Unknown user files, including
    /// unknown extensions and ordinary JSON/CSV/TSV files, remain visible.
    static func isInternalSidecarFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        if name.hasPrefix("._") || name == ".DS_Store" {
            return true
        }
        if ["bai", "csi", "fai", "gzi", "tbi"].contains(ext) {
            return true
        }
        if name.hasSuffix(".lungfish-meta.json")
            || name.hasSuffix(".lungfish-provenance.json")
            || name.hasSuffix("-provenance.json") {
            return true
        }
        if name == FASTQBundleCSVMetadata.filename {
            return true
        }

        let internalJSONFilenames: Set<String> = [
            ".lungfish-provenance.json",
            "analysis-metadata.json",
            "analyses-manifest.json",
            "alignment-result.json",
            "assembly-result.json",
            "batch.manifest.json",
            "classification-batch-result.json",
            "classification-result.json",
            "cz-id-manifest.json",
            "demux-manifest.json",
            "derived.manifest.json",
            "esviritu-batch-result.json",
            "esviritu-result.json",
            "extraction-metadata.json",
            ONTGenotypeResultBundleManifest.filename,
            "mapping-result.json",
            "manifest.json",
            "read-manifest.json",
            "scout-result.json",
            "source-files.json",
            "taxtriage-batch-manifest.json",
            "taxtriage-result.json",
            "viralrecon-result.json",
        ]
        return internalJSONFilenames.contains(name)
    }

    /// Returns true for metagenomics result directories hidden from the generic
    /// directory scanner because dedicated batch-group or result nodes already
    /// represent them.
    ///
    /// Prefix checks run first for speed, then a sidecar-content fallback so
    /// user-renamed directories are still recognised.
    static func isMetagenomicsResultDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let fm = FileManager.default

        // TaxTriage result directories (taxtriage-XXXXXXXX)
        if name.hasPrefix("taxtriage-") {
            let sidecar = url.appendingPathComponent("taxtriage-result.json")
            if fm.fileExists(atPath: sidecar.path) { return true }
            let hasKraken = fm.fileExists(atPath: url.appendingPathComponent("kraken2").path)
            if hasKraken { return true }
        }

        // Classification result directories
        if name.hasPrefix("classification-") {
            let sidecar = url.appendingPathComponent("classification-result.json")
            if fm.fileExists(atPath: sidecar.path) { return true }
        }

        // EsViritu result directories
        if name.hasPrefix("esviritu-") {
            let sidecar = url.appendingPathComponent("esviritu-result.json")
            if fm.fileExists(atPath: sidecar.path) { return true }
        }

        // NAO-MGS result bundles
        if name.hasPrefix("naomgs-") {
            let sidecar = url.appendingPathComponent("manifest.json")
            if fm.fileExists(atPath: sidecar.path) { return true }
        }

        // NVD result bundles
        if name.hasPrefix("nvd-") {
            let sidecar = url.appendingPathComponent("manifest.json")
            if fm.fileExists(atPath: sidecar.path) { return true }
        }

        // CZ-ID imported result bundles
        if name.hasPrefix("cz-id-"), url.pathExtension.lowercased() != "lungfishtax" {
            let sidecar = url.appendingPathComponent("cz-id-manifest.json")
            if fm.fileExists(atPath: sidecar.path) { return true }
        }

        // Authoritative metadata sidecar: analysis-metadata.json is written at
        // directory creation time and survives renames.
        if fm.fileExists(atPath: url.appendingPathComponent(AnalysesFolder.metadataFilename).path) {
            return true
        }

        // Content-based fallback: detect renamed analysis directories by their
        // signature files (e.g. manifest.json + hits.sqlite for NAO-MGS).
        // Only directories inside the Analyses/ folder reach this check, so
        // the probe cost is bounded.
        if url.deletingLastPathComponent().lastPathComponent == AnalysesFolder.directoryName {
            if fm.fileExists(atPath: url.appendingPathComponent("classification-result.json").path) { return true }
            if fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path),
               fm.fileExists(atPath: url.appendingPathComponent("hits.sqlite").path) { return true }
        }

        return false
    }

    static func isFASTQOperationStagingDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("cli-output-")
            || name.hasPrefix("materialized-inputs-")
    }

    // MARK: - FASTQ bundle children

    /// Collects child `.lungfishfastq` bundles from a parent bundle's `demux/` directory.
    ///
    /// Recurses through the `demux/` tree, skipping `materialized/` (intermediate
    /// full FASTQs used during processing). Returns bundles sorted alphabetically.
    static func collectDemuxChildBundles(in bundleURL: URL, excluding: Set<URL> = []) -> [URL] {
        let demuxDir = bundleURL.appendingPathComponent("demux", isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: demuxDir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var results: [URL] = []
        func scan(_ dir: URL) {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for childURL in contents {
                var childIsDir: ObjCBool = false
                fm.fileExists(atPath: childURL.path, isDirectory: &childIsDir)
                guard childIsDir.boolValue else { continue }

                // Skip materialized/ (temporary full FASTQs during active processing).
                if childURL.lastPathComponent == "materialized" { continue }

                if FASTQBundle.isBundleURL(childURL) {
                    // Skip batch operation outputs (shown under batch group nodes).
                    if !excluding.contains(childURL.standardizedFileURL) && !FASTQBundle.isProcessing(childURL) {
                        results.append(childURL)
                    }
                } else {
                    // Recurse into non-bundle subdirectories (e.g. barcode13/).
                    scan(childURL)
                }
            }
        }
        scan(demuxDir)
        return results.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// Builds virtual batch group nodes from a pre-loaded batch manifest.
    static func buildBatchGroupNodes(manifest: FASTQBatchManifest, baseDirectory: URL) -> [SidebarScanNode] {
        manifest.operations.map { record in
            var groupNode = SidebarScanNode(
                title: record.label,
                type: .batchGroup,
                badge: .symbol("tray.2"),
                url: nil,
                subtitle: "\(record.successCount) processed"
            )

            for relativePath in record.outputBundlePaths {
                let outputURL = baseDirectory.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    groupNode.children.append(scanTree(from: outputURL, isRoot: false))
                }
            }

            return groupNode
        }
    }

    // MARK: - Analyses/ folder scanning

    /// Collects analysis results from the project-level `Analyses/` directory.
    static func collectAnalyses(in projectURL: URL) -> [SidebarScanNode] {
        let analysesDir = projectURL.appendingPathComponent(AnalysesFolder.directoryName, isDirectory: true)
        return collectAnalysisItems(in: analysesDir, includeLooseFolders: true)
    }

    static func collectAnalysisItems(in directoryURL: URL, includeLooseFolders: Bool) -> [SidebarScanNode] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var nodes: [SidebarScanNode] = []
        for url in contents.sorted(by: {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard shouldIncludeEntry(
                url,
                isDirectory: isDirectory,
                context: .analysesDirectory
            ) else { continue }

            if !isDirectory {
                nodes.append(scanTree(from: url, isRoot: false))
                continue
            }
            if bundleClassification(for: url) != nil {
                nodes.append(scanTree(from: url, isRoot: false))
                continue
            }

            if let info = AnalysesFolder.analysisInfo(for: url) {
                if let node = buildAnalysisNode(info: info) {
                    nodes.append(node)
                }
                continue
            }

            let children = collectAnalysisItems(in: url, includeLooseFolders: false)
            if !children.isEmpty {
                nodes.append(SidebarScanNode(
                    title: url.lastPathComponent,
                    type: .folder,
                    badge: .symbol("folder"),
                    url: url,
                    children: children
                ))
            } else if includeLooseFolders {
                nodes.append(scanTree(from: url, isRoot: false))
            }
        }

        return nodes
    }

    static func buildAnalysisNode(info: AnalysesFolder.AnalysisDirectoryInfo) -> SidebarScanNode? {
        if info.isBatch {
            return buildBatchAnalysisNode(info: info)
        }

        let icon = analysisIcon(for: info.tool)
        let title = analysisDisplayTitle(for: info)
        let badge = classifierBatchBadge(for: info.tool)

        var node = SidebarScanNode(
            title: title,
            type: analysisItemType(for: info.tool),
            badge: badge.map { SidebarBadgeDescriptor.text($0) } ?? .symbol(icon),
            url: info.url,
            subtitle: AnalysesFolder.formatTimestamp(info.timestamp)
        )
        node.userInfo["analysisTool"] = info.tool

        if info.tool == "esviritu" {
            node.subtitle = esvirituResultTitle(for: info.url)
        } else if info.tool == "kraken2" {
            node.subtitle = classificationResultTitle(for: info.url)
        } else if info.tool == "cz-id" {
            node.subtitle = czIdResultTitle(for: info.url)
        }
        return node
    }

    /// Builds a batch group node for a classifier or generic tool batch.
    ///
    /// For the classifier tools (Kraken2, EsViritu, TaxTriage, …) the batch is a
    /// LEAF node — no per-sample children, no disclosure triangle. Sample filtering
    /// happens inside the batch viewer via the sample picker, and the row uses a
    /// text pill badge (K2 / ES / TT) in Lungfish Orange.
    ///
    /// Generic tools (SPAdes, minimap2, …) still enumerate per-sample children.
    static func buildBatchAnalysisNode(info: AnalysesFolder.AnalysisDirectoryInfo) -> SidebarScanNode? {
        let title = analysisDisplayTitle(for: info)

        // Classifier batches: leaf node with a text badge and no children.
        if let badge = classifierBatchBadge(for: info.tool) {
            guard let subtitle = classifierBatchSubtitle(for: info) else {
                return nil  // skip corrupt/empty batches
            }
            return SidebarScanNode(
                title: title,
                type: .batchGroup,
                badge: .text(badge),
                url: info.url,
                subtitle: subtitle
            )
        }

        // Generic tools: expandable group with per-sample children.
        var groupNode = SidebarScanNode(
            title: title,
            type: .batchGroup,
            badge: .symbol("tray.2"),
            url: info.url,
            subtitle: AnalysesFolder.formatTimestamp(info.timestamp)
        )
        appendBatchChildrenFromFilesystem(
            info: info,
            groupNode: &groupNode,
            sidecarCheck: { _ in true },
            itemType: .analysisResult,
            icon: analysisIcon(for: info.tool)
        )
        guard !groupNode.children.isEmpty else { return nil }
        return groupNode
    }

    /// The badge text for a classifier batch sidebar icon, or nil for non-classifier tools.
    static func classifierBatchBadge(for tool: String) -> String? {
        switch tool {
        case "kraken2": return "K2"
        case "esviritu": return "ES"
        case "taxtriage": return "TT"
        case "naomgs": return "NM"
        case "nvd": return "NVD"
        case "cz-id": return "CZ"
        default: return nil
        }
    }

    /// Computes the subtitle for a classifier batch sidebar row.
    ///
    /// Prefers the batch manifest (accurate sample count and database name) and
    /// falls back to a filesystem scan when no manifest is present. Returns nil
    /// when the batch is genuinely empty so the caller can skip it.
    static func classifierBatchSubtitle(for info: AnalysesFolder.AnalysisDirectoryInfo) -> String? {
        let timestamp = AnalysesFolder.formatTimestamp(info.timestamp)

        switch info.tool {
        case "esviritu":
            if let manifest = MetagenomicsBatchResultStore.loadEsViritu(from: info.url) {
                return "\(manifest.header.sampleCount) samples · \(timestamp)"
            }
            let count = countBatchSampleSubdirectories(in: info.url, sidecarCheck: EsVirituResult.exists)
            return count > 0 ? "\(count) samples · \(timestamp)" : nil

        case "kraken2":
            if let manifest = MetagenomicsBatchResultStore.loadClassification(from: info.url) {
                let dbLabel = manifest.databaseName.isEmpty ? "" : " · \(manifest.databaseName)"
                return "\(manifest.header.sampleCount) samples\(dbLabel) · \(timestamp)"
            }
            let count = countBatchSampleSubdirectories(in: info.url, sidecarCheck: ClassificationResult.exists)
            return count > 0 ? "\(count) samples · \(timestamp)" : nil

        case "taxtriage":
            // TaxTriage writes sample subdirectories but no batch manifest.
            let count = countBatchSampleSubdirectories(in: info.url, sidecarCheck: { _ in true })
            return count > 0 ? "\(count) samples · \(timestamp)" : nil

        case "naomgs":
            let manifestURL = info.url.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let manifest = try? decoder.decode(NaoMgsManifest.self, from: data) {
                    let count = max(1, Set(manifest.cachedTaxonRows?.map(\.sample) ?? []).count)
                    return "\(count) samples · \(timestamp)"
                }
            }
            return timestamp

        case "nvd":
            let manifestURL = info.url.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let manifest = try? decoder.decode(NvdManifest.self, from: data) {
                    return "\(manifest.sampleCount) samples · \(timestamp)"
                }
            }
            return timestamp

        case "cz-id":
            let manifestURL = info.url.appendingPathComponent("cz-id-manifest.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(CzIdImportManifest.self, from: data) {
                return "\(manifest.rowCount) taxa · \(timestamp)"
            }
            return timestamp

        default:
            return timestamp
        }
    }

    /// Counts valid sample subdirectories inside a batch directory.
    static func countBatchSampleSubdirectories(
        in batchURL: URL,
        sidecarCheck: (URL) -> Bool
    ) -> Int {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: batchURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        return contents.reduce(0) { count, child in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else {
                return count
            }
            return sidecarCheck(child) ? count + 1 : count
        }
    }

    /// Fallback: enumerate batch children when no batch manifest is available.
    ///
    /// Most batch producers (mapping, assembly) write one subdirectory per
    /// sample. Savont writes flat per-sample FILES directly inside the batch
    /// directory instead. Both shapes are batch children; only the metadata
    /// sidecar itself is excluded.
    static func appendBatchChildrenFromFilesystem(
        info: AnalysesFolder.AnalysisDirectoryInfo,
        groupNode: inout SidebarScanNode,
        sidecarCheck: (URL) -> Bool,
        itemType: SidebarItemType,
        icon: String
    ) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: info.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in contents.sorted(by: {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }) {
            guard child.lastPathComponent != AnalysesFolder.metadataFilename else { continue }
            guard fm.fileExists(atPath: child.path) else { continue }
            guard sidecarCheck(child) else { continue }
            var childNode = SidebarScanNode(
                title: child.lastPathComponent,
                type: itemType,
                badge: .symbol(icon),
                url: child
            )
            // Identify the child as a specific sample so the routing layer can
            // filter the batch view to just this sample after display.
            childNode.userInfo["sampleId"] = child.lastPathComponent
            childNode.userInfo["analysisTool"] = info.tool
            groupNode.children.append(childNode)
        }
        groupNode.subtitle = "\(groupNode.children.count) samples"
    }

    static func analysisIcon(for tool: String) -> String {
        switch tool {
        case "esviritu": return "e.circle"
        case "kraken2": return "k.circle"
        case "taxtriage": return "t.circle"
        case "mafft": return "rectangle.grid.1x2"
        case "spades", "megahit", "skesa", "flye", "hifiasm": return "s.circle"
        case "minimap2", "bwa-mem2", "bowtie2", "bbmap": return "m.circle"
        case "naomgs": return "n.circle"
        case "cz-id": return "c.circle"
        case "ont-genotyping": return "tablecells.badge.ellipsis"
        case "viralrecon": return "v.circle"
        default: return "circle"
        }
    }

    static func analysisDisplayTitle(for info: AnalysesFolder.AnalysisDirectoryInfo) -> String {
        if analysisItemType(for: info.tool).isBundle {
            return info.url.deletingPathExtension().lastPathComponent
        }
        return info.url.lastPathComponent
    }

    /// Maps an analysis tool name to the correct `SidebarItemType` so the selection
    /// handler in `MainSplitViewController` dispatches to the right display method.
    static func analysisItemType(for tool: String) -> SidebarItemType {
        switch tool {
        case "esviritu": return .esvirituResult
        case "kraken2": return .classificationResult
        case "taxtriage": return .taxTriageResult
        case "mafft": return .multipleSequenceAlignmentBundle
        case "naomgs": return .naoMgsResult
        case "nvd": return .nvdResult
        case "cz-id": return .czIdResult
        case "ont-genotyping": return .genotypeResultBundle
        // Viral Recon publishes its alignment and variants into a reference
        // bundle inside the analysis directory, so it routes through the
        // generic analysis-result path like the mapping tools do.
        case "viralrecon": return .analysisResult
        default: return .analysisResult
        }
    }

    // MARK: - Result titles

    /// Derives a human-readable title for a classification result directory,
    /// reading only the lightweight sidecar (no tree parsing).
    static func classificationResultTitle(for directory: URL) -> String {
        let sidecarURL = directory.appendingPathComponent("classification-result.json")
        if let data = try? Data(contentsOf: sidecarURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let config = json["config"] as? [String: Any],
           let dbName = config["databaseName"] as? String {
            return "Classification (\(dbName))"
        }
        return "Classification"
    }

    /// Derives a human-readable title for an EsViritu result directory.
    static func esvirituResultTitle(for directory: URL) -> String {
        let sidecarURL = directory.appendingPathComponent("esviritu-result.json")
        if let data = try? Data(contentsOf: sidecarURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let virusCount = json["virusCount"] as? Int {
            return "Viral Detection (\(virusCount) viruses)"
        }
        return "Viral Detection"
    }

    /// Derives a human-readable title for a CZ-ID imported result directory.
    static func czIdResultTitle(for directory: URL) -> String {
        let manifestURL = directory.appendingPathComponent("cz-id-manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(CzIdImportManifest.self, from: data) {
            return "CZ-ID · \(manifest.sampleName)"
        }
        return "CZ-ID"
    }

    // MARK: - Standalone result bundles

    /// Collects NAO-MGS result bundles from inside a directory.
    ///
    /// Matches `naomgs-*` directories (or ones whose `analysis-metadata.json`
    /// declares `tool=naomgs`) that carry a `manifest.json` sidecar.
    static func collectNaoMgsResults(in bundleURL: URL) -> [SidebarScanNode] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [SidebarScanNode] = []

        for childURL in contents {
            guard !OperationMarker.isInProgress(childURL) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: childURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let hasPrefix = childURL.lastPathComponent.hasPrefix("naomgs-")
            let hasMetadata = AnalysesFolder.readAnalysisMetadata(from: childURL)?.tool == "naomgs"
            guard hasPrefix || hasMetadata else { continue }

            let manifestURL = childURL.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            results.append(SidebarScanNode(
                title: naoMgsResultTitle(for: childURL),
                type: .naoMgsResult,
                badge: .text("NM"),
                url: childURL
            ))
        }

        return results.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Derives a display title for a NAO-MGS result bundle, falling back to
    /// "NAO-MGS" when the manifest cannot be read.
    static func naoMgsResultTitle(for directory: URL) -> String {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return "NAO-MGS"
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(NaoMgsManifest.self, from: data) else {
            return "NAO-MGS"
        }
        return "NAO-MGS: \(manifest.sampleName)"
    }

    /// Collects NVD result bundles from inside a directory.
    ///
    /// Matches `nvd-*` directories (or ones whose `analysis-metadata.json`
    /// declares `tool=nvd`) that carry a `manifest.json` sidecar.
    static func collectNvdResults(in bundleURL: URL) -> [SidebarScanNode] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [SidebarScanNode] = []

        for childURL in contents {
            guard !OperationMarker.isInProgress(childURL) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: childURL.path, isDirectory: &isDir), isDir.boolValue else { continue }

            let hasPrefix = childURL.lastPathComponent.hasPrefix("nvd-")
            let hasMetadata = AnalysesFolder.readAnalysisMetadata(from: childURL)?.tool == "nvd"
            guard hasPrefix || hasMetadata else { continue }

            let manifestURL = childURL.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            results.append(SidebarScanNode(
                title: nvdResultTitle(for: childURL),
                type: .nvdResult,
                badge: .text("NVD"),
                url: childURL
            ))
        }

        return results.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Derives a display title for an NVD result bundle, falling back to "NVD"
    /// when the manifest cannot be read.
    static func nvdResultTitle(for directory: URL) -> String {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return "NVD"
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(NvdManifest.self, from: data) else {
            return "NVD"
        }
        return "NVD: \(manifest.experiment)"
    }
}
