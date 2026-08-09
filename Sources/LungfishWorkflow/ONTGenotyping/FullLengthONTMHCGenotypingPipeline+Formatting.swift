import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

extension FullLengthONTMHCGenotypingPipeline {
    internal func removeGeneratedWorkflowIntermediates(_ workDirectory: URL) throws {
        if FileManager.default.fileExists(atPath: workDirectory.path) {
            try postPublicationWorkDirectoryCleaner.removeWorkDirectory(at: workDirectory)
        }
    }

    internal func append(
        records: [FullLengthONTMHCClusterFASTARecord],
        sample: String,
        to url: URL
    ) throws {
        guard !records.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for record in records {
            let text = ">\(sample)_\(record.name)\n\(record.sequence)\n"
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        }
    }

    internal func fastqReadCount(_ url: URL) -> Int {
        var lineCount = 0
        do {
            try url.forEachLineAutoDecompressing { _ in
                lineCount += 1
            }
            return lineCount / 4
        } catch {
            return 0
        }
    }

    internal func sampleName(for url: URL, fallbackIndex: Int) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "sample-\(fallbackIndex + 1)" : sanitizedSampleName(trimmed)
    }

    internal func sanitizedSampleName(_ value: String) -> String {
        let replaced = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "sample" : collapsed
    }

    internal func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    internal func optionalString<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? ""
    }

    internal func oneDecimalString(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.1f", value)
    }

    internal func formattedReadCount(_ value: Int) -> String {
        value.formatted(.number)
    }

    internal func sampleLabel(_ count: Int) -> String {
        count == 1 ? "sample" : "samples"
    }

    internal func jobLabel(_ count: Int) -> String {
        count == 1 ? "job" : "jobs"
    }

    internal func relativePath(from baseURL: URL, to targetURL: URL) -> String {
        let basePath = baseURL.standardizedFileURL.path
        let normalizedBase = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let targetPath = targetURL.standardizedFileURL.path
        guard targetPath.hasPrefix(normalizedBase) else { return targetPath }
        return String(targetPath.dropFirst(normalizedBase.count))
    }
}
