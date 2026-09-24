import XCTest
import LungfishWorkflow
@testable import LungfishApp

final class PrimerSchemeViewerTests: XCTestCase {
  func testQPCRAlternativesKeepRolesStatusAndUnpooledIdentity() throws {
    let fixture = makeQPCRFixture()
    let presentation = try PrimerSchemeViewerAdapter.adapt(document: fixture.document)
    let result = try XCTUnwrap(presentation.results.first)
    XCTAssertEqual(result.primers.count, 6)
    XCTAssertEqual(result.primers.filter { $0.role == .probe }.count, 2)
    XCTAssertTrue(result.primers.allSatisfy { $0.nativePool == nil && $0.poolLabel.hasPrefix("Unpooled ·") })

    let review = try XCTUnwrap(presentation.reviews.first)
    XCTAssertEqual(review.intervals.map(\.candidateStatus), [.selected, .alternative])
    XCTAssertEqual(review.intervals.map(\.rank), [1, 2])
    XCTAssertEqual(review.intervals.map(\.name), ["Selected assay", "Alternative assay 2"])
    XCTAssertEqual(review.primers.filter { $0.role == .probe }.map(\.strand), ["-", "-"])
    XCTAssertEqual(PrimerReferenceCoverageTrack.laneHeight(for: review), 102)
    XCTAssertEqual(Set(review.primers.flatMap(\.ampliconIDs)), Set(fixture.assayIDs.map { $0.uuidString.lowercased() }))
  }

  func testEqualWidthAndZeroWidthCollapsedBlocksRemainAuthoritative() throws {
    let fixture = makeQPCRFixture()
    let target = try XCTUnwrap(fixture.document.results.first?.targets.first)
    let forward = try XCTUnwrap(target.oligos.first { $0.role == .forward })
    let equalWidth = PrimerBindingProjection(sourceInputID: target.sourceInputID,
      sourcePath: "inputs/source.fasta", generatedReferencePath: target.referencePath,
      sourceLength: 200, generatedLength: 200,
      blocks: [.init(generatedStart: 0, generatedEnd: 4, sourceStart: 0, sourceEnd: 4, kind: .collapsed),
        .init(generatedStart: 4, generatedEnd: 200, sourceStart: 4, sourceEnd: 200, kind: .mapped)])
    guard case .unavailable = PrimerSchemeViewerAdapter.project(oligo: forward, through: equalWidth) else {
      return XCTFail("Collapsed kind must stay non-bijective even when interval widths match")
    }

    let anchor = PrimerBindingProjection(sourceInputID: target.sourceInputID,
      sourcePath: "inputs/source.fasta", generatedReferencePath: target.referencePath,
      sourceLength: 204, generatedLength: 200,
      blocks: [.init(generatedStart: 0, generatedEnd: 2, sourceStart: 0, sourceEnd: 2, kind: .mapped),
        .init(generatedStart: 2, generatedEnd: 2, sourceStart: 2, sourceEnd: 6, kind: .collapsed),
        .init(generatedStart: 2, generatedEnd: 200, sourceStart: 6, sourceEnd: 204, kind: .mapped)])
    guard case .unavailable = PrimerSchemeViewerAdapter.project(oligo: forward, through: anchor) else {
      return XCTFail("An oligo crossing a collapsed source anchor must be unavailable")
    }
    var boundary = forward
    boundary.start = 2
    boundary.end = 4
    guard case .exact(let start, let end) = PrimerSchemeViewerAdapter.project(oligo: boundary, through: anchor) else {
      return XCTFail("An oligo starting at the deleted-gap boundary maps on the adjacent exact side")
    }
    XCTAssertEqual([start, end], [6, 8])
  }

  func testAmbiguousOligoDoesNotInventSingleGCValue() {
    let primer = PrimalSchemeDisplayPrimer(id: 0, reference: "ref", referenceLabel: "ref",
      start: 0, end: 4, name: "ambiguous", pool: 1, strand: "+", sequence: "ACRN",
      referenceLength: 10)
    XCTAssertEqual(primer.gcLabel, "GC varies")
  }

