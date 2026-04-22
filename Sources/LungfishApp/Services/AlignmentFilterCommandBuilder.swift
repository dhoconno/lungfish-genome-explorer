import Foundation

enum AlignmentFilterCommandBuilder {
    static func build(
        request: AlignmentFilterRequest,
        inputBAMURL: URL,
        outputBAMURL: URL
    ) throws -> AlignmentFilterCommandPlan {
        var arguments = ["view", "-b", "-o", outputBAMURL.path]
        var summaryParts: [String] = []
        var excludedFlags = 0
        var requiredFlags = 0
        var requiredTags: [String] = []

        if request.minimumMAPQ > 0 {
            arguments += ["-q", String(request.minimumMAPQ)]
            summaryParts.append("MAPQ ≥ \(request.minimumMAPQ)")
        }

        if request.mappedOnly {
            excludedFlags |= 0x4
            summaryParts.append("mapped only")
        }

        if request.primaryOnly {
            excludedFlags |= 0x100
            excludedFlags |= 0x800
            summaryParts.append("primary only")
        }

        if request.properPairsOnly {
            requiredFlags |= 0x2
            summaryParts.append("proper pairs only")
        }

        if request.bothMatesMapped {
            requiredFlags |= 0x1
            excludedFlags |= 0x4
            excludedFlags |= 0x8
            summaryParts.append("both mates mapped")
        }

        switch request.duplicateMode {
        case .keepAll:
            break
        case .excludeMarked:
            excludedFlags |= 0x400
            summaryParts.append("duplicate-marked reads excluded")
        case .remove:
            excludedFlags |= 0x400
            summaryParts.append("duplicates removed")
        }

        if requiredFlags > 0 {
            arguments += ["-f", String(requiredFlags)]
        }

        if excludedFlags > 0 {
            arguments += ["-F", String(excludedFlags)]
        }

        switch request.identityFilter {
        case .none:
            break
        case .exactMatchesOnly:
            requiredTags = ["NM"]
            arguments += ["-e", "exists([NM]) && [NM] == 0"]
            summaryParts.append("exact matches only")
        case .minimumPercent(let percent):
            requiredTags = ["NM"]
            let locale = Locale(identifier: "en_US_POSIX")
            let threshold = percent / 100.0
            let formattedThreshold = String(format: "%.2f", locale: locale, threshold)
            let formattedPercent = String(format: "%.1f", locale: locale, percent)
            arguments += [
                "-e",
                "exists([NM]) && qlen > sclen && (((qlen-sclen)-[NM])/(qlen-sclen)) >= \(formattedThreshold)"
            ]
            summaryParts.append("identity ≥ \(formattedPercent)%")
        }
        arguments.append(inputBAMURL.path)
        arguments.append(contentsOf: request.regions)

        return AlignmentFilterCommandPlan(
            arguments: arguments,
            requiredTags: requiredTags,
            summary: summaryParts.joined(separator: "; ")
        )
    }
}
