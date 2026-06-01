import Foundation
@testable import LungfishIO

/// Shared minimal 12S result fixtures for the leaf UI tests.
///
/// A compact two-sample bundle (`SampleA` + `SampleB`) with two target species
/// and two unresolved clusters. Distinct per-sample counts let multi-sample
/// aggregation tests exercise sample-subset restriction.
enum TwelveSFixtures {
    static func twoSampleResult() -> TwelveSAmpliconResultBundleData {
        let bundleURL = URL(fileURLWithPath: "/tmp/fixture.lungfish12s")
        let manifest = TwelveSAmpliconResultBundleManifest(
            outputName: "fixture",
            analysisName: "Fixture",
            referencePath: "reference.fa",
            targetTablePath: "targets.tsv",
            countMatrixPath: "sample-target-counts.tsv",
            sampleTablePath: "samples.tsv",
            readFatePath: "read-fate.json",
            unresolvedTablePath: "unresolved-sequences.tsv",
            unresolvedFastaPath: "unresolved-sequences.fasta",
            provenancePath: ".lungfish-provenance.json"
        )
        let samples = [
            TwelveSAmpliconSampleResult(
                sampleID: "SampleA", displayName: "Sample A",
                inputReads: 60, exactMatchReads: 45, unresolvedReads: 15,
                ambiguousExactReads: 0, chimeraCandidateReads: 2,
                exactMatchPercent: 75, unresolvedPercent: 25
            ),
            TwelveSAmpliconSampleResult(
                sampleID: "SampleB", displayName: "Sample B",
                inputReads: 40, exactMatchReads: 20, unresolvedReads: 20,
                ambiguousExactReads: 0, chimeraCandidateReads: 1,
                exactMatchPercent: 50, unresolvedPercent: 50
            ),
        ]
        let targets = [
            TwelveSAmpliconTarget(
                targetID: "human",
                displayName: "human (Homo sapiens)",
                scientificName: "Homo sapiens",
                commonName: "human",
                taxid: "9606",
                taxonGroup: "Mammal"
            ),
            TwelveSAmpliconTarget(
                targetID: "chicken",
                displayName: "chicken (Gallus gallus)",
                scientificName: "Gallus gallus",
                commonName: "chicken",
                taxid: "9031",
                taxonGroup: "Bird"
            ),
        ]
        return TwelveSAmpliconResultBundleData(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: TwelveSAmpliconResultArtifacts(
                referenceURL: bundleURL.appendingPathComponent("reference.fa"),
                targetTableURL: bundleURL.appendingPathComponent("targets.tsv"),
                countMatrixURL: bundleURL.appendingPathComponent("sample-target-counts.tsv"),
                sampleTableURL: bundleURL.appendingPathComponent("samples.tsv"),
                readFateURL: bundleURL.appendingPathComponent("read-fate.json"),
                unresolvedTableURL: bundleURL.appendingPathComponent("unresolved-sequences.tsv"),
                unresolvedFastaURL: bundleURL.appendingPathComponent("unresolved-sequences.fasta"),
                provenanceURL: bundleURL.appendingPathComponent(".lungfish-provenance.json")
            ),
            samples: samples,
            targets: targets,
            countRows: [
                // SampleA-heavy human; chicken only in SampleB.
                "human": ["SampleA": 40, "SampleB": 5],
                "chicken": ["SampleA": 0, "SampleB": 15],
            ],
            readFate: TwelveSAmpliconReadFate(
                totalReads: 100,
                exactMatchReads: 65,
                unresolvedReads: 35,
                ambiguousExactReads: 0,
                chimeraCandidateReads: 3
            ),
            unresolvedSequences: [
                TwelveSUnresolvedSequence(
                    sequenceID: "unresolved_1",
                    sequence: "ACGTACGT",
                    readCount: 20,
                    sampleCounts: ["SampleA": 15, "SampleB": 5],
                    chimeraStatus: .candidate
                ),
                TwelveSUnresolvedSequence(
                    sequenceID: "unresolved_2",
                    sequence: "TGCATGCA",
                    readCount: 10,
                    sampleCounts: ["SampleB": 10],
                    chimeraStatus: .notDetected
                ),
            ]
        )
    }
}