  func testCollapsedProjectionNeverProducesMismatchStatistics() throws {
    let fixture = makeQPCRFixture(collapsedProbe: true)
    let target = try XCTUnwrap(fixture.document.results.first?.targets.first)
    let probe = try XCTUnwrap(target.oligos.first { $0.role == .probe })
    let projection = PrimerSchemeViewerAdapter.project(oligo: probe, through: fixture.projection)
    guard case .unavailable(let reason) = projection else {
      return XCTFail("A primer crossing a collapsed block must be unavailable")
    }
    XCTAssertTrue(reason.localizedCaseInsensitiveContains("collapsed"))

    let comparison = PrimerBindingInspectionContext.compare(id: 0, name: "source-row",
      row: Array(String(repeating: "A", count: probe.sequence.count)), lower: 0,
      upper: probe.sequence.count, primer: probe.sequence, strand: probe.strand.rawValue,
      contiguousReference: false)
    XCTAssertNil(comparison.mismatchCount)
    XCTAssertTrue(comparison.status.contains("Unavailable"))
  }

  private func makeQPCRFixture(collapsedProbe: Bool = false) ->
    (document: PrimerSchemeResultsDocument, projection: PrimerBindingProjection, assayIDs: [UUID]) {
    let inputID = UUID(), resultID = UUID(), targetID = UUID()
    let assays = [UUID(), UUID()]
    var oligos: [PrimerSchemeOligo] = []
    for (index, assayID) in assays.enumerated() {
      let base = index * 100
      oligos += [
        .init(id: UUID(), name: "candidate-\(index + 1)-left", role: .forward,
          sequence: "AAAA", start: base, end: base + 4, strand: .forward,
          assayIDs: [assayID], pool: nil, nativeMetadata: [:]),
        .init(id: UUID(), name: "candidate-\(index + 1)-probe", role: .probe,
          sequence: "TTTT", start: base + 20, end: base + 24, strand: .reverse,
          assayIDs: [assayID], pool: nil, nativeMetadata: [:]),
        .init(id: UUID(), name: "candidate-\(index + 1)-right", role: .reverse,
          sequence: "CCCC", start: base + 66, end: base + 70, strand: .reverse,
          assayIDs: [assayID], pool: nil, nativeMetadata: [:]),
      ]
    }
    let normalizedAssays = assays.enumerated().map { index, id in
      PrimerSchemeAssay(id: id, start: index * 100, end: index * 100 + 70,
        memberIDs: oligos.filter { $0.assayIDs == [id] }.map(\.id), pool: nil,
        status: index == 0 ? .selected : .alternative, rank: index + 1, nativeMetadata: [:])
    }
    let target = PrimerSchemeTarget(id: targetID, label: "qPCR target",
      referencePath: "native/reference.fasta", referenceID: "consensus", referenceLength: 200,
      sourceInputID: inputID, bindingProjectionPath: "results/map.json",
      assays: normalizedAssays, oligos: oligos)
    let blocks: [PrimerBindingProjectionBlock] = collapsedProbe
      ? [.init(generatedStart: 0, generatedEnd: 20, sourceStart: 0, sourceEnd: 20, kind: .mapped),
         .init(generatedStart: 20, generatedEnd: 24, sourceStart: 20, sourceEnd: 30, kind: .collapsed),
         .init(generatedStart: 24, generatedEnd: 200, sourceStart: 30, sourceEnd: 206, kind: .mapped)]
      : [.init(generatedStart: 0, generatedEnd: 200, sourceStart: 0, sourceEnd: 200, kind: .mapped)]
    let projection = PrimerBindingProjection(sourceInputID: inputID, sourcePath: "inputs/source.fasta",
      generatedReferencePath: "native/reference.fasta", sourceLength: collapsedProbe ? 206 : 200,
      generatedLength: 200, blocks: blocks)
    let document = PrimerSchemeResultsDocument(analysisID: UUID(), runID: UUID(), resultID: resultID,
      engine: .varvamp, engineVersion: "1.3.2", adapterVersion: "1.0.0", mode: .qpcr,
      resolvedOptions: [:], results: [.init(id: resultID, inputIDs: [inputID], targets: [target])],
      artifacts: [], provenancePath: "native/provenance-v1.json")
    return (document, projection, assays)
  }
}
