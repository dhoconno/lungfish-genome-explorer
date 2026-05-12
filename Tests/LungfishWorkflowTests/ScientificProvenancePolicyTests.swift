import Testing
@testable import LungfishWorkflow

@Suite("Scientific Provenance Policy")
struct ScientificProvenancePolicyTests {
    @Test("native tools all have provenance policy entries")
    func nativeToolsHavePolicyEntries() {
        let missing = NativeTool.allCases.filter { ScientificProvenancePolicy.nativeTool($0) == nil }

        #expect(
            missing.isEmpty,
            "Missing native tool provenance policies: \(missing.map(\.rawValue).joined(separator: ", "))"
        )
    }
}
