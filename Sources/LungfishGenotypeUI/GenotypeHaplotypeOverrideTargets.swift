import Foundation

enum GenotypeHaplotypeOverrideTargets {
    static let unresolved = "?"

    static func expandedTargets(from names: [String], includeUnknown: Bool) -> [String] {
        var seen = Set<String>()
        var targets: [String] = []
        for name in names {
            for target in expandedTargets(from: name) where !target.isEmpty {
                if seen.insert(target).inserted {
                    targets.append(target)
                }
            }
        }
        if includeUnknown, seen.insert(unresolved).inserted {
            targets.append(unresolved)
        }
        return targets
    }

    static func expandedTargets(from name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("/") else { return trimmed.isEmpty ? [] : [trimmed] }
        let parts = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count > 1 else { return trimmed.isEmpty ? [] : [trimmed] }
        guard let final = parseMauritianFamily(parts.last ?? "") else {
            return [trimmed]
        }
        let suffix = final.suffix
        var expanded: [String] = []
        for part in parts {
            guard let parsed = parseMauritianFamily(part) else {
                return [trimmed]
            }
            let targetSuffix = parsed.suffix.isEmpty ? suffix : parsed.suffix
            expanded.append(parsed.family + targetSuffix)
        }
        return expanded
    }

    private static func parseMauritianFamily(_ value: String) -> (family: String, suffix: String)? {
        guard value.hasPrefix("M") else { return nil }
        let suffixStart = value.dropFirst().firstIndex { !$0.isNumber } ?? value.endIndex
        guard suffixStart > value.index(after: value.startIndex) else { return nil }
        let family = String(value[..<suffixStart])
        let suffix = String(value[suffixStart...])
        return (family, suffix)
    }
}
