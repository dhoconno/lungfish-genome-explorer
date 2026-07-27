import Foundation

/// Pure, shared validation for user-visible manual haplotype labels.
///
/// Formula-leading strings are intentionally accepted as literal scientific
/// labels. Exporters are responsible for escaping formulas in their output
/// format rather than changing the stored label.
public enum GenotypeManualHaplotypeAssignmentInputValidator {
    public static let maximumLabelUnicodeScalarCount = 128

    public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
        case emptyLabel
        case labelTooLong(maximumUnicodeScalars: Int)
        case controlCharacter

        public var errorDescription: String? {
            switch self {
            case .emptyLabel:
                return "A manual haplotype label must not be empty."
            case .labelTooLong(let maximum):
                return "A manual haplotype label must contain at most \(maximum) Unicode scalars."
            case .controlCharacter:
                return "A manual haplotype label must not contain control characters."
            }
        }
    }

    public static func validatedLabel(_ rawLabel: String) throws -> String {
        let label = rawLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !label.isEmpty else {
            throw ValidationError.emptyLabel
        }
        guard label.unicodeScalars.count <= maximumLabelUnicodeScalarCount else {
            throw ValidationError.labelTooLong(
                maximumUnicodeScalars: maximumLabelUnicodeScalarCount
            )
        }
        guard !label.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw ValidationError.controlCharacter
        }
        return label
    }

    public static func normalizedLabelKey(for rawLabel: String) throws -> String {
        try validatedLabel(rawLabel)
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCanonicalMapping
    }
}
