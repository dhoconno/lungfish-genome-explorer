import Foundation

enum VariantAttachmentPathComponent {
    static func sanitizedTrackBasename(_ rawValue: String, fallback: String = "variant-track") -> String {
        var result = ""
        var previousWasSeparator = false

        for scalar in rawValue.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if scalar == "-" || scalar == "_" {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? fallback : trimmed
    }
}
