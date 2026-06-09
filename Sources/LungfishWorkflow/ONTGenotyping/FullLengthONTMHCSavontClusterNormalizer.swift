import Foundation
import LungfishIO

public enum FullLengthONTMHCSavontClusterNormalizer {
    public static func normalize(
        savontFinalASVFASTAURL: URL,
        outputFASTAURL: URL
    ) throws {
        var output = ""
        try savontFinalASVFASTAURL.forEachLineAutoDecompressing { line in
            if line.hasPrefix(">") {
                let rawName = String(line.dropFirst())
                let firstToken = rawName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? rawName
                if firstToken.contains("ReadCount-") {
                    output += ">\(firstToken)\n"
                } else {
                    output += ">\(firstToken)_ReadCount-\(readDepth(from: firstToken))\n"
                }
            } else {
                output += "\(line.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            }
        }
        try output.write(to: outputFASTAURL, atomically: true, encoding: .utf8)
    }

    static func readDepth(from header: String) -> Int {
        guard let range = header.range(of: "_depth_") else { return 0 }
        let suffix = header[range.upperBound...]
        let digits = suffix.prefix(while: \.isNumber)
        return Int(digits) ?? 0
    }
}
