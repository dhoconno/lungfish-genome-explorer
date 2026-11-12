import Foundation

/// A plain-language explanation attached to a saved scheme target.
public struct PrimerSchemeCoverageAdvisory: Equatable, Sendable {
    public enum Severity: String, Equatable, Sendable { case info, warning }
    public var severity: Severity
    public var message: String
    public init(severity: Severity, message: String) {
        self.severity = severity; self.message = message
    }
}

extension PrimerSchemeResultsDocument {
    /// Tiled coverage below this fraction triggers the longest-chain explanation.
    static let varVAMPChainAdvisoryCoverage = 0.95

    /// What a person should read beside a saved target of either engine. varVAMP gets its coverage
    /// explanations. Olivar records only the warnings its adapter wrote (an amplicon outside the
    /// requested size range, for one), so those are all it shows.
    public func schemeAdvisories(for target: PrimerSchemeTarget) -> [PrimerSchemeCoverageAdvisory] {
        switch engine {
        case .varvamp:
            return varVAMPCoverageAdvisories(for: target)
        case .olivar:
            return Self.nativeWarningAdvisories(recordedDiagnostics(for: target), engineName: "Olivar")
        }
    }

    /// The diagnostics the adapter recorded for this target's input, when it recorded any.
    private func recordedDiagnostics(for target: PrimerSchemeTarget) -> [String: PrimerSchemeJSONValue]? {
        resolvedOptions["adapterResolution"]?.advisoryObject?["coverageDiagnostics"]?.advisoryObject?[
            target.sourceInputID.uuidString.lowercased()]?.advisoryObject
    }

    /// One warning advisory for each line the engine wrote to its own log or the adapter wrote for it.
    private static func nativeWarningAdvisories(
        _ diagnostics: [String: PrimerSchemeJSONValue]?, engineName: String
    ) -> [PrimerSchemeCoverageAdvisory] {
        (diagnostics?["nativeWarnings"]?.advisoryStrings ?? []).map {
            .init(severity: .warning, message: "\(engineName) warning: \($0)")
        }
    }

    /// Explains how varVAMP arrived at a target's coverage: the consensus threshold it
    /// actually used (in "k of N sequences" terms when the adapter recorded N), the
    /// warnings varVAMP wrote to its own log, and its single-chain tiling model.
    /// Older bundles without adapter diagnostics still report the stored threshold.
    public func varVAMPCoverageAdvisories(for target: PrimerSchemeTarget) -> [PrimerSchemeCoverageAdvisory] {
        guard engine == .varvamp else { return [] }
        let inputKey = target.sourceInputID.uuidString.lowercased()
        let resolution = resolvedOptions["adapterResolution"]?.advisoryObject ?? [:]
        let diagnostics = recordedDiagnostics(for: target)
        var advisories: [PrimerSchemeCoverageAdvisory] = []

        let threshold = diagnostics?["effectiveThreshold"]?.advisoryNumber
            ?? resolution["nativeCumulativeConsensusThresholds"]?.advisoryObject?[inputKey]?.advisoryNumber
        if let threshold {
            let automatic: Bool
            if let source = diagnostics?["thresholdSource"]?.advisoryString {
                automatic = source == "automatic"
            } else {
                automatic = resolvedOptions["cumulativeConsensusThreshold"] == .null
            }
            var message = "Consensus threshold \(Self.twoDecimals(threshold)), "
                + (automatic ? "chosen automatically by varVAMP." : "as requested.")
            if let count = diagnostics?["sequenceCount"]?.advisoryInteger,
               let required = diagnostics?["requiredAgreeing"]?.advisoryInteger {
                message += " A base counts as conserved only when \(required) of \(count) sequences agree."
                if let range = diagnostics?["equivalentThresholdRange"]?.advisoryNumbers, range.count == 2,
                   range[0] < range[1] {
                    message += " Any threshold from \(Self.twoDecimals(range[0])) to \(Self.twoDecimals(range[1])) gives the same consensus for this alignment."
                }
            }
            advisories.append(.init(severity: .info, message: message))
        }

        advisories += Self.nativeWarningAdvisories(diagnostics, engineName: "varVAMP")

        if mode == .tiled, target.referenceLength > 0,
           Double(Self.coveredBases(target.assays)) / Double(target.referenceLength) < Self.varVAMPChainAdvisoryCoverage {
            advisories.append(.init(severity: .warning, message:
                "varVAMP keeps only the longest unbroken chain of overlapping amplicons. "
                + "Regions it cannot link are left uncovered instead of starting a second chain. "
                + "Wider amplicon size bounds, a lower consensus threshold or more allowed ambiguous bases usually close these gaps."))
        }
        return advisories
    }

    static func coveredBases(_ assays: [PrimerSchemeAssay]) -> Int {
        var total = 0, end = 0
        for assay in assays.sorted(by: { $0.start < $1.start }) where assay.end > end {
            total += assay.end - max(end, assay.start); end = assay.end
        }
        return total
    }

    private static func twoDecimals(_ value: Double) -> String { String(format: "%.2f", value) }
}

private extension PrimerSchemeJSONValue {
    var advisoryObject: [String: PrimerSchemeJSONValue]? {
        if case .object(let value) = self { return value }; return nil
    }
    var advisoryNumber: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }
    var advisoryInteger: Int? { if case .integer(let value) = self { return value }; return nil }
    var advisoryString: String? { if case .string(let value) = self { return value }; return nil }
    var advisoryNumbers: [Double]? {
        guard case .array(let values) = self else { return nil }
        let numbers = values.compactMap(\.advisoryNumber)
        return numbers.count == values.count ? numbers : nil
    }
    var advisoryStrings: [String]? {
        guard case .array(let values) = self else { return nil }
        let strings = values.compactMap(\.advisoryString)
        return strings.count == values.count ? strings : nil
    }
}
