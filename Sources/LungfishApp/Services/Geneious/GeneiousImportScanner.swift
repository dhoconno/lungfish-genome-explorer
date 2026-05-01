import Foundation
import LungfishIO
import LungfishWorkflow

public struct GeneiousImportScanner: Sendable {
    private let archiveTool: GeneiousArchiveTool

    public init(archiveTool: GeneiousArchiveTool = GeneiousArchiveTool()) {
        self.archiveTool = archiveTool
    }

    private var fileManager: FileManager { .default }

    public func scan(sourceURL: URL) async throws -> GeneiousImportInventory {
        let sourceKind = try sourceKind(for: sourceURL)
        var warnings: [String] = []
        let scanRoot: URL
        let cleanupRoot: URL?

        switch sourceKind {
        case .geneiousArchive:
            let tempRoot = fileManager.temporaryDirectory
                .appendingPathComponent("geneious-scan-\(UUID().uuidString)", isDirectory: true)
            try archiveTool.extract(archiveURL: sourceURL, to: tempRoot)
            scanRoot = tempRoot
            cleanupRoot = tempRoot
        case .folder:
            scanRoot = sourceURL
            cleanupRoot = nil
        case .file:
            scanRoot = sourceURL
            cleanupRoot = nil
        }

        defer {
            if let cleanupRoot {
                try? fileManager.removeItem(at: cleanupRoot)
            }
        }

        let items = try scanItems(rootURL: scanRoot, sourceKind: sourceKind)
        let xmlMetadata = items.compactMap(\.geneiousMetadata)
        let geneiousVersion = xmlMetadata.compactMap(\.version).first
        let geneiousMinimumVersion = xmlMetadata.compactMap(\.minimumVersion).first
        let documentClasses = uniqueSorted(xmlMetadata.flatMap(\.documentClasses))
        let unresolvedURNs = uniqueSorted(xmlMetadata.flatMap(\.unresolvedURNs))
        if sourceKind == .geneiousArchive && items.isEmpty {
            warnings.append("The Geneious archive did not contain any importable file entries.")
        }

        return GeneiousImportInventory(
            sourceURL: sourceURL,
            sourceKind: sourceKind,
            sourceName: sourceURL.lastPathComponent,
            geneiousVersion: geneiousVersion,
            geneiousMinimumVersion: geneiousMinimumVersion,
            items: items.map(\.item),
            documentClasses: documentClasses,
            unresolvedURNs: unresolvedURNs,
            warnings: warnings
        )
    }

    private func sourceKind(for sourceURL: URL) throws -> GeneiousImportSourceKind {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if isDirectory.boolValue {
            return .folder
        }
        if sourceURL.pathExtension.lowercased() == "geneious" {
            return .geneiousArchive
        }
        return .file
    }

