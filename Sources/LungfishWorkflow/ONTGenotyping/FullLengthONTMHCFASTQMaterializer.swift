import Foundation
import LungfishIO

enum FullLengthONTMHCFASTQMaterializer {
    @discardableResult
    static func materializePlainFASTQ(inputURL: URL, outputURL: URL) throws -> URL {
        let inputFiles: [URL]
        if let allFASTQs = FASTQBundle.resolveAllFASTQURLs(for: inputURL), !allFASTQs.isEmpty {
            inputFiles = allFASTQs
        } else if let resolved = SequenceInputResolver.resolvePrimarySequenceURL(for: inputURL),
                  (SequenceInputResolver.inputSequenceFormat(for: inputURL) ?? SequenceFormat.from(url: resolved)) == .fastq {
            inputFiles = [resolved]
        } else {
            throw FullLengthONTMHCGenotypingError.invalidFASTQ(inputURL.path)
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        var previousChunkEndedWithNewline = true
        for inputFile in inputFiles {
            if !previousChunkEndedWithNewline {
                try output.write(contentsOf: Data([0x0a]))
                previousChunkEndedWithNewline = true
            }
            try inputFile.forEachChunkAutoDecompressing { chunk in
                guard !chunk.isEmpty else { return }
                try output.write(contentsOf: chunk)
                previousChunkEndedWithNewline = chunk.last == 0x0a || chunk.last == 0x0d
            }
        }

        return outputURL.standardizedFileURL
    }
}
