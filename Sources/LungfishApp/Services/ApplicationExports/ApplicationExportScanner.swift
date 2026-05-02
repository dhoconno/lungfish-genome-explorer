import Foundation
import LungfishIO
import LungfishWorkflow

public struct ApplicationExportScanner: Sendable {
    private let archiveTool: GeneiousArchiveTool

    public init(archiveTool: GeneiousArchiveTool = GeneiousArchiveTool()) {
        self.archiveTool = archiveTool
    }

    private var fileManager: FileManager { .default }

    public func scan(
        sourceURL: URL,
        kind: ApplicationExportKind,
        temporaryDirectory: URL? = nil
    ) async throws -> ApplicationExportImportInventory {
        let sourceKind = try sourceKind(for: sourceURL)
        let scanRoot: URL
        let cleanupRoot: URL?

        switch sourceKind {
        case .archive:
            guard let tempRoot = temporaryDirectory else {
                throw ApplicationExportScannerError.temporaryDirectoryRequired
            }
            try archiveTool.extract(archiveURL: sourceURL, to: tempRoot)
            scanRoot = tempRoot
            cleanupRoot = tempRoot
        case .folder, .file:
            scanRoot = sourceURL
            cleanupRoot = nil
        }

        defer {
            if let cleanupRoot {
                try? fileManager.removeItem(at: cleanupRoot)
            }
        }

        var warnings: [String] = []
        let items = try scanItems(rootURL: scanRoot, sourceKind: sourceKind)
        if sourceKind == .archive && items.isEmpty {
            warnings.append("The application export archive did not contain any importable file entries.")
        }

        return ApplicationExportImportInventory(
            sourceURL: sourceURL,
            sourceKind: sourceKind,
            sourceName: sourceURL.lastPathComponent,
            applicationKind: kind,
            items: items,
            warnings: warnings
        )
    }

    private func sourceKind(for sourceURL: URL) throws -> ApplicationExportImportSourceKind {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if isDirectory.boolValue {
            return .folder
        }
        if Self.archiveExtensions.contains(ReferenceBundleImportService.normalizedExtension(for: sourceURL)) {
            return .archive
        }
        return .file
    }

    private func scanItems(rootURL: URL, sourceKind: ApplicationExportImportSourceKind) throws -> [ApplicationExportImportItem] {
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

        var scanned: [ApplicationExportImportItem] = []
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

        return scanned.sorted {
            $0.sourceRelativePath.localizedStandardCompare($1.sourceRelativePath) == .orderedAscending
        }
    }

    private func scanFile(
        url: URL,
        relativePath: String,
        sourceKind: ApplicationExportImportSourceKind
    ) throws -> ApplicationExportImportItem {
        let kind = classify(url: url, relativePath: relativePath)
        return ApplicationExportImportItem(
            sourceRelativePath: relativePath,
            stagedRelativePath: sourceKind == .archive ? relativePath : nil,
            kind: kind,
            sizeBytes: Self.fileSizeBytes(url: url),
            sha256: ProvenanceRecorder.sha256(of: url),
            warnings: warnings(for: kind)
        )
    }

    private func classify(url: URL, relativePath: String) -> ApplicationExportImportItemKind {
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
        let lowerName = URL(fileURLWithPath: relativePath).lastPathComponent.lowercased()
        if Self.nativeProjectExtensions.contains(normalizedExtension) {
            return .nativeProject
        }
        if Self.platformMetadataNames.contains(lowerName) || Self.platformMetadataExtensions.contains(normalizedExtension) {
            return .platformMetadata
        }
        if Self.phylogeneticsExtensions.contains(normalizedExtension) {
            return .phylogeneticsArtifact
        }
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

    private func warnings(for kind: ApplicationExportImportItemKind) -> [String] {
        switch kind {
        case .nativeProject:
            return ["Native application project data is preserved but not decoded in the no-vendor-app baseline."]
        case .treeOrAlignment:
            return ["Alignment or tree content is preserved until native LGE MSA/tree bundles are available."]
        case .phylogeneticsArtifact:
            return ["Phylogenetics result content is preserved until native LGE phylogenetics bundles are available."]
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

    private static let archiveExtensions: Set<String> = ["qza", "qzv", "zip"]
    private static let nativeProjectExtensions: Set<String> = [
        "ba6", "clc", "dna", "ga4", "gvp", "jvp", "ma4", "oa4", "pa4", "pro", "sbd", "seq", "ugenedb",
    ]
    private static let treeOrAlignmentExtensions: Set<String> = [
        "aln", "amsa", "clustal", "maf", "mega", "msf", "nex", "nexus", "nwk", "phy", "phylip", "pir",
        "pfam", "pileup", "sto", "stockholm", "tree", "tre",
    ]
    private static let phylogeneticsExtensions: Set<String> = ["jsonl", "mat", "ndjson", "pb", "trees"]
    private static let signalTrackExtensions: Set<String> = ["bedgraph", "bigwig", "bw", "tdf", "wig", "wiggle"]
    private static let reportExtensions: Set<String> = [
        "csv", "html", "htm", "json", "log", "md", "pdf", "png", "svg", "tif", "tiff", "tsv", "txt", "xls", "xlsx", "xml",
    ]
    private static let platformMetadataExtensions: Set<String> = ["interop", "pbi", "pod5"]
    private static let platformMetadataNames: Set<String> = [
        "runinfo.xml", "runparameters.xml", "sample_sheet.csv", "samplesheet.csv", "sequencing_summary.txt",
        "final_summary.txt", "datastore.json", "output_hash", "barcode_alignment_report.tsv",
    ]
}

public enum ApplicationExportScannerError: LocalizedError, Sendable, Equatable {
    case temporaryDirectoryRequired

    public var errorDescription: String? {
        switch self {
        case .temporaryDirectoryRequired:
            return "Scanning an application export archive requires a project-local temporary directory."
        }
    }
}
