import Foundation
import XCTest
@testable import LungfishIO

final class HaplotypeDefinitionLibraryProjectScopeTests: XCTestCase {
    func testRecordsReturnsOnlyProjectBundleRecords() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaploLib-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: projectRoot) }
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        let library = HaplotypeDefinitionLibrary(projectRoot: projectRoot)
        XCTAssertTrue(library.records().isEmpty)
        for record in library.records() {
            XCTAssertEqual(record.scope, .project)
            XCTAssertNotNil(record.referenceFASTAURL)
        }
    }

    func testHaplotypeDefinitionScopeHasOnlyProjectCase() {
        XCTAssertEqual(HaplotypeDefinitionScope.allCases, [.project])
    }

    /// A bare definition that `haplotypes import` wrote under the project's
    /// `Haplotype Definitions/` folder is what `haplotypes list` shows
    /// (`allManagedRecords`). The GUI list (`records()`) stays bundle-only,
    /// but a resolver asked to include the project store must find it, so
    /// `genotype-cohort --haplotype-definition <id>` resolves the same set.
    func testProjectStoreDefinitionResolvesWhenTheProjectStoreIsIncluded() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaploLibStore-\(UUID().uuidString).lungfish", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: projectRoot) }
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        let definition = GenotypeHaplotypeDefinitionSet(
            id: "MHC-exon2-miSeq.mcm.bare",
            assayID: "MHC-exon2-miSeq",
            displayName: "MCM bare",
            speciesName: "Mauritian cynomolgus macaque",
            speciesCode: "MCM",
            prefix: "Mafa",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-A",
                    sourceLocus: "MHC-A",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "M1A", diagnosticAlleles: ["A1"], minimumMatches: 1)
                    ]
                )
            ]
        )
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(definition)

        let library = HaplotypeDefinitionLibrary(projectRoot: projectRoot)
        XCTAssertTrue(library.records().isEmpty, "the GUI list stays bundle-only")
        XCTAssertEqual(library.allManagedRecords().map(\.definitionSet.id), [definition.id])

        XCTAssertTrue(library.activeRecords(includeProjectStore: false).isEmpty)
        let resolved = library.activeRecords(
            assayID: definition.assayID,
            speciesCode: "MCM",
            scope: .project,
            includeProjectStore: true
        )
        XCTAssertEqual(resolved.map(\.definitionSet.id), [definition.id])
        XCTAssertNil(resolved.first?.referenceBundleURL)

        XCTAssertNil(library.mergedRegistry().definitionSet(id: definition.id))
        XCTAssertEqual(
            library.mergedRegistry(includeProjectStore: true).definitionSet(id: definition.id)?.id,
            definition.id
        )
        XCTAssertEqual(
            Set(library.resolvableRecords(includeProjectStore: true).map(\.definitionSet.id)),
            Set(library.allManagedRecords().map(\.definitionSet.id)),
            "the resolver sees exactly what `haplotypes list` shows"
        )
    }
}
