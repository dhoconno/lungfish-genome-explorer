import Testing
import Foundation
@testable import LungfishCore

@Suite("SampleMetadataStore")
struct SampleMetadataStoreTests {

    @Test("Parses TSV with tab delimiter")
    func parseTSV() throws {
        let tsv = "Sample\tType\tLocation\nS1\tww\tColumbia\nS2\tww\tJefferson City\n"
        let data = Data(tsv.utf8)
        let store = try SampleMetadataStore(
            csvData: data,
            knownSampleIds: Set(["S1", "S2", "S3"])
        )
        #expect(store.columnNames == ["Type", "Location"])
        #expect(store.records["S1"]?["Type"] == "ww")
        #expect(store.records["S2"]?["Location"] == "Jefferson City")
        #expect(store.matchedSampleIds == Set(["S1", "S2"]))
        #expect(store.unmatchedRecords.isEmpty)
    }

    @Test("Parses CSV with comma delimiter")
    func parseCSV() throws {
        let csv = "Sample,Type,Location\nS1,ww,Columbia\n"
        let data = Data(csv.utf8)
        let store = try SampleMetadataStore(csvData: data, knownSampleIds: Set(["S1"]))
        #expect(store.columnNames == ["Type", "Location"])
        #expect(store.records["S1"]?["Type"] == "ww")
    }

    @Test("Unmatched samples go to unmatchedRecords")
    func unmatchedSamples() throws {
        let tsv = "Sample\tType\nS1\tww\nS99\tunknown\n"
        let data = Data(tsv.utf8)
        let store = try SampleMetadataStore(csvData: data, knownSampleIds: Set(["S1"]))
        #expect(store.matchedSampleIds == Set(["S1"]))
        #expect(store.unmatchedRecords["S99"]?["Type"] == "unknown")
    }

    @Test("Case-insensitive sample matching")
    func caseInsensitive() throws {
        let tsv = "Sample\tType\ns1\tww\n"
        let data = Data(tsv.utf8)
        let store = try SampleMetadataStore(csvData: data, knownSampleIds: Set(["S1"]))
        #expect(store.matchedSampleIds == Set(["S1"]))
    }

    @Test("Apply edit records change")
    func applyEdit() throws {
        let tsv = "Sample\tType\nS1\tww\n"
        let data = Data(tsv.utf8)
        let store = try SampleMetadataStore(csvData: data, knownSampleIds: Set(["S1"]))
        store.applyEdit(sampleId: "S1", column: "Type", newValue: "clinical")
        #expect(store.records["S1"]?["Type"] == "clinical")
        #expect(store.edits.count == 1)
        #expect(store.edits[0].oldValue == "ww")
        #expect(store.edits[0].newValue == "clinical")
    }

    @Test("Serialize and deserialize edits JSON")
    func editsPersistence() throws {
        let tsv = "Sample\tType\nS1\tww\n"
        let data = Data(tsv.utf8)
        let store = try SampleMetadataStore(csvData: data, knownSampleIds: Set(["S1"]))
        store.applyEdit(sampleId: "S1", column: "Type", newValue: "clinical")
        let json = try store.editsJSON()
        #expect(json.count > 10)
        let decoded = try JSONDecoder().decode([MetadataEdit].self, from: json)
        #expect(decoded.count == 1)
        #expect(decoded[0].newValue == "clinical")
    }

    @Test("Empty cells handled gracefully")
    func emptyCells() throws {
        let tsv = "Sample\tType\tLocation\nS1\t\tColumbia\n"
        let data = Data(tsv.utf8)
        let store = try SampleMetadataStore(csvData: data, knownSampleIds: Set(["S1"]))
        #expect(store.records["S1"]?["Type"] == "")
        #expect(store.records["S1"]?["Location"] == "Columbia")
    }

    // MARK: - Column Scanning Tests

    @Test("scanForSampleColumn picks column with most matches")
    func scanPicksBestColumn() throws {
        let tsv = "Index\tBarcode\tType\n1\tS1\tww\n2\tS2\tclinical\n3\tS3\tenv\n"
        let data = Data(tsv.utf8)
        let result = try SampleMetadataStore.scanForSampleColumn(
            csvData: data,
            knownSampleIds: Set(["S1", "S2", "S3"])
        )
        #expect(result.bestColumn!.name == "Barcode")
        #expect(result.bestColumn!.matchCount == 3)
        #expect(result.totalRows == 3)
    }

    @Test("scanForSampleColumn tie-breaks by leftmost column")
    func scanTieBreaksLeftmost() throws {
        let tsv = "A\tB\nS1\tS1\nS2\tS2\n"
        let data = Data(tsv.utf8)
        let result = try SampleMetadataStore.scanForSampleColumn(
            csvData: data,
            knownSampleIds: Set(["S1", "S2"])
        )
        #expect(result.bestColumn!.name == "A")
    }

    @Test("scanForSampleColumn returns empty candidates when nothing matches")
    func scanNoMatches() throws {
        let tsv = "Foo\tBar\nX\tY\n"
        let data = Data(tsv.utf8)
        let result = try SampleMetadataStore.scanForSampleColumn(
            csvData: data,
            knownSampleIds: Set(["S1", "S2"])
        )
        #expect(result.candidates.isEmpty)
        #expect(result.bestColumn == nil)
    }

    @Test("scanForSampleColumn case-insensitive matching")
    func scanCaseInsensitive() throws {
        let tsv = "Name\tType\ns1\tww\nS2\tclinical\n"
        let data = Data(tsv.utf8)
        let result = try SampleMetadataStore.scanForSampleColumn(
            csvData: data,
            knownSampleIds: Set(["S1", "S2"])
        )
        #expect(result.bestColumn!.name == "Name")
        #expect(result.bestColumn!.matchCount == 2)
    }

    @Test("Init from scan result uses correct sample column")
    func initFromScanResult() throws {
        let tsv = "Index\tBarcode\tType\n1\tS1\tww\n2\tS2\tclinical\n"
        let data = Data(tsv.utf8)
        let scanResult = try SampleMetadataStore.scanForSampleColumn(
            csvData: data,
            knownSampleIds: Set(["S1", "S2"])
        )
        let store = SampleMetadataStore(
            scanResult: scanResult,
            sampleColumnIndex: scanResult.bestColumn!.index,
            knownSampleIds: Set(["S1", "S2"])
        )
        #expect(store.columnNames == ["Index", "Type"])
        #expect(store.records["S1"]?["Type"] == "ww")
        #expect(store.records["S1"]?["Index"] == "1")
        #expect(store.records["S2"]?["Type"] == "clinical")
        #expect(store.matchedSampleIds == Set(["S1", "S2"]))
    }

    @Test("load from bundle detects non-leading sample column")
    func loadDetectsSampleColumn() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-metadata-load-\(UUID().uuidString)", isDirectory: true)
        let metadataURL = bundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let tsv = """
        row_id\tsample_accession\tcity
        1\tSRR001\tDallas
        2\tSRR002\tHouston
        """
        try Data(tsv.utf8).write(to: metadataURL.appendingPathComponent("sample_metadata.tsv"))

        let store = SampleMetadataStore.load(from: bundleURL, knownSampleIds: Set(["SRR001", "SRR002"]))
        #expect(store?.columnNames == ["row_id", "city"])
        #expect(store?.records["SRR001"]?["city"] == "Dallas")
        #expect(store?.records["SRR002"]?["city"] == "Houston")
    }
}
