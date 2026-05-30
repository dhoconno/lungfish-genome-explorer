import Foundation
import Testing
@testable import LungfishCore

@Suite("SampleMetadataResolver")
struct SampleMetadataResolverTests {
    @Test("Analysis metadata overrides FASTQ metadata without clearing blank cells")
    func resolvesPrecedenceAndBlankCells() throws {
        let fastq = SampleMetadataTable(
            columns: ["sample_name", "sample_type", "collection_date", "site"],
            records: [
                "S1": [
                    "sample_name": "Sample One",
                    "sample_type": "wastewater",
                    "collection_date": "2026-05-11",
                    "site": "Hilo",
                ],
            ],
            source: .init(kind: .fastqBundle, path: "/tmp/S1.lungfishfastq")
        )
        let analysis = SampleMetadataTable(
            columns: ["sample_name", "site", "batch_id"],
            records: [
                "S1": [
                    "sample_name": "",
                    "site": "Hilo WWTP",
                    "batch_id": "run-42",
                ],
            ],
            source: .init(kind: .analysisOverride, path: "/tmp/analysis.tsv")
        )

        let resolved = SampleMetadataResolver.resolve(
            sampleIDs: ["S1"],
            sourceTables: [fastq, analysis]
        )

        #expect(resolved.columns == ["sample_id", "sample_name", "sample_type", "collection_date", "site", "batch_id"])
        #expect(resolved.records["S1"]?["sample_name"] == "Sample One")
        #expect(resolved.records["S1"]?["sample_type"] == "wastewater")
        #expect(resolved.records["S1"]?["site"] == "Hilo WWTP")
        #expect(resolved.records["S1"]?["batch_id"] == "run-42")
        #expect(resolved.cellSources["S1"]?["site"]?.kind == .analysisOverride)
        #expect(resolved.cellSources["S1"]?["sample_type"]?.kind == .fastqBundle)
    }

    @Test("Normalized-equivalent columns override the frozen TSV column")
    func normalizedEquivalentColumnsUseCanonicalOutputColumn() throws {
        let fastq = SampleMetadataTable(
            columns: ["sample_type"],
            records: [
                "S1": ["sample_type": "wastewater"],
            ],
            source: .init(kind: .fastqBundle, path: "/tmp/S1.lungfishfastq")
        )
        let analysis = SampleMetadataTable(
            columns: ["Sample Type"],
            records: [
                "S1": ["Sample Type": "wastewater-influent"],
            ],
            source: .init(kind: .analysisOverride, path: "/tmp/analysis.tsv")
        )

        let resolved = SampleMetadataResolver.resolve(
            sampleIDs: ["S1"],
            sourceTables: [fastq, analysis]
        )

        #expect(resolved.columns == ["sample_id", "sample_type"])
        #expect(resolved.records["S1"]?["sample_type"] == "wastewater-influent")
        #expect(resolved.records["S1"]?["Sample Type"] == nil)
        #expect(resolved.tsvString().contains("S1\twastewater-influent\n"))
    }

    @Test("Delimited analysis metadata rejects duplicate sample IDs")
    func parseRejectsDuplicateSampleIDs() throws {
        let data = Data("""
        sample_id\tsite
        S1\tA
        s1\tB
        """.utf8)

        #expect(throws: SampleMetadataResolverError.duplicateSampleID("s1")) {
            try SampleMetadataTable.parseDelimited(
                data: data,
                knownSampleIDs: ["S1"],
                source: .init(kind: .analysisOverride, path: "/tmp/meta.tsv")
            )
        }
    }

    @Test("Delimited analysis metadata fails when no rows match known samples")
    func parseRejectsZeroOverlap() throws {
        let data = Data("""
        sample_id\tsite
        X1\tA
        """.utf8)

        #expect(throws: SampleMetadataResolverError.noMatchingSamples) {
            try SampleMetadataTable.parseDelimited(
                data: data,
                knownSampleIDs: ["S1"],
                source: .init(kind: .analysisOverride, path: "/tmp/meta.tsv")
            )
        }
    }
}
