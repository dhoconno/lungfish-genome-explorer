import Foundation
import LungfishIO

enum FASTAOperationCatalog {
    enum Error: LocalizedError {
        case emptyInput

        var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "No FASTA records were provided."
            }
        }
    }

    static func availableOperationKinds() -> [FASTQDerivativeOperationKind] {
        FASTQDerivativeOperationKind.allCases.filter(\.supportsFASTA)
    }

    static func availableToolIDs() -> [FASTQOperationToolID] {
        FASTQOperationToolID.allCases.filter(\.supportsFASTA)
    }

    static func inputSequenceFormat(for url: URL) -> SequenceFormat? {
        let standardizedURL = url.standardizedFileURL
        if FASTQBundle.isBundleURL(standardizedURL),
           let manifest = FASTQBundle.loadDerivedManifest(in: standardizedURL) {
            return manifest.sequenceFormat ?? inferredSequenceFormat(from: manifest.payload)
        }

        let parentBundleURL = standardizedURL.deletingLastPathComponent()
        if FASTQBundle.isBundleURL(parentBundleURL),
           let manifest = FASTQBundle.loadDerivedManifest(in: parentBundleURL) {
            return manifest.sequenceFormat ?? inferredSequenceFormat(from: manifest.payload)
        }

        return SequenceFormat.from(url: standardizedURL)
    }

    static func createTemporaryInputBundle(
        fastaRecords: [String],
        suggestedName: String,
        projectURL: URL?
    ) throws -> URL {
        guard !fastaRecords.isEmpty else {
            throw Error.emptyInput
        }

        let tempRoot = try ProjectTempDirectory.create(
            prefix: "lungfish-fasta-ops-",
            in: projectURL
        )
        let bundleName = sanitizedBundleStem(from: suggestedName)
        let bundleURL = tempRoot.appendingPathComponent(
            "\(bundleName).\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )

        let fastaFilename = "selection.fasta"
        let fastaURL = bundleURL.appendingPathComponent(fastaFilename)
        let normalizedFASTA = fastaRecords
            .map(normalizeRecord)
            .joined(separator: "")
        try normalizedFASTA.write(to: fastaURL, atomically: true, encoding: .utf8)

        let statistics = FASTQDatasetStatistics.placeholder(
            readCount: recordCount(in: normalizedFASTA),
            baseCount: baseCount(in: normalizedFASTA)
        )
        let manifest = FASTQDerivedBundleManifest(
            name: bundleName,
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: fastaFilename,
            payload: .fullFASTA(fastaFilename: fastaFilename),
            lineage: [],
            operation: FASTQDerivativeOperation(
                kind: .searchText,
                query: "selected-fasta-sequences"
            ),
            cachedStatistics: statistics,
            pairingMode: nil,
            sequenceFormat: .fasta
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        return bundleURL
    }

    private static func inferredSequenceFormat(
        from payload: FASTQDerivativePayload
    ) -> SequenceFormat? {
        switch payload {
        case .fullFASTA:
            return .fasta
        default:
            return nil
        }
    }

    private static func sanitizedBundleStem(from suggestedName: String) -> String {
        let trimmed = suggestedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "selected-sequences" : trimmed
    }

    private static func normalizeRecord(_ record: String) -> String {
        var normalized = record
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.hasSuffix("\n") {
            normalized.append("\n")
        }
        return normalized
    }

    private static func recordCount(in fasta: String) -> Int {
        fasta.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(">") }.count
    }

    private static func baseCount(in fasta: String) -> Int64 {
        Int64(
            fasta
                .split(whereSeparator: \.isNewline)
                .filter { !$0.hasPrefix(">") }
                .reduce(into: 0) { $0 += $1.count }
        )
    }
}
