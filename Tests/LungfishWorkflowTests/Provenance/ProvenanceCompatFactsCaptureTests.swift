import Foundation
import Testing
import LungfishTestSupport

/// Writes the expected facts for corpus cases that have none yet. It runs only with
/// `LUNGFISH_CAPTURE_PROVENANCE_FACTS=1`, on unchanged code, and never replaces a
/// file. A reviewer reads every written file against its source bytes before it is
/// committed, and ProvenanceCompatReaderTests compares it byte for byte afterwards.
@Suite("Provenance compatibility facts capture")
struct ProvenanceCompatFactsCaptureTests {
    @Test(
        "writes expected facts for cases that have none",
        .enabled(if: ProvenanceCompatCorpus.captureFactsRequested)
    )
    func writesMissingExpectedFacts() throws {
        for item in try ProvenanceCompatCorpus.cases() where ProvenanceCompatCorpus.expectedFactsData(for: item.id) == nil {
            let materialized = try ProvenanceCompatCorpus.materialize(item.id)
            defer { materialized.cleanup() }
            let facts = try ProvenanceCompatFacts.project(
                sidecar: materialized.sidecar,
                projectRoot: materialized.projectRoot
            )
            try ProvenanceCompatCorpus.writeExpectedFacts(try facts.canonicalJSON(), for: item.id)
        }
    }
}