    private func scanItems(rootURL: URL, sourceKind: GeneiousImportSourceKind) throws -> [ScannedItem] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
            return []
        }

        if !isDirectory.boolValue {
            let relativePath = rootURL.lastPathComponent
            return [try scanFile(url: rootURL, relativePath: relativePath, sourceKind: sourceKind)]
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isHiddenKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var scanned: [ScannedItem] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            if values.isHidden == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let relativePath = Self.relativePath(from: rootURL, to: fileURL)
            scanned.append(try scanFile(url: fileURL, relativePath: relativePath, sourceKind: sourceKind))
        }

        return scanned.sorted { $0.item.sourceRelativePath.localizedStandardCompare($1.item.sourceRelativePath) == .orderedAscending }
    }

    private func scanFile(url: URL, relativePath: String, sourceKind: GeneiousImportSourceKind) throws -> ScannedItem {
        let metadata = parseGeneiousXMLMetadataIfPresent(url: url)
        let kind = classify(url: url, relativePath: relativePath, xmlMetadata: metadata)
        let sizeBytes = Self.fileSizeBytes(url: url)
        let sha256 = ProvenanceRecorder.sha256(of: url)
        let documentName = metadata?.cacheName ?? metadata?.overrideCacheName

        let item = GeneiousImportItem(
            sourceRelativePath: relativePath,
            stagedRelativePath: sourceKind == .geneiousArchive ? relativePath : nil,
            kind: kind,
            sizeBytes: sizeBytes,
            sha256: sha256,
            geneiousDocumentClass: metadata?.documentClasses.first,
            geneiousDocumentName: documentName,
            warnings: warnings(for: kind)
        )
        return ScannedItem(item: item, geneiousMetadata: metadata)
    }

    private func classify(url: URL, relativePath: String, xmlMetadata: GeneiousXMLMetadata?) -> GeneiousImportItemKind {
        if Self.isGeneiousSidecar(relativePath) {
            return .geneiousSidecar
        }
        if xmlMetadata != nil {
            return .geneiousXML
        }
        if FASTQBundle.isFASTQFileURL(url) {
            return .fastq
        }

        switch ReferenceBundleImportService.classify(url) {
        case .standaloneReferenceSequence:
            return .standaloneReferenceSequence
        case .annotationTrack:
            return .annotationTrack
        case .variantTrack:
            return .variantTrack
        case .alignmentTrack:
            return .alignmentTrack
        case .unsupported:
            break
        }

        let normalizedExtension = ReferenceBundleImportService.normalizedExtension(for: url)
        if Self.treeOrAlignmentExtensions.contains(normalizedExtension) {
            return .treeOrAlignment
        }
        if Self.signalTrackExtensions.contains(normalizedExtension) {
            return .signalTrack
        }
        if Self.reportExtensions.contains(normalizedExtension) {
            return .report
        }
        return .unsupported
    }

    private func parseGeneiousXMLMetadataIfPresent(url: URL) -> GeneiousXMLMetadata? {
        let ext = url.pathExtension.lowercased()
        guard ext == "geneious" || ext == "xml" else { return nil }
        guard let data = try? Data(contentsOf: url), data.count <= Self.maximumXMLBytes else {
            return nil
        }
        guard let prefix = String(data: data.prefix(4096), encoding: .utf8),
              prefix.localizedCaseInsensitiveContains("<geneious") else {
            return nil
        }

        let parser = XMLParser(data: data)
        let delegate = GeneiousXMLMetadataParser()
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.metadata
    }

    private func warnings(for kind: GeneiousImportItemKind) -> [String] {
        switch kind {
        case .geneiousXML, .geneiousSidecar:
            return ["Native Geneious data is preserved but not decoded in the no-Geneious baseline."]
        default:
            return []
        }
    }

    private static func relativePath(from rootURL: URL, to fileURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(prefix.count))
    }

    private static func isGeneiousSidecar(_ relativePath: String) -> Bool {
        let name = URL(fileURLWithPath: relativePath).lastPathComponent
        guard name.hasPrefix("fileData.") else { return false }
        return name.dropFirst("fileData.".count).allSatisfy(\.isNumber)
    }

    private static func fileSizeBytes(url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.size] else {
            return nil
        }
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        return value as? UInt64
    }

    private func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static let maximumXMLBytes = 16 * 1024 * 1024
    private static let treeOrAlignmentExtensions: Set<String> = [
        "aln", "clustal", "maf", "msf", "nex", "nexus", "newick", "nwk", "phy", "phylip", "sto", "stockholm", "tree", "tre",
    ]
    private static let signalTrackExtensions: Set<String> = ["bigwig", "bw", "tdf", "wig", "wiggle"]
    private static let reportExtensions: Set<String> = ["csv", "html", "htm", "log", "md", "pdf", "tsv", "txt"]
}

private struct ScannedItem {
    let item: GeneiousImportItem
    let geneiousMetadata: GeneiousXMLMetadata?
}

private struct GeneiousXMLMetadata: Equatable {
    var version: String?
    var minimumVersion: String?
    var documentClasses: [String] = []
    var cacheName: String?
    var overrideCacheName: String?
    var unresolvedURNs: [String] = []
}

private final class GeneiousXMLMetadataParser: NSObject, XMLParserDelegate {
    private(set) var metadata = GeneiousXMLMetadata()
    private var activeHiddenFieldName: String?
    private var activeHiddenFieldText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "geneious":
            metadata.version = attributeDict["version"] ?? metadata.version
            metadata.minimumVersion = attributeDict["minimumVersion"] ?? metadata.minimumVersion
        case "geneiousDocument":
            appendUnique(attributeDict["class"], to: &metadata.documentClasses)
        case "excludedDocument":
            if let value = attributeDict["class"], value.hasPrefix("urn:") {
                appendUnique(value, to: &metadata.unresolvedURNs)
            }
        case "hiddenField":
            activeHiddenFieldName = attributeDict["name"]
            activeHiddenFieldText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeHiddenFieldName != nil {
            activeHiddenFieldText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "hiddenField", let name = activeHiddenFieldName else { return }
        let value = activeHiddenFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            switch name {
            case "cache_name":
                metadata.cacheName = metadata.cacheName ?? value
            case "override_cache_name":
                metadata.overrideCacheName = metadata.overrideCacheName ?? value
            default:
                break
            }
        }
        activeHiddenFieldName = nil
        activeHiddenFieldText = ""
    }

    private func appendUnique(_ value: String?, to values: inout [String]) {
        guard let value, !values.contains(value) else { return }
        values.append(value)
    }
}
