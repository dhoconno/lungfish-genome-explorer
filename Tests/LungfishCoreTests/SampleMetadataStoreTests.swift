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
}
