import XCTest
@testable import LungfishWorkflow

final class PrimerSchemeOrderSheetTests: XCTestCase {
  func testSelectedAssayIncludesItsReverseProbeAndExcludesAlternative() throws {
    let fixture = makeDocument()
    let rows = try PrimerSchemeOrderSheet.rows(from: fixture.document,
      selection: .selectedAssays([fixture.selectedAssay]))
    XCTAssertEqual(rows.count, 3)
    XCTAssertEqual(rows.map(\.role), [.forward, .probe, .reverse])
    XCTAssertEqual(rows.first { $0.role == .probe }?.strand, .reverse)
    XCTAssertTrue(rows.allSatisfy { $0.assayID == fixture.selectedAssay && $0.status == .selected })
  }

  func testAllAssaysKeepsAlternativesLabeledAndPoolsNullable() throws {
    let fixture = makeDocument()
    let rows = try PrimerSchemeOrderSheet.rows(from: fixture.document, selection: .allAssays)
    XCTAssertEqual(rows.count, 6)
    XCTAssertEqual(rows.filter { $0.status == .selected }.count, 3)
    XCTAssertEqual(rows.filter { $0.status == .alternative }.count, 3)
    XCTAssertTrue(rows.allSatisfy { $0.nativePool == nil })
    XCTAssertEqual(Set(rows.map(\.assayID)), Set([fixture.selectedAssay, fixture.alternativeAssay]))
  }

  func testExplicitEmptySelectionIsRejectedInsteadOfUsingVisibleRows() {
    let fixture = makeDocument()
    XCTAssertThrowsError(try PrimerSchemeOrderSheet.rows(from: fixture.document,
      selection: .selectedAssays([])))
  }

  private func makeDocument() ->
    (document: PrimerSchemeResultsDocument, selectedAssay: UUID, alternativeAssay: UUID) {
    let inputID = UUID(), resultID = UUID(), targetID = UUID()
    let selected = UUID(), alternative = UUID()
    var oligos: [PrimerSchemeOligo] = []
    for (index, assay) in [selected, alternative].enumerated() {
      let start = index * 80
      oligos += [
        .init(id: UUID(), name: "left-\(index)", role: .forward, sequence: "AAAA",
          start: start, end: start + 4, strand: .forward, assayIDs: [assay], pool: nil, nativeMetadata: [:]),
        .init(id: UUID(), name: "probe-\(index)", role: .probe, sequence: "TTTT",
          start: start + 20, end: start + 24, strand: .reverse, assayIDs: [assay], pool: nil, nativeMetadata: [:]),
        .init(id: UUID(), name: "right-\(index)", role: .reverse, sequence: "CCCC",
          start: start + 66, end: start + 70, strand: .reverse, assayIDs: [assay], pool: nil, nativeMetadata: [:]),
      ]
    }
    let assays = [selected, alternative].enumerated().map { index, assay in
      PrimerSchemeAssay(id: assay, start: index * 80, end: index * 80 + 70,
        memberIDs: oligos.filter { $0.assayIDs == [assay] }.map(\.id), pool: nil,
        status: index == 0 ? .selected : .alternative, rank: index, nativeMetadata: [:])
    }
    let target = PrimerSchemeTarget(id: targetID, label: "target", referencePath: "native/reference.fasta",
      referenceID: "reference", referenceLength: 160, sourceInputID: inputID,
      bindingProjectionPath: "results/map.json", assays: assays, oligos: oligos)
    return (.init(analysisID: UUID(), runID: UUID(), resultID: resultID, engine: .varvamp,
      engineVersion: "1.3.2", adapterVersion: "1.0.0", mode: .qpcr,
      resolvedOptions: [:], results: [.init(id: resultID, inputIDs: [inputID], targets: [target])],
      artifacts: [], provenancePath: "native/provenance-v1.json"), selected, alternative)
  }
}
