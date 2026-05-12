import Testing
@testable import LungfishWorkflow

@Suite("Scientific Provenance Policy")
struct ScientificProvenancePolicyTests {
    @Test("native tools all have provenance policy entries")
    func nativeToolsHavePolicyEntries() {
        let toolNames = Set(NativeTool.allCases.map(\.rawValue))
        let policyNames = Set(ScientificProvenancePolicy.nativeToolPolicies.keys)
        let missing = toolNames.subtracting(policyNames).sorted()
        let stale = policyNames.subtracting(toolNames).sorted()

        #expect(
            missing.isEmpty,
            "Missing native tool provenance policies: \(missing.joined(separator: ", "))"
        )
        #expect(
            stale.isEmpty,
            "Native provenance policy references removed tools: \(stale.joined(separator: ", "))"
        )
    }

    @Test("native tool policies require concrete writer ownership")
    func nativeToolPoliciesRequireConcreteWriterOwnership() throws {
        let incomplete = NativeTool.allCases.compactMap { tool -> String? in
            guard let policy = ScientificProvenancePolicy.nativeTool(tool),
                  policy.createsOrModifiesScientificData,
                  policy.requiresProvenance,
                  !policy.writer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return tool.rawValue
            }
            return nil
        }

        #expect(
            incomplete.isEmpty,
            "Incomplete native tool provenance policies: \(incomplete.joined(separator: ", "))"
        )
    }
}
