import CryptoKit
import Foundation
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
}

public enum PhylogeneticTreeBundleError: Error, LocalizedError, Sendable, Equatable {
    case sourceMissing(String)
    case destinationAlreadyExists(String)
    case unsupportedFormat(String)
    case parseFailed(String)
    case missingBundleFile(String)
    case sqliteIndexFailed(String)
    case nodeNotFound(String)
    case ambiguousNodeLabel(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            return "Tree source file does not exist: \(path)"
        case .destinationAlreadyExists(let path):
            return "Tree bundle destination already exists: \(path)"
        case .unsupportedFormat(let format):
            return "Unsupported phylogenetic tree format: \(format)"
        case .parseFailed(let message):
            return "Could not parse phylogenetic tree: \(message)"
        case .missingBundleFile(let path):
            return "Tree bundle is missing required file: \(path)"
        case .sqliteIndexFailed(let message):
            return "Could not write tree index: \(message)"
        case .nodeNotFound(let selector):
            return "Tree node not found: \(selector)"
        case .ambiguousNodeLabel(let label):
            return "Tree node label is ambiguous: \(label)"
        }
    }
}

public struct PhylogeneticTreeSubtreeExport: Sendable, Equatable {
    public let selectedNodeID: String
    public let selectedLabel: String
    public let newick: String
    public let descendantTipCount: Int
}

public struct PhylogeneticTreeManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let bundleKind: String
    public let identifier: String
    public let name: String
    public let createdAt: Date
    public let sourceFormat: String
    public let sourceFileName: String
    public let treeCount: Int
    public let primaryTreeID: String
    public let isRooted: Bool
    public let tipCount: Int
    public let internalNodeCount: Int
    public let branchLengthUnit: String?
    public let dateScale: String?
    public let warnings: [String]
    public let capabilities: [String]
    public let checksums: [String: String]
    public let fileSizes: [String: Int64]
}

public struct PhylogeneticTreeNormalizedTree: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let treeID: String
    public let rooted: Bool
    public let nodes: [PhylogeneticTreeNormalizedNode]
}

public struct PhylogeneticTreeNormalizedNode: Codable, Sendable, Equatable {
    public let id: String
    public let rawLabel: String?
    public let displayLabel: String
    public let parentID: String?
    public let childIDs: [String]
    public let isTip: Bool
    public let branchLength: Double?
    public let cumulativeDivergence: Double?
    public let metadata: [String: String]
    public let support: PhylogeneticTreeSupport?
    public let descendantTipCount: Int
}

public struct PhylogeneticTreeSupport: Codable, Sendable, Equatable {
    public let rawValue: String
    public let interpretation: String
}

public struct PhylogeneticTreeImportOptions: Sendable, Equatable {
    public let name: String?
    public let argv: [String]?
    public let command: String?
    public let sourceFormat: String?
    public let toolName: String
    public let toolVersion: String

