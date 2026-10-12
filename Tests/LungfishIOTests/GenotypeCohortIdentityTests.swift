import XCTest
@testable import LungfishIO

/// Phase 2.8 decisions O2 and G2. A smart cohort stores an optional `id`. A
/// cohort that stores none has a UUID version 5 derived from its scope and name,
/// the n-th cohort of one scope and name derives from `[scope, name, n]`, and
/// the next save of the sidecar stores the derived value.
///
/// The expected ids are Python `uuid.uuid5` values of
/// `json.dumps(array, separators=(",", ":"), ensure_ascii=False)` under the
/// namespace `EAE6B16C-E0F3-4099-B3D7-DB52CED9199C`, so they share no code with
/// the Swift derivation.
final class GenotypeCohortIdentityTests: XCTestCase {
    private typealias Filter = GenotypeCohortSmartFilter

    private struct Vector {
        let scope: String
        let name: String
        let ordinal: Int
        let array: String
        let id: String
    }

    private static let vectors: [Vector] = [
        Vector(scope: "bundle", name: "Incomplete haplotypes", ordinal: 1,
               array: #"["bundle","Incomplete haplotypes"]"#, id: "31D2B132-01DD-5F19-BC0A-8878472F012F"),
        Vector(scope: "bundle", name: "Needs review", ordinal: 1,
               array: #"["bundle","Needs review"]"#, id: "DF4CA8E2-BF22-50FC-8C94-BDB45C58A1F5"),
        Vector(scope: "bundle", name: "Homozygous", ordinal: 1,
               array: #"["bundle","Homozygous"]"#, id: "5FD26AEC-1025-5049-AE30-F43C219E9A7A"),
        Vector(scope: "bundle", name: "Recombinants", ordinal: 1,
               array: #"["bundle","Recombinants"]"#, id: "048C9D06-A36A-5243-BEEC-7F2F591D780A"),
        Vector(scope: "bundle", name: "Errors at MHC-A", ordinal: 1,
               array: #"["bundle","Errors at MHC-A"]"#, id: "3C5638B5-3D64-5064-AC68-20AE371E14D2"),
        Vector(scope: "bundle", name: "Errors at MHC-A", ordinal: 2,
               array: #"["bundle","Errors at MHC-A",2]"#, id: "8E1DCABA-DFBD-53C8-ADAF-9AD629D5260A"),
        Vector(scope: "bundle", name: "Errors at MHC-A", ordinal: 3,
               array: #"["bundle","Errors at MHC-A",3]"#, id: "A93ED129-7806-592E-81B8-66FBF6128A02"),
        Vector(scope: "user", name: "Errors at MHC-A", ordinal: 1,
               array: #"["user","Errors at MHC-A"]"#, id: "BCB2419C-DE8D-5124-9463-9E07F479276A"),
        Vector(scope: "bundle", name: #"Filter: "quoted" back\slash"#, ordinal: 1,
               array: #"["bundle","Filter: \"quoted\" back\\slash"]"#, id: "09F80CB8-92AE-54FE-BC42-148509B90D65"),
        Vector(scope: "bundle", name: "Filter: A/B", ordinal: 1,
               array: #"["bundle","Filter: A/B"]"#, id: "B17289AB-800B-5F6E-B556-EDE7DB41003D"),
        Vector(scope: "bundle", name: "Caf\u{E9} \u{3B1} \u{2603}", ordinal: 1,
               array: "[\"bundle\",\"Caf\u{E9} \u{3B1} \u{2603}\"]", id: "C66AD928-2DC0-5C41-9C7E-26776DB9BC02"),
        Vector(scope: "bundle", name: "tab\there", ordinal: 1,
               array: #"["bundle","tab\there"]"#, id: "740B32FA-8CCE-51E7-B59C-55F22752A9B5"),
        Vector(scope: "bundle", name: "ctl\u{1F}char", ordinal: 1,
               array: #"["bundle","ctl\u001fchar"]"#, id: "ECBFD0EC-67EF-52A9-85FF-9F2D2AF353CF"),
        Vector(scope: "", name: "", ordinal: 1,
               array: #"["",""]"#, id: "8CA8AAEB-7D4D-5412-9BEF-44DF9F003688"),
    ]

    private func cohort(_ name: String, scope: String = "bundle", id: UUID? = nil) -> Filter {
        Filter(name: name, scope: scope, predicate: .hasAnyComment, id: id)
    }

    // MARK: - The derivation

    func testTheNamespaceNeverChanges() {
        XCTAssertEqual(Filter.derivationNamespace.uuidString, "EAE6B16C-E0F3-4099-B3D7-DB52CED9199C")
    }

    func testTheDerivationInputIsTheCompactJSONArrayWithTheMinimalEscapes() {
        for vector in Self.vectors {
            XCTAssertEqual(
                String(decoding: Filter.derivationInput(scope: vector.scope, name: vector.name, ordinal: vector.ordinal), as: UTF8.self),
                vector.array,
                "\(vector.name) \(vector.ordinal)"
            )
        }
    }

    func testDerivedIDsEqualPythonUUID5OfThatArray() {
        for vector in Self.vectors {
            let derived = Filter.derivedID(scope: vector.scope, name: vector.name, ordinal: vector.ordinal)
            XCTAssertEqual(derived.uuidString, vector.id, "\(vector.name) \(vector.ordinal)")
        }
    }

    func testADerivedIDIsAVersionFiveRFC4122UUID() {
        for vector in Self.vectors {
            let text = Filter.derivedID(scope: vector.scope, name: vector.name, ordinal: vector.ordinal).uuidString
            let characters = Array(text)
            XCTAssertEqual(characters[14], "5", "version nibble of \(text)")
            XCTAssertTrue("89AB".contains(characters[19]), "variant bits of \(text)")
        }
    }

    func testAnOrdinalBelowTwoDerivesFromTheTwoElementArray() {
        let first = Filter.derivedID(scope: "bundle", name: "Homozygous", ordinal: 1)
        XCTAssertEqual(Filter.derivedID(scope: "bundle", name: "Homozygous"), first)
        XCTAssertEqual(Filter.derivedID(scope: "bundle", name: "Homozygous", ordinal: 0), first)
        XCTAssertNotEqual(Filter.derivedID(scope: "bundle", name: "Homozygous", ordinal: 2), first)
    }

    // MARK: - Resolving the ids of one sidecar

    func testTheNthCohortOfOneScopeAndNameDerivesFromTheCountedArray() {
        let cohorts = [cohort("Errors"), cohort("Other"), cohort("Errors"), cohort("Errors", scope: "user"), cohort("Errors")]

        let ids = Filter.resolvedIDs(of: cohorts)

        XCTAssertEqual(ids, [
            Filter.derivedID(scope: "bundle", name: "Errors", ordinal: 1),
            Filter.derivedID(scope: "bundle", name: "Other", ordinal: 1),
            Filter.derivedID(scope: "bundle", name: "Errors", ordinal: 2),
            Filter.derivedID(scope: "user", name: "Errors", ordinal: 1),
            Filter.derivedID(scope: "bundle", name: "Errors", ordinal: 3),
        ])
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testResolvingNeverChangesTheCohortsAndAStoredIDWins() {
        let stored = UUID(uuidString: "6A1F0C52-3B7D-4E0A-9C58-0D2B7E41A9F3")!
        let cohorts = [cohort("Errors", id: stored), cohort("Errors")]

        let ids = Filter.resolvedIDs(of: cohorts)

        XCTAssertEqual(ids[0], stored)
        XCTAssertEqual(ids[1], Filter.derivedID(scope: "bundle", name: "Errors", ordinal: 2), "a stored cohort holds its place in the count")
        XCTAssertNil(cohorts[1].id, "reading derives and never stores")
    }

    func testADerivedIDThatEqualsAStoredIDMovesToTheNextPlace() {
        let secondPlaceID = Filter.derivedID(scope: "bundle", name: "Errors", ordinal: 2)
        let cohorts = [cohort("Errors", id: secondPlaceID), cohort("Errors"), cohort("Errors")]

        let ids = Filter.resolvedIDs(of: cohorts)

        XCTAssertEqual(ids[0], secondPlaceID)
        XCTAssertEqual(ids[1], Filter.derivedID(scope: "bundle", name: "Errors", ordinal: 3), "its own place 2 is taken by the stored id")
        XCTAssertEqual(ids[2], Filter.derivedID(scope: "bundle", name: "Errors", ordinal: 4), "its own place 3 is taken by the one before")
        XCTAssertEqual(Set(ids).count, 3)
    }

    func testTheSidecarResolvesItsCohortsInOrder() {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-11T00:00:00Z")
        sidecar.smartCohorts = [cohort("Homozygous"), cohort("Recombinants")]

        XCTAssertEqual(sidecar.resolvedSmartCohortIDs.map(\.uuidString), [
            "5FD26AEC-1025-5049-AE30-F43C219E9A7A",
            "048C9D06-A36A-5243-BEEC-7F2F591D780A",
        ])
        XCTAssertEqual(sidecar.smartCohorts.map(\.id), [nil, nil], "reading stores nothing")
    }

    // MARK: - Storing the derived ids at a save

    func testStoringKeepsEveryStoredIDStoresTheDerivedOnesAndIsIdempotent() {
        let stored = UUID(uuidString: "6A1F0C52-3B7D-4E0A-9C58-0D2B7E41A9F3")!
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-11T00:00:00Z")
        sidecar.smartCohorts = [cohort("Homozygous"), cohort("Errors", id: stored), cohort("Homozygous")]
        let resolved = sidecar.resolvedSmartCohortIDs

        sidecar.storeSmartCohortIDs()

        XCTAssertEqual(sidecar.smartCohorts.map(\.id), resolved.map { Optional($0) })
        XCTAssertEqual(sidecar.smartCohorts[1].id, stored)
        let once = sidecar
        sidecar.storeSmartCohortIDs()
        XCTAssertEqual(sidecar, once)
        XCTAssertEqual(once.storingSmartCohortIDs(), once)
    }

    func testStoringBeforeARenameKeepsTheIDAndRenamingFirstChangesTheDerivedOne() {
        var unsaved = GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-11T00:00:00Z")
        unsaved.smartCohorts = [cohort("Homozygous"), cohort("Recombinants")]
        let original = unsaved.resolvedSmartCohortIDs

        var saved = unsaved.storingSmartCohortIDs()
        saved.smartCohorts[0].name = "Homozygous (strict)"
        unsaved.smartCohorts[0].name = "Homozygous (strict)"

        XCTAssertEqual(saved.resolvedSmartCohortIDs, original, "stored before the rename, so the rename changes no id")
        XCTAssertNotEqual(unsaved.resolvedSmartCohortIDs[0], original[0], "an id never stored follows the name, which is why a save stores it first")
        XCTAssertEqual(unsaved.resolvedSmartCohortIDs[1], original[1])
    }

    func testDeletingACohortChangesNoOtherIDOfAStoredSidecar() {
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-11T00:00:00Z")
        sidecar.smartCohorts = [cohort("Errors"), cohort("Errors"), cohort("Other")]
        sidecar.storeSmartCohortIDs()
        let before = sidecar.resolvedSmartCohortIDs

        sidecar.smartCohorts.removeFirst()

        XCTAssertEqual(sidecar.resolvedSmartCohortIDs, Array(before.dropFirst()), "the second of two keeps the id of its place 2")
    }

    func testInheritingTheIDOfTheReplacedCohort() {
        let stored = UUID(uuidString: "6A1F0C52-3B7D-4E0A-9C58-0D2B7E41A9F3")!
        let own = UUID(uuidString: "0C3E8A41-5B6D-4F7A-8E92-1D4C7B2A6F05")!

        XCTAssertEqual(cohort("Errors").inheritingID(from: cohort("Errors", id: stored)).id, stored)
        XCTAssertEqual(cohort("Errors", id: own).inheritingID(from: cohort("Errors", id: stored)).id, own)
        XCTAssertNil(cohort("Errors").inheritingID(from: cohort("Errors")).id)
        XCTAssertNil(cohort("Errors").inheritingID(from: nil).id)
    }

    // MARK: - The sidecar file

    func testTheIDRoundTripsThroughTheSidecarFile() throws {
        let stored = UUID(uuidString: "6A1F0C52-3B7D-4E0A-9C58-0D2B7E41A9F3")!
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-10-11T00:00:00Z")
        sidecar.smartCohorts = [cohort("Errors", id: stored), cohort("Other")]

        let data = try sidecar.encoded()
        let decoded = try GenotypeAnnotationSidecar.decode(data)

        XCTAssertEqual(decoded, sidecar)
        XCTAssertEqual(decoded.smartCohorts.map(\.id), [stored, nil])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cohorts = try XCTUnwrap(object["smartCohorts"] as? [[String: Any]])
        XCTAssertEqual(cohorts[0]["id"] as? String, stored.uuidString, "the key is `id` and the text is the UUID")
        XCTAssertNil(cohorts[1]["id"], "a cohort that stores none writes no key")
        XCTAssertEqual(try decoded.encoded(), data)
    }

    func testASidecarWrittenBeforeCohortIDsReadsWithNoneAndWritesNoKey() throws {
        let older = """
        {"schemaVersion":4,"generatedAt":"2026-05-22T10:00:00Z",
         "smartCohorts":[{"name":"Errors","scope":"bundle","isStarred":true,
                          "predicate":{"kind":"hasErrorAt","locus":"MHC-A"}}]}
        """

        let sidecar = try GenotypeAnnotationSidecar.decode(Data(older.utf8))

        XCTAssertEqual(sidecar.smartCohorts.count, 1)
        XCTAssertNil(sidecar.smartCohorts[0].id)
        let rewritten = try sidecar.encoded()
        XCTAssertFalse(String(decoding: rewritten, as: UTF8.self).contains("\"id\""))
        XCTAssertEqual(try GenotypeAnnotationSidecar.decode(rewritten), sidecar)
        XCTAssertEqual(sidecar.resolvedSmartCohortIDs, [Filter.derivedID(scope: "bundle", name: "Errors")])
    }
}
