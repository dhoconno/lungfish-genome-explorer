enum GenotypeHaplotypeTokenNormalization {
    static func removingLeadingRunNumber(from token: String) -> String {
        let parts = token.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].allSatisfy(\.isNumber) else { return token }
        return String(parts[1])
    }
}