    public init(
        name: String? = nil,
        argv: [String]? = nil,
        command: String? = nil,
        sourceFormat: String? = nil,
        toolName: String = "lungfish import tree",
        toolVersion: String = PhylogeneticTreeBundleImporter.toolVersion
    ) {
        self.name = name
        self.argv = argv
        self.command = command
        self.sourceFormat = sourceFormat
        self.toolName = toolName
        self.toolVersion = toolVersion
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
                argv: options.argv ?? defaultArgv(sourceURL: sourceURL, destinationURL: destinationURL),
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
        ["lungfish", "import", "tree", sourceURL.path, "--output", destinationURL.path]
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

public struct PhylogeneticTreeProvenance: Codable, Sendable, Equatable {
    public struct RuntimeIdentity: Codable, Sendable, Equatable {
        public let operatingSystem: String
        public let swiftRuntime: String
        public let condaEnvironment: String?
        public let containerImage: String?

        public static var current: RuntimeIdentity {
            RuntimeIdentity(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                swiftRuntime: "swift",
                condaEnvironment: ProcessInfo.processInfo.environment["CONDA_DEFAULT_ENV"],
                containerImage: nil
            )
        }
    }

    public struct FileRecord: Codable, Sendable, Equatable {
        public let path: String
        public let sha256: String
        public let fileSizeBytes: Int64
    }

    public let toolName: String
    public let toolVersion: String
    public let argv: [String]
    public let command: String
    public let options: [String: String]
    public let runtime: RuntimeIdentity
    public let input: FileRecord
    public let output: FileRecord
    public let checksums: [String: String]
    public let fileSizes: [String: Int64]
    public let exitStatus: Int
    public let wallTimeSeconds: TimeInterval
    public let warnings: [String]
    public let stderr: String?
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

private final class ParsedTreeNode {
    var rawLabel: String?
    var displayLabel: String
    var branchLength: Double?
    var metadata: [String: String]
    var children: [ParsedTreeNode]

    init(
        rawLabel: String? = nil,
        displayLabel: String = "",
        branchLength: Double? = nil,
        metadata: [String: String] = [:],
        children: [ParsedTreeNode] = []
    ) {
        self.rawLabel = rawLabel
        self.displayLabel = displayLabel
        self.branchLength = branchLength
        self.metadata = metadata
        self.children = children
    }
}

private struct ParsedTree {
    let tree: ParsedTreeNode
    let sourceFormat: String
    let treeCount: Int
    let isRooted: Bool
}

private enum TreeInputParser {
    static func parse(text: String, sourceURL: URL, requestedFormat: String?) throws -> ParsedTree {
        let format = try resolvedFormat(text: text, sourceURL: sourceURL, requestedFormat: requestedFormat)
        switch format {
        case "newick":
            let parser = NewickParser(text: text, translations: [:])
            let root = try parser.parse()
            return ParsedTree(tree: root, sourceFormat: "newick", treeCount: 1, isRooted: parser.isRooted(root: root))
        case "nexus":
            let nexus = try NexusTreeBlockParser.parse(text: text)
            let parser = NewickParser(text: nexus.newick, translations: nexus.translations)
            let root = try parser.parse()
            let rooted = parser.explicitRooted ?? nexus.explicitRooted ?? parser.isRooted(root: root)
            return ParsedTree(tree: root, sourceFormat: "nexus", treeCount: nexus.treeCount, isRooted: rooted)
        default:
            throw PhylogeneticTreeBundleError.unsupportedFormat(format)
        }
    }

    private static func resolvedFormat(text: String, sourceURL: URL, requestedFormat: String?) throws -> String {
        if let requestedFormat {
            let lower = requestedFormat.lowercased()
            if lower == "newick" || lower == "nexus" {
                return lower
            }
            throw PhylogeneticTreeBundleError.unsupportedFormat(requestedFormat)
        }
        let ext = sourceURL.pathExtension.lowercased()
        if ["nwk", "newick", "tree", "tre", "treefile", "contree"].contains(ext) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("#nexus")
                ? "nexus" : "newick"
        }
        if ["nex", "nexus"].contains(ext) {
            return "nexus"
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("#nexus") {
            return "nexus"
        }
        return "newick"
    }
}

private struct NexusTreeBlockParser {
    let translations: [String: String]
    let newick: String
    let treeCount: Int
    let explicitRooted: Bool?

    static func parse(text: String) throws -> NexusTreeBlockParser {
        guard let block = treeBlock(in: text) else {
            throw PhylogeneticTreeBundleError.parseFailed("NEXUS file does not contain a trees block.")
        }
        let translations = parseTranslations(in: block)
        let treeStatements = treeStatementPayloads(in: block)
        guard let first = treeStatements.first else {
            throw PhylogeneticTreeBundleError.parseFailed("NEXUS trees block does not contain a tree statement.")
        }
        return NexusTreeBlockParser(
            translations: translations,
            newick: first.newick,
            treeCount: treeStatements.count,
            explicitRooted: first.rooted
        )
    }

    private static func treeBlock(in text: String) -> String? {
        let lower = text.lowercased()
        guard let beginRange = lower.range(of: "begin trees;") ?? lower.range(of: "begin trees") else {
            return nil
        }
        guard let endRange = lower[beginRange.upperBound...].range(of: "end;")
            ?? lower[beginRange.upperBound...].range(of: "end") else {
            return nil
        }
        return String(text[beginRange.upperBound..<endRange.lowerBound])
    }

    private static func parseTranslations(in block: String) -> [String: String] {
        let lower = block.lowercased()
        guard let translateRange = lower.range(of: "translate") else { return [:] }
        guard let semicolon = block[translateRange.upperBound...].firstIndex(of: ";") else { return [:] }
        let body = block[translateRange.upperBound..<semicolon]
        var result: [String: String] = [:]
        for entry in body.split(separator: ",") {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = unquote(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    private static func treeStatementPayloads(in block: String) -> [(newick: String, rooted: Bool?)] {
        var results: [(String, Bool?)] = []
        let scanner = NewickTextScanner(text: block)
        while !scanner.isAtEnd {
            scanner.skipWhitespace()
            guard scanner.consumeKeyword("tree") || scanner.consumeKeyword("utree") else {
                scanner.advance()
                continue
            }
            guard scanner.consumeUntil("=") else { continue }
            scanner.skipWhitespace()
            var rooted: Bool?
            if scanner.peekCommentPrefix() {
                let comment = scanner.readComment() ?? ""
                let lower = comment.lowercased()
                if lower == "&r" { rooted = true }
                if lower == "&u" { rooted = false }
            }
            let newick = scanner.readBalancedNewickStatement()
            if !newick.isEmpty {
                results.append((newick, rooted))
            }
        }
        return results
    }

    private static func unquote(_ value: String) -> String {
        var value = value
        if value.hasSuffix(";") { value.removeLast() }
        if value.count >= 2, value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

private final class NewickParser {
    private let scanner: NewickTextScanner
    private let translations: [String: String]
    private(set) var explicitRooted: Bool?

    init(text: String, translations: [String: String]) {
        self.scanner = NewickTextScanner(text: text)
        self.translations = translations
    }

    func parse() throws -> ParsedTreeNode {
        scanner.skipWhitespace()
        if scanner.peekCommentPrefix(), let comment = scanner.readComment() {
            if comment.lowercased() == "&r" { explicitRooted = true }
            if comment.lowercased() == "&u" { explicitRooted = false }
        }
        let root = try parseSubtree()
        scanner.skipWhitespace()
        guard scanner.consume(";") else {
            throw PhylogeneticTreeBundleError.parseFailed("Expected ';' at end of Newick tree.")
        }
        scanner.skipWhitespace()
        if !scanner.isAtEnd {
            throw PhylogeneticTreeBundleError.parseFailed("Unexpected content after Newick terminator.")
        }
        return root
    }

    func isRooted(root: ParsedTreeNode) -> Bool {
        explicitRooted ?? (root.children.count == 2)
    }

    private func parseSubtree() throws -> ParsedTreeNode {
        scanner.skipWhitespace()
        if scanner.consume("(") {
            var children: [ParsedTreeNode] = []
            repeat {
                children.append(try parseSubtree())
                scanner.skipWhitespace()
            } while scanner.consume(",")
            guard scanner.consume(")") else {
                throw PhylogeneticTreeBundleError.parseFailed("Expected ')' to close child list.")
            }
            let parsed = try parseNodeSuffix(allowsEmptyLabel: true)
            parsed.children = children
            return parsed
        }

        let parsed = try parseNodeSuffix(allowsEmptyLabel: false)
        guard !parsed.displayLabel.isEmpty else {
            throw PhylogeneticTreeBundleError.parseFailed("Tip node is missing a label.")
        }
        return parsed
    }

    private func parseNodeSuffix(allowsEmptyLabel: Bool) throws -> ParsedTreeNode {
        var metadata: [String: String] = [:]
        scanner.skipWhitespace()
        while scanner.peekCommentPrefix(), let comment = scanner.readComment() {
            metadata.merge(parseMetadataComment(comment)) { _, new in new }
            scanner.skipWhitespace()
        }

        let label = scanner.readLabel()
        scanner.skipWhitespace()
        while scanner.peekCommentPrefix(), let comment = scanner.readComment() {
            metadata.merge(parseMetadataComment(comment)) { _, new in new }
            scanner.skipWhitespace()
        }

        var length: Double?
        if scanner.consume(":") {
            let token = scanner.readLengthToken()
            guard let parsedLength = Double(token) else {
                throw PhylogeneticTreeBundleError.parseFailed("Invalid branch length '\(token)'.")
            }
            length = parsedLength
        }

        let rawLabel = label.isEmpty ? nil : label
        let display = rawLabel.flatMap { translations[$0] } ?? rawLabel ?? ""
        if !allowsEmptyLabel && display.isEmpty {
            throw PhylogeneticTreeBundleError.parseFailed("Tip node is missing a label.")
        }
        return ParsedTreeNode(
            rawLabel: rawLabel,
            displayLabel: display,
            branchLength: length,
            metadata: metadata
        )
    }

    private func parseMetadataComment(_ comment: String) -> [String: String] {
        var body = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("&") {
            body.removeFirst()
        }
        if body.lowercased() == "r" {
            explicitRooted = true
            return [:]
        }
        if body.lowercased() == "u" {
            explicitRooted = false
            return [:]
        }

        var result: [String: String] = [:]
        for part in splitMetadataList(body) {
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            result[pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)] = unquote(
                pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    private func splitMetadataList(_ body: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for ch in body {
            if ch == "\"" || ch == "'" {
                if quote == ch {
                    quote = nil
                } else if quote == nil {
                    quote = ch
                }
            }
            if ch == ",", quote == nil {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private func unquote(_ value: String) -> String {
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            return String(value.dropFirst().dropLast())
        }
        if value.count >= 2, value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }
}

private final class NewickTextScanner {
    private let chars: [Character]
    private var index: Int = 0

    init(text: String) {
        self.chars = Array(text)
    }

    var isAtEnd: Bool { index >= chars.count }

    func advance() {
        if !isAtEnd { index += 1 }
    }

    func skipWhitespace() {
        while !isAtEnd, chars[index].isWhitespace {
            index += 1
        }
    }

    func consume(_ literal: Character) -> Bool {
        skipWhitespace()
        guard !isAtEnd, chars[index] == literal else { return false }
        index += 1
        return true
    }

    func consumeKeyword(_ keyword: String) -> Bool {
        skipWhitespace()
        let end = index + keyword.count
        guard end <= chars.count else { return false }
        let candidate = String(chars[index..<end]).lowercased()
        guard candidate == keyword.lowercased() else { return false }
        if end < chars.count, isLabelCharacter(chars[end]) {
            return false
        }
        index = end
        return true
    }

    func consumeUntil(_ literal: Character) -> Bool {
        while !isAtEnd {
            if chars[index] == literal {
                index += 1
                return true
            }
            index += 1
        }
        return false
    }

    func peekCommentPrefix() -> Bool {
        skipWhitespace()
        return !isAtEnd && chars[index] == "["
    }

    func readComment() -> String? {
        skipWhitespace()
        guard !isAtEnd, chars[index] == "[" else { return nil }
        index += 1
        var depth = 1
        var result = ""
        while !isAtEnd {
            let ch = chars[index]
            index += 1
            if ch == "[" {
                depth += 1
            } else if ch == "]" {
                depth -= 1
                if depth == 0 {
                    return result
                }
            }
            if depth > 0 {
                result.append(ch)
            }
        }
        return nil
    }

    func readLabel() -> String {
        skipWhitespace()
        guard !isAtEnd else { return "" }
        if chars[index] == "'" {
            index += 1
            var result = ""
            while !isAtEnd {
                let ch = chars[index]
                index += 1
                if ch == "'" {
                    if !isAtEnd, chars[index] == "'" {
                        result.append("'")
                        index += 1
                        continue
                    }
                    break
                }
                result.append(ch)
            }
            return result
        }

        var result = ""
        while !isAtEnd, isLabelCharacter(chars[index]) {
            result.append(chars[index])
            index += 1
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func readLengthToken() -> String {
        skipWhitespace()
        var result = ""
        while !isAtEnd {
            let ch = chars[index]
            if ch == "," || ch == ")" || ch == ";" || ch == "[" || ch.isWhitespace {
                break
            }
            result.append(ch)
            index += 1
        }
        return result
    }

    func readBalancedNewickStatement() -> String {
        skipWhitespace()
        var result = ""
        var depth = 0
        var inSingleQuote = false
        var commentDepth = 0
        while !isAtEnd {
            let ch = chars[index]
            index += 1
            result.append(ch)
            if commentDepth > 0 {
                if ch == "[" { commentDepth += 1 }
                if ch == "]" { commentDepth -= 1 }
                continue
            }
            if ch == "'", !inSingleQuote {
                inSingleQuote = true
                continue
            } else if ch == "'", inSingleQuote {
                if !isAtEnd, chars[index] == "'" {
                    result.append(chars[index])
                    index += 1
                    continue
                }
                inSingleQuote = false
                continue
            }
            if inSingleQuote { continue }
            if ch == "[" { commentDepth = 1 }
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if ch == ";", depth == 0 {
                break
            }
        }
        return result
    }

    private func isLabelCharacter(_ ch: Character) -> Bool {
        !(ch == ":" || ch == "," || ch == ")" || ch == "(" || ch == ";" || ch == "[" || ch == "]")
            && !ch.isWhitespace
    }
}

private enum TreeNormalizer {
    static func normalizedTree(from root: ParsedTreeNode, rooted: Bool) -> PhylogeneticTreeNormalizedTree {
        var nodes: [PartialNode] = []
        _ = collect(
            node: root,
            parentID: nil,
            path: "root",
            cumulativeDivergence: 0,
            nodes: &nodes
        )
        let finalNodes = nodes.map { partial in
            PhylogeneticTreeNormalizedNode(
                id: partial.id,
                rawLabel: partial.rawLabel,
                displayLabel: partial.displayLabel,
                parentID: partial.parentID,
                childIDs: partial.childIDs,
                isTip: partial.isTip,
                branchLength: partial.branchLength,
                cumulativeDivergence: partial.cumulativeDivergence,
                metadata: partial.metadata,
                support: partial.support,
                descendantTipCount: partial.descendantTipCount
            )
        }
        return PhylogeneticTreeNormalizedTree(schemaVersion: 1, treeID: "tree-1", rooted: rooted, nodes: finalNodes)
    }

    private static func collect(
        node: ParsedTreeNode,
        parentID: String?,
        path: String,
        cumulativeDivergence: Double,
        nodes: inout [PartialNode]
    ) -> (id: String, descendantTipCount: Int) {
        let id = stableID(path: path, node: node)
        var childIDs: [String] = []
        var descendantTipCount = node.children.isEmpty ? 1 : 0
        let nodeDivergence = cumulativeDivergence + (node.branchLength ?? 0)
        for (idx, child) in node.children.enumerated() {
            let childResult = collect(
                node: child,
                parentID: id,
                path: "\(path).\(idx)",
                cumulativeDivergence: nodeDivergence,
                nodes: &nodes
            )
            childIDs.append(childResult.id)
            descendantTipCount += childResult.descendantTipCount
        }

        let support = supportValue(for: node)
        nodes.insert(
            PartialNode(
                id: id,
                rawLabel: node.rawLabel,
                displayLabel: node.displayLabel.isEmpty ? "Internal node" : node.displayLabel,
                parentID: parentID,
                childIDs: childIDs,
                isTip: node.children.isEmpty,
                branchLength: node.branchLength,
                cumulativeDivergence: parentID == nil ? 0 : nodeDivergence,
                metadata: node.metadata,
                support: support,
                descendantTipCount: descendantTipCount
            ),
            at: 0
        )
        return (id, descendantTipCount)
    }

    private static func stableID(path: String, node: ParsedTreeNode) -> String {
        let content = "\(path)|\(node.rawLabel ?? "")|\(node.displayLabel)|\(node.children.count)"
        let digest = PhylogeneticTreeBundleImporter.sha256Hex(for: Data(content.utf8))
        return "node-\(digest.prefix(16))"
    }

    private static func supportValue(for node: ParsedTreeNode) -> PhylogeneticTreeSupport? {
        if let posterior = node.metadata["posterior"] {
            return PhylogeneticTreeSupport(rawValue: posterior, interpretation: "posterior")
        }
        guard !node.children.isEmpty, let raw = node.rawLabel else { return nil }
        guard let value = Double(raw) else {
            return PhylogeneticTreeSupport(rawValue: raw, interpretation: "unknown")
        }
        if value >= 0, value <= 1 {
            return PhylogeneticTreeSupport(rawValue: raw, interpretation: "posterior")
        }
        if value > 1, value <= 100 {
            return PhylogeneticTreeSupport(rawValue: raw, interpretation: "bootstrap")
        }
        return PhylogeneticTreeSupport(rawValue: raw, interpretation: "unknown")
    }

    private struct PartialNode {
        let id: String
        let rawLabel: String?
        let displayLabel: String
        let parentID: String?
        let childIDs: [String]
        let isTip: Bool
        let branchLength: Double?
        let cumulativeDivergence: Double?
        let metadata: [String: String]
        let support: PhylogeneticTreeSupport?
        let descendantTipCount: Int
    }
}

private enum TreeWarningCollector {
    static func warnings(for tree: PhylogeneticTreeNormalizedTree) -> [String] {
        var warnings: [String] = []
        let nonRootNodes = tree.nodes.filter { $0.parentID != nil }
        if nonRootNodes.contains(where: { $0.branchLength == nil }) {
            warnings.append("Tree contains one or more edges without branch lengths.")
        }
        if nonRootNodes.contains(where: { ($0.branchLength ?? 0) < 0 }) {
            warnings.append("Tree contains one or more negative branch lengths.")
        }
        for node in tree.nodes where !node.isTip {
            if let support = node.support {
                if support.interpretation == "posterior", node.rawLabel == support.rawValue {
                    warnings.append("Internal support value '\(support.rawValue)' was interpreted as posterior probability.")
                } else if support.interpretation == "unknown" {
                    warnings.append("Internal support value '\(support.rawValue)' has unknown interpretation.")
                }
            }
        }
        return Array(NSOrderedSet(array: warnings)) as? [String] ?? warnings
    }
}

private enum NewickWriter {
    static func write(_ root: ParsedTreeNode) -> String {
        writeNode(root) + ";"
    }

    private static func writeNode(_ node: ParsedTreeNode) -> String {
        var result = ""
        if !node.children.isEmpty {
            result += "(" + node.children.map(writeNode).joined(separator: ",") + ")"
        }
        if !node.displayLabel.isEmpty {
            result += escapedLabel(node.displayLabel)
        } else if let rawLabel = node.rawLabel {
            result += escapedLabel(rawLabel)
        }
        if let branchLength = node.branchLength {
            result += ":\(branchLength)"
        }
        return result
    }

    private static func escapedLabel(_ label: String) -> String {
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        if label.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return label
        }
        return "'" + label.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

private struct PhylogeneticTreeSubtreeExporter {
    let bundle: PhylogeneticTreeBundle
    let nodesByID: [String: PhylogeneticTreeNormalizedNode]

    init(bundle: PhylogeneticTreeBundle) {
        self.bundle = bundle
        self.nodesByID = Dictionary(uniqueKeysWithValues: bundle.normalizedTree.nodes.map { ($0.id, $0) })
    }

    func export(nodeID: String) throws -> PhylogeneticTreeSubtreeExport {
        let trimmed = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let node = nodesByID[trimmed] else {
            throw PhylogeneticTreeBundleError.nodeNotFound("node \(nodeID)")
        }
        return try export(node: node)
    }

    func export(label: String) throws -> PhylogeneticTreeSubtreeExport {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = bundle.normalizedTree.nodes.filter { node in
            node.displayLabel == trimmed || node.rawLabel == trimmed
        }
        guard matches.isEmpty == false else {
            throw PhylogeneticTreeBundleError.nodeNotFound("label \(label)")
        }
        guard matches.count == 1, let node = matches.first else {
            throw PhylogeneticTreeBundleError.ambiguousNodeLabel(label)
        }
        return try export(node: node)
    }

    private func export(node: PhylogeneticTreeNormalizedNode) throws -> PhylogeneticTreeSubtreeExport {
        PhylogeneticTreeSubtreeExport(
            selectedNodeID: node.id,
            selectedLabel: nodeLabel(for: node) ?? node.displayLabel,
            newick: try writeNode(node) + ";",
            descendantTipCount: node.descendantTipCount
        )
    }

    private func writeNode(_ node: PhylogeneticTreeNormalizedNode) throws -> String {
        var result = ""
        if node.childIDs.isEmpty == false {
            let children = try node.childIDs.map { childID in
                guard let child = nodesByID[childID] else {
                    throw PhylogeneticTreeBundleError.parseFailed("Normalized tree references missing child node \(childID).")
                }
                return try writeNode(child)
            }
            result += "(" + children.joined(separator: ",") + ")"
        }
        if let label = nodeLabel(for: node), label.isEmpty == false {
            result += escapedLabel(label)
        }
        if let branchLength = node.branchLength {
            result += ":\(branchLength)"
        }
        return result
    }

    private func nodeLabel(for node: PhylogeneticTreeNormalizedNode) -> String? {
        if node.isTip {
            return node.displayLabel
        }
        if node.rawLabel != nil {
            return node.displayLabel
        }
        if node.displayLabel != "Internal node" {
            return node.displayLabel
        }
        return nil
    }

    private func escapedLabel(_ label: String) -> String {
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        if label.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return label
        }
        return "'" + label.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

private enum TreeIndexWriter {
    static func write(normalizedTree: PhylogeneticTreeNormalizedTree, to url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            if let db { sqlite3_close(db) }
            throw PhylogeneticTreeBundleError.sqliteIndexFailed(message)
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE nodes (
          id TEXT PRIMARY KEY,
          parent_id TEXT,
          raw_label TEXT,
          display_label TEXT NOT NULL,
          is_tip INTEGER NOT NULL,
          branch_length REAL,
          cumulative_divergence REAL,
          descendant_tip_count INTEGER NOT NULL,
          metadata_json TEXT NOT NULL,
          support_raw TEXT,
          support_interpretation TEXT
        );
        CREATE INDEX nodes_parent_idx ON nodes(parent_id);
        CREATE INDEX nodes_tip_idx ON nodes(is_tip, display_label);
        """
        try exec(schema, db: db)
        try exec("BEGIN TRANSACTION", db: db)
        do {
            try exec(
                "INSERT INTO metadata(key, value) VALUES ('schemaVersion', '1'), ('treeID', '\(normalizedTree.treeID)')",
                db: db
            )
            let insertSQL = """
            INSERT INTO nodes(
              id, parent_id, raw_label, display_label, is_tip, branch_length,
              cumulative_divergence, descendant_tip_count, metadata_json,
              support_raw, support_interpretation
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw PhylogeneticTreeBundleError.sqliteIndexFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for node in normalizedTree.nodes {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, node.id)
                bindOptionalText(stmt, 2, node.parentID)
                bindOptionalText(stmt, 3, node.rawLabel)
                bindText(stmt, 4, node.displayLabel)
                sqlite3_bind_int(stmt, 5, node.isTip ? 1 : 0)
                bindOptionalDouble(stmt, 6, node.branchLength)
                bindOptionalDouble(stmt, 7, node.cumulativeDivergence)
                sqlite3_bind_int64(stmt, 8, Int64(node.descendantTipCount))
                let metadataJSON = String(data: try encoder.encode(node.metadata), encoding: .utf8) ?? "{}"
                bindText(stmt, 9, metadataJSON)
                bindOptionalText(stmt, 10, node.support?.rawValue)
                bindOptionalText(stmt, 11, node.support?.interpretation)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw PhylogeneticTreeBundleError.sqliteIndexFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
            try exec("COMMIT", db: db)
        } catch {
            try? exec("ROLLBACK", db: db)
            throw error
        }
    }

    private static func exec(_ sql: String, db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let error { sqlite3_free(error) }
            throw PhylogeneticTreeBundleError.sqliteIndexFailed(message)
        }
    }

    private static func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    private static func bindOptionalText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func bindOptionalDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
