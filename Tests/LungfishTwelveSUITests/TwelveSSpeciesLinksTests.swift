import XCTest
@testable import LungfishTwelveSUI

final class TwelveSSpeciesLinksTests: XCTestCase {
    func testNCBIWithTaxid() {
        XCTAssertEqual(
            TwelveSSpeciesLinks.ncbiTaxonomyURL(taxid: "9606", scientificName: "Homo sapiens").absoluteString,
            "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/9606/")
    }

    func testNCBINameSearchFallbackWhenNilTaxid() {
        XCTAssertEqual(
            TwelveSSpeciesLinks.ncbiTaxonomyURL(taxid: nil, scientificName: "Gallus gallus").absoluteString,
            "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/?term=Gallus%20gallus")
    }

    func testNCBIEmptyTaxidFallsBackToName() {
        XCTAssertEqual(
            TwelveSSpeciesLinks.ncbiTaxonomyURL(taxid: "  ", scientificName: "Canis lupus").absoluteString,
            "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/?term=Canis%20lupus")
    }

    func testWikipediaUnderscoresAndEncoding() {
        XCTAssertEqual(
            TwelveSSpeciesLinks.wikipediaURL(scientificName: "Homo sapiens").absoluteString,
            "https://en.wikipedia.org/wiki/Homo_sapiens")
    }
}
