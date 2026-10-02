import CryptoKit
import Foundation
import LungfishCore
import SQLite3

public struct PhylogeneticTreeBundle: Sendable, Equatable {
    public let url: URL
    public let manifest: PhylogeneticTreeManifest
    public let normalizedTree: PhylogeneticTreeNormalizedTree

    public static func load(from url: URL) throws -> PhylogeneticTreeBundle {
        let fm = FileManager.default
        let manifestURL = url.appendingPathComponent("manifest.json")
        let normalizedURL = url.appendingPathComponent("tree/primary.normalized.json")
        let required = [
            manifestURL,
            url.appendingPathComponent("tree/source.original"),
            url.appendingPathComponent("tree/primary.nwk"),
            normalizedURL,
            url.appendingPathComponent("cache/tree-index.sqlite"),
            url.appendingPathComponent(".viewstate.json"),
            url.appendingPathComponent(".lungfish-provenance.json")
        ]

        for fileURL in required where !fm.fileExists(atPath: fileURL.path) {
            throw PhylogeneticTreeBundleError.missingBundleFile(fileURL.lastPathComponent)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            PhylogeneticTreeManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let normalized = try decoder.decode(
            PhylogeneticTreeNormalizedTree.self,
            from: Data(contentsOf: normalizedURL)
        )
        return PhylogeneticTreeBundle(url: url, manifest: manifest, normalizedTree: normalized)
    }

    public func subtreeExport(nodeID: String) throws -> PhylogeneticTreeSubtreeExport {
        try PhylogeneticTreeSubtreeExporter(bundle: self).export(nodeID: nodeID)
    }

    public func subtreeExport(label: String) throws -> PhylogeneticTreeSubtreeExport {
        try PhylogeneticTreeSubtreeExporter(bundle: self).export(label: label)
    }

    public func subtreeNewick(nodeID: String) throws -> String {
        try subtreeExport(nodeID: nodeID).newick
    }

    public func subtreeNewick(label: String) throws -> String {
        try subtreeExport(label: label).newick
    }

    public func extractSubtreeBundle(
        nodeID: String,
        to destinationURL: URL,
        provenance: PhylogeneticTreeBundleTransformProvenance
    ) throws -> PhylogeneticTreeBundle {
        let selected = try resolveNode(selector: nodeID)
        let export = try subtreeExport(nodeID: selected.id)
        var options = provenance.options
        options["node"] = nodeID
        options["resolvedNodeID"] = selected.id
        options["selectedTipCount"] = "\(export.descendantTipCount)"
        return try writeDerivedBundle(
            newick: export.newick,
            destinationURL: destinationURL,
            workflowName: "phylogenetic-tree-extract-subtree",
            actionID: "tree.extract-subtree",
            provenance: provenance.withOptions(options),
            isRooted: manifest.isRooted
        )
    }

    public func rerootedBundle(
        on selector: String,
        to destinationURL: URL,
        provenance: PhylogeneticTreeBundleTransformProvenance
    ) throws -> PhylogeneticTreeBundle {
        let selected = try resolveNode(selector: selector)
        var options = provenance.options
        options["on"] = selector
        options["resolvedNodeID"] = selected.id
        // The new root sits at the midpoint of the branch above the selected node (outgroup rooting).
        options["rooting"] = "branch-midpoint"
        return try writeDerivedBundle(
            newick: try PhylogeneticTreeRerooter(bundle: self).newick(rootedOn: selected),
            destinationURL: destinationURL,
            workflowName: "phylogenetic-tree-reroot",
            actionID: "tree.reroot",
            provenance: provenance.withOptions(options),
            isRooted: true
        )
    }

    public func relabeledBundle(
        column: String,
        to destinationURL: URL,
        provenance: PhylogeneticTreeBundleTransformProvenance
    ) throws -> PhylogeneticTreeBundle {
        let metadataURL = url.appendingPathComponent("metadata.tsv")
        let metadata = try TreeTipMetadataTable.load(from: metadataURL)
        let labelsByTip = try metadata.labelsByTip(column: column)
        let newick = try PhylogeneticTreeRelabeler(bundle: self).newick(labelsByTip: labelsByTip)
        var options = provenance.options
        options["column"] = column
        options["metadataPath"] = metadataURL.path
        return try writeDerivedBundle(
            newick: newick,
            destinationURL: destinationURL,
            workflowName: "phylogenetic-tree-relabel",
            actionID: "tree.relabel",
            provenance: provenance.withOptions(options),
            isRooted: manifest.isRooted,
            metadataURL: metadataURL
        )
    }

    public func resolveNode(selector: String) throws -> PhylogeneticTreeNormalizedNode {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if let node = normalizedTree.nodes.first(where: { $0.id == trimmed }) {
            return node
        }
        let matches = normalizedTree.nodes.filter { $0.displayLabel == trimmed || $0.rawLabel == trimmed }
        guard matches.isEmpty == false else {
            throw PhylogeneticTreeBundleError.nodeNotFound(selector)
        }
        guard matches.count == 1, let node = matches.first else {
            throw PhylogeneticTreeBundleError.ambiguousNodeLabel(selector)
        }
        return node
    }

    private func writeDerivedBundle(
        newick: String,
        destinationURL: URL,
        workflowName: String,
        actionID: String,
        provenance: PhylogeneticTreeBundleTransformProvenance,
        isRooted: Bool,
        metadataURL: URL? = nil
    ) throws -> PhylogeneticTreeBundle {
        let started = Date()
        let fm = FileManager.default
        let destinationURL = destinationURL.standardizedFileURL
        guard !fm.fileExists(atPath: destinationURL.path) else {
            throw PhylogeneticTreeBundleError.destinationAlreadyExists(destinationURL.path)
        }
        let sourceText = newick.hasSuffix("\n") ? newick : newick + "\n"
        let parsed = try TreeInputParser.parse(
            text: sourceText,
            sourceURL: URL(fileURLWithPath: "derived.nwk"),
            requestedFormat: "newick"
        )
        let normalized = TreeNormalizer.normalizedTree(from: parsed.tree, rooted: isRooted)
        let warnings = TreeWarningCollector.warnings(for: normalized)
        do {
            try fm.createDirectory(at: destinationURL.appendingPathComponent("tree"), withIntermediateDirectories: true)
            try fm.createDirectory(at: destinationURL.appendingPathComponent("cache"), withIntermediateDirectories: true)
            try Data(sourceText.utf8).write(to: destinationURL.appendingPathComponent("tree/source.original"), options: .atomic)
            try Data(sourceText.utf8).write(to: destinationURL.appendingPathComponent("tree/primary.nwk"), options: .atomic)
            if let metadataURL {
                try fm.copyItem(at: metadataURL, to: destinationURL.appendingPathComponent("metadata.tsv"))
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(normalized).write(to: destinationURL.appendingPathComponent("tree/primary.normalized.json"), options: .atomic)
            try encoder.encode(PhylogeneticTreeViewState()).write(to: destinationURL.appendingPathComponent(".viewstate.json"), options: .atomic)
            try TreeIndexWriter.write(normalizedTree: normalized, to: destinationURL.appendingPathComponent("cache/tree-index.sqlite"))

            var payloadPaths = [
                "tree/source.original",
                "tree/primary.nwk",
                "tree/primary.normalized.json",
                "cache/tree-index.sqlite",
                ".viewstate.json"
            ]
            if metadataURL != nil {
                payloadPaths.append("metadata.tsv")
            }
            let manifest = PhylogeneticTreeManifest(
                schemaVersion: 1,
                bundleKind: "phylogenetic-tree",
                identifier: UUID().uuidString,
                name: destinationURL.deletingPathExtension().lastPathComponent,
                createdAt: Date(),
                sourceFormat: "newick",
                sourceFileName: url.lastPathComponent,
                treeCount: 1,
                primaryTreeID: normalized.treeID,
                isRooted: isRooted,
                tipCount: normalized.nodes.filter(\.isTip).count,
                internalNodeCount: normalized.nodes.filter { !$0.isTip }.count,
                branchLengthUnit: self.manifest.branchLengthUnit,
                dateScale: self.manifest.dateScale,
                warnings: warnings,
                capabilities: ["rectangular-phylogram", "metadata-inspector", "subtree-export", "tree-reroot", "tree-relabel"],
                checksums: try treeChecksumMap(paths: payloadPaths, bundleURL: destinationURL),
                fileSizes: try treeFileSizeMap(paths: payloadPaths, bundleURL: destinationURL)
            )
            try encoder.encode(manifest).write(to: destinationURL.appendingPathComponent("manifest.json"), options: .atomic)

            var allPaths = payloadPaths
            allPaths.append("manifest.json")
            let provenanceJSON = try derivedTreeProvenance(
                workflowName: workflowName,
                actionID: actionID,
                provenance: provenance,
                sourceBundleURL: url,
                outputBundleURL: destinationURL,
                payloadPaths: allPaths,
                warnings: warnings,
                wallTimeSeconds: Date().timeIntervalSince(started),
                metadataURL: metadataURL
            )
            try writeTreeJSONObject(provenanceJSON, to: destinationURL.appendingPathComponent(".lungfish-provenance.json"))
            return PhylogeneticTreeBundle(url: destinationURL, manifest: manifest, normalizedTree: normalized)
        } catch {
            try? fm.removeItem(at: destinationURL)
            throw error
        }
    }
}

public struct PhylogeneticTreeBundleTransformProvenance: Sendable, Equatable {
    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let command: String?
    public let options: [String: String]
    public let stderr: String?

    public init(
        toolName: String,
        toolVersion: String = PhylogeneticTreeBundleImporter.toolVersion,
        argv: [String],
        command: String? = nil,
        options: [String: String] = [:],
        stderr: String? = nil
    ) {
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.argv = argv
        self.command = command
        self.options = options
        self.stderr = stderr
    }

    fileprivate func withOptions(_ options: [String: String]) -> PhylogeneticTreeBundleTransformProvenance {
        PhylogeneticTreeBundleTransformProvenance(
            toolName: toolName,
            toolVersion: toolVersion,
            argv: argv,
            command: command,
            options: options,
            stderr: stderr
        )
    }
}

public enum PhylogeneticTreeBundleImporter {
    public static let toolVersion = "0.1.0"

    public static func importTree(
        from sourceURL: URL,
        to destinationURL: URL,
        options: PhylogeneticTreeImportOptions = .init()
    ) throws -> PhylogeneticTreeBundle {
        let started = Date()
        let fm = FileManager.default
        let sourceURL = sourceURL.standardizedFileURL
        let destinationURL = destinationURL.standardizedFileURL
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw PhylogeneticTreeBundleError.sourceMissing(sourceURL.path)
        }
        guard !fm.fileExists(atPath: destinationURL.path) else {
            throw PhylogeneticTreeBundleError.destinationAlreadyExists(destinationURL.path)
        }

        let sourceData = try Data(contentsOf: sourceURL)
        guard let sourceText = String(data: sourceData, encoding: .utf8) else {
            throw PhylogeneticTreeBundleError.parseFailed("Input is not valid UTF-8 text.")
        }

        let parsed = try TreeInputParser.parse(
            text: sourceText,
            sourceURL: sourceURL,
            requestedFormat: options.sourceFormat
        )
        let normalized = TreeNormalizer.normalizedTree(from: parsed.tree, rooted: parsed.isRooted)
        let warnings = TreeWarningCollector.warnings(for: normalized)
        let primaryNewick = NewickWriter.write(parsed.tree) + "\n"

        do {
            try fm.createDirectory(at: destinationURL.appendingPathComponent("tree"), withIntermediateDirectories: true)
            try fm.createDirectory(at: destinationURL.appendingPathComponent("cache"), withIntermediateDirectories: true)
            try sourceData.write(to: destinationURL.appendingPathComponent("tree/source.original"), options: .atomic)
            try Data(primaryNewick.utf8).write(
                to: destinationURL.appendingPathComponent("tree/primary.nwk"),
                options: .atomic
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(normalized).write(
                to: destinationURL.appendingPathComponent("tree/primary.normalized.json"),
                options: .atomic
            )

            let viewState = PhylogeneticTreeViewState()
            try encoder.encode(viewState).write(
                to: destinationURL.appendingPathComponent(".viewstate.json"),
                options: .atomic
            )

            try TreeIndexWriter.write(
                normalizedTree: normalized,
                to: destinationURL.appendingPathComponent("cache/tree-index.sqlite")
            )

            let payloadPaths = [
                "tree/source.original",
                "tree/primary.nwk",
                "tree/primary.normalized.json",
                "cache/tree-index.sqlite",
                ".viewstate.json"
            ]
            let payloadChecksums = try checksumMap(paths: payloadPaths, bundleURL: destinationURL)
            let payloadSizes = try fileSizeMap(paths: payloadPaths, bundleURL: destinationURL)
            let manifest = PhylogeneticTreeManifest(
                schemaVersion: 1,
                bundleKind: "phylogenetic-tree",
                identifier: UUID().uuidString,
                name: options.name ?? sourceURL.deletingPathExtension().lastPathComponent,
                createdAt: Date(),
                sourceFormat: parsed.sourceFormat,
                sourceFileName: sourceURL.lastPathComponent,
                treeCount: parsed.treeCount,
                primaryTreeID: normalized.treeID,
                isRooted: parsed.isRooted,
                tipCount: normalized.nodes.filter(\.isTip).count,
                internalNodeCount: normalized.nodes.filter { !$0.isTip }.count,
                branchLengthUnit: nil,
                dateScale: nil,
                warnings: warnings,
                capabilities: ["rectangular-phylogram", "metadata-inspector", "subtree-export"],
                checksums: payloadChecksums,
                fileSizes: payloadSizes
            )
            try encoder.encode(manifest).write(
                to: destinationURL.appendingPathComponent("manifest.json"),
                options: .atomic
            )

            var allPaths = payloadPaths
            allPaths.append("manifest.json")
            let provenance = PhylogeneticTreeProvenance(
                toolName: options.toolName,
                toolVersion: options.toolVersion,
                createdAt: started,
                argv: options.argv ?? defaultArgv(sourceURL: sourceURL, destinationURL: destinationURL),
                durableReplayArgv: options.argv ?? defaultArgv(sourceURL: sourceURL, destinationURL: destinationURL),
                command: options.command ?? shellCommand(defaultArgv(sourceURL: sourceURL, destinationURL: destinationURL)),
                options: [
                    "sourceFormat": options.sourceFormat ?? "auto",
                    "primaryTree": "first",
                    "normalizeComments": "true",
                    "writeSQLiteIndex": "true"
                ],
                runtime: .current,
                input: try provenanceFile(path: sourceURL.path, url: sourceURL),
                output: PhylogeneticTreeProvenance.FileRecord(
                    path: destinationURL.path,
                    sha256: bundleDigest(checksums: try checksumMap(paths: allPaths, bundleURL: destinationURL)),
                    fileSizeBytes: try directorySize(at: destinationURL)
                ),
                checksums: try checksumMap(paths: allPaths, bundleURL: destinationURL),
                fileSizes: try fileSizeMap(paths: allPaths, bundleURL: destinationURL),
                exitStatus: 0,
                wallTimeSeconds: Date().timeIntervalSince(started),
                warnings: warnings,
                stderr: nil
            )
            try encoder.encode(provenance).write(
                to: destinationURL.appendingPathComponent(".lungfish-provenance.json"),
                options: .atomic
            )

            return PhylogeneticTreeBundle(url: destinationURL, manifest: manifest, normalizedTree: normalized)
        } catch {
            try? fm.removeItem(at: destinationURL)
            throw error
        }
    }

    public static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func defaultArgv(sourceURL: URL, destinationURL: URL) -> [String] {
        [CLICommandIdentity.executableName, "import", "tree", sourceURL.path, "--output", destinationURL.path]
    }

    private static func shellCommand(_ argv: [String]) -> String {
        argv.map(shellEscaped).joined(separator: " ")
    }

    private static func shellEscaped(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=/:.,")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func checksumMap(paths: [String], bundleURL: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in paths {
            let url = bundleURL.appendingPathComponent(path)
            result[path] = sha256Hex(for: try Data(contentsOf: url))
        }
        return result
    }

    private static func fileSizeMap(paths: [String], bundleURL: URL) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        for path in paths {
            result[path] = try fileSize(at: bundleURL.appendingPathComponent(path))
        }
        return result
    }

    private static func provenanceFile(path: String, url: URL) throws -> PhylogeneticTreeProvenance.FileRecord {
        try PhylogeneticTreeProvenance.FileRecord(
            path: path,
            sha256: sha256Hex(for: Data(contentsOf: url)),
            fileSizeBytes: fileSize(at: url)
        )
    }

    private static func fileSize(at url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func directorySize(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private static func bundleDigest(checksums: [String: String]) -> String {
        let joined = checksums.keys.sorted().map { "\($0)=\(checksums[$0] ?? "")" }.joined(separator: "\n")
        return sha256Hex(for: Data(joined.utf8))
    }
}

private struct PhylogeneticTreeViewState: Codable, Sendable {
    let layout: String
    let zoom: Double
    let panX: Double
    let panY: Double
    let selectedNodeID: String?
    let collapsedNodeIDs: [String]
    let colorMode: String
    let visibleMetadataColumns: [String]

    init() {
        self.layout = "rectangular-phylogram"
        self.zoom = 1
        self.panX = 0
        self.panY = 0
        self.selectedNodeID = nil
        self.collapsedNodeIDs = []
        self.colorMode = "none"
        self.visibleMetadataColumns = []
    }
}
