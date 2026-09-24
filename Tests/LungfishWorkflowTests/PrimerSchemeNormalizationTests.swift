import XCTest
@testable import LungfishWorkflow

final class PrimerSchemeNormalizationTests: XCTestCase {
    private let analysisID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let runID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let resultID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let inputID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let targetID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private let assayID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private let forwardID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    private let reverseID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    private let probeID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

    func testValidTiledResultUsesZeroBasedHalfOpenCoordinates() throws {
        let document = makeDocument(mode: .tiled)
        XCTAssertNoThrow(try document.validateStructure(
            knownInputIDs: [inputID], options: tiledOptions,
            projections: ["maps/target.json": projection()]))
    }

    func testAlternativeQPCRAssayRetainsReverseProbe() throws {
        let document = makeDocument(mode: .qpcr, status: .alternative, rank: 2,
                                    includeProbe: true, probeStrand: .reverse)
        try document.validateStructure(
            knownInputIDs: [inputID], options: qpcrOptions,
            projections: ["maps/target.json": projection()])
        let target = try XCTUnwrap(document.results.first?.targets.first)
        XCTAssertEqual(target.assays.first?.status, .alternative)
        XCTAssertEqual(target.oligos.first(where: { $0.role == .probe })?.strand, .reverse)
    }

    func testRejectsAssaySpanOutsideRequestedBounds() {
        let document = makeDocument(mode: .tiled, assayStart: 10, assayEnd: 71)
        XCTAssertThrowsError(try document.validateStructure(
            knownInputIDs: [inputID], options: tiledOptions,
            projections: ["maps/target.json": projection()]))
    }

    func testRejectsMalformedProjectionWithOverlappingGeneratedBlocks() {
        let malformed = PrimerBindingProjection(
            sourceInputID: inputID, sourcePath: "/run/input.fasta",
            generatedReferencePath: "generated/reference.fasta",
            sourceLength: 100, generatedLength: 100,
            blocks: [
                .init(generatedStart: 0, generatedEnd: 60, sourceStart: 0,
                      sourceEnd: 60, kind: .mapped),
                .init(generatedStart: 50, generatedEnd: 100, sourceStart: 50,
                      sourceEnd: 100, kind: .mapped),
            ])
        XCTAssertThrowsError(try makeDocument(mode: .tiled).validateStructure(
            knownInputIDs: [inputID], options: tiledOptions,
            projections: ["maps/target.json": malformed]))
    }

    func testAcceptsEqualWidthCollapsedBlockWithoutClaimingBijection() throws {
        let projection = PrimerBindingProjection(
            sourceInputID: inputID, sourcePath: "/run/input.fasta",
            generatedReferencePath: "generated/reference.fasta",
            sourceLength: 100, generatedLength: 100,
            blocks: [
                .init(generatedStart: 0, generatedEnd: 50, sourceStart: 0,
                      sourceEnd: 50, kind: .mapped),
                .init(generatedStart: 50, generatedEnd: 51, sourceStart: 50,
                      sourceEnd: 51, kind: .collapsed),
                .init(generatedStart: 51, generatedEnd: 100, sourceStart: 51,
                      sourceEnd: 100, kind: .mapped),
            ])
        XCTAssertNoThrow(try makeDocument(mode: .tiled).validateStructure(
            knownInputIDs: [inputID], options: tiledOptions,
            projections: ["maps/target.json": projection]))
    }

    func testAcceptsZeroWidthCollapsedBlockForRemovedSourceColumns() throws {
        let projection = PrimerBindingProjection(
            sourceInputID: inputID, sourcePath: "/run/input.fasta",
            generatedReferencePath: "generated/reference.fasta",
            sourceLength: 101, generatedLength: 100,
            blocks: [
                .init(generatedStart: 0, generatedEnd: 50, sourceStart: 0,
                      sourceEnd: 50, kind: .mapped),
                .init(generatedStart: 50, generatedEnd: 50, sourceStart: 50,
                      sourceEnd: 51, kind: .collapsed),
                .init(generatedStart: 50, generatedEnd: 100, sourceStart: 51,
                      sourceEnd: 101, kind: .mapped),
            ])
        XCTAssertNoThrow(try makeDocument(mode: .tiled).validateStructure(
            knownInputIDs: [inputID], options: tiledOptions,
            projections: ["maps/target.json": projection]))
    }

    func testRejectsQPCRAssayWithoutProbe() {
        let document = makeDocument(mode: .qpcr, includeProbe: false)
        XCTAssertThrowsError(try document.validateStructure(
            knownInputIDs: [inputID], options: qpcrOptions,
            projections: ["maps/target.json": projection()])) { error in
            XCTAssertTrue(error.localizedDescription.lowercased().contains("probe"))
        }
    }

    func testRejectsInputIdentityNotOwnedByResult() {
        let unknown = UUID()
        let target = makeTarget(mode: .tiled, sourceInputID: unknown)
        let document = makeDocument(mode: .tiled, targets: [target])
        XCTAssertThrowsError(try document.validateStructure(
            knownInputIDs: [inputID, unknown], options: tiledOptions,
            projections: ["maps/target.json": projection(sourceInputID: unknown)]))
    }

    func testRejectsDuplicateOligoNamesEvenWhenIDsDiffer() {
        var target = makeTarget(mode: .tiled)
        let duplicate = PrimerSchemeOligo(
            id: UUID(), name: "LEFT_1", role: .forward, sequence: "ACGTACGTAC",
            start: 20, end: 30, strand: .forward, assayIDs: [assayID], pool: "1",
            nativeMetadata: [:])
        target = target.replacing(oligos: target.oligos + [duplicate],
                                  assays: [target.assays[0].replacing(
                                    memberIDs: target.assays[0].memberIDs + [duplicate.id])])
        XCTAssertThrowsError(try makeDocument(mode: .tiled, targets: [target]).validateStructure(
            knownInputIDs: [inputID], options: tiledOptions,
            projections: ["maps/target.json": projection()]))
    }

    func testAcceptsRepeatedNativeNamesAcrossIndependentTargets() throws {
        let secondInputID = UUID()
        let secondAssayID = UUID()
        let secondForwardID = UUID()
        let secondReverseID = UUID()
        let secondTarget = PrimerSchemeTarget(
            id: UUID(), label: "second", referencePath: "generated/second.fasta",
            referenceID: "second-ref", referenceLength: 100,
            sourceInputID: secondInputID,
            bindingProjectionPath: "maps/second.json",
            assays: [.init(
                id: secondAssayID, start: 10, end: 90,
                memberIDs: [secondForwardID, secondReverseID], pool: "1",
                status: .selected, rank: nil, nativeMetadata: [:])],
            oligos: [
                .init(id: secondForwardID, name: "LEFT_1", role: .forward,
                      sequence: "ACGTACGTAC", start: 10, end: 20,
                      strand: .forward, assayIDs: [secondAssayID], pool: "1",
                      nativeMetadata: [:]),
                .init(id: secondReverseID, name: "RIGHT_1", role: .reverse,
                      sequence: "TGCATGCATG", start: 80, end: 90,
                      strand: .reverse, assayIDs: [secondAssayID], pool: "1",
                      nativeMetadata: [:]),
            ])
        let document = PrimerSchemeResultsDocument(
            analysisID: analysisID, runID: runID, resultID: resultID,
            engine: .varvamp, engineVersion: "1.3.2", adapterVersion: "1.0.0",
            mode: .tiled, resolvedOptions: [:],
            results: [
                .init(id: resultID, inputIDs: [inputID],
                      targets: [makeTarget(mode: .tiled)]),
                .init(id: UUID(), inputIDs: [secondInputID], targets: [secondTarget]),
            ], artifacts: [], provenancePath: "provenance-v1.json")

        XCTAssertNoThrow(try document.validateStructure(
            knownInputIDs: [inputID, secondInputID], options: tiledOptions,
            projections: [
                "maps/target.json": projection(),
                "maps/second.json": projection(
                    sourceInputID: secondInputID,
                    generatedReferencePath: "generated/second.fasta"),
            ]))
    }

    func testRejectsProbeBorrowedFromAnotherTarget() {
        let otherInputID = UUID()
        let otherTargetID = UUID()
        let borrowedProbe = PrimerSchemeOligo(
            id: probeID, name: "PROBE_other", role: .probe, sequence: "ACGTRYSWKM",
            start: 40, end: 50, strand: .forward, assayIDs: [assayID], pool: nil,
            nativeMetadata: [:])
        let other = PrimerSchemeTarget(
            id: otherTargetID, label: "other", referencePath: "generated/other.fasta",
            referenceID: "other-ref", referenceLength: 100, sourceInputID: otherInputID,
            bindingProjectionPath: "maps/other.json", assays: [], oligos: [borrowedProbe])
        let first = makeTarget(mode: .qpcr, includeProbe: false,
                               assayMemberIDs: [forwardID, probeID, reverseID])
        let document = makeDocument(mode: .qpcr, inputIDs: [inputID, otherInputID],
                                    targets: [first, other])
        XCTAssertThrowsError(try document.validateStructure(
            knownInputIDs: [inputID, otherInputID], options: qpcrOptions,
            projections: [
                "maps/target.json": projection(),
                "maps/other.json": projection(sourceInputID: otherInputID,
                                                generatedReferencePath: "generated/other.fasta"),
            ]))
    }

    func testRejectsNonIUPACOligoSequence() {
        var target = makeTarget(mode: .tiled)
        let invalid = target.oligos[0].replacing(sequence: "ACGTZCGTAC")
        target = target.replacing(oligos: [invalid, target.oligos[1]])
        XCTAssertThrowsError(try makeDocument(mode: .tiled, targets: [target]).validateStructure(
            knownInputIDs: [inputID], options: tiledOptions,
            projections: ["maps/target.json": projection()]))
    }

    private var tiledOptions: PrimerSchemeDesignOptions {
        .init(engine: .varvamp, mode: .tiled, grouping: .independent,
              nominalAmpliconLength: 80, minimumAmpliconLength: 70,
              maximumAmpliconLength: 90, workers: 1, varvamp: .init())
    }

    private var qpcrOptions: PrimerSchemeDesignOptions {
        .init(engine: .varvamp, mode: .qpcr, grouping: .independent,
              nominalAmpliconLength: 80, minimumAmpliconLength: 70,
              maximumAmpliconLength: 90, workers: 1,
              varvamp: .init(cumulativeConsensusThreshold: 0.9))
    }

    private func makeDocument(
        mode: PrimerSchemeMode, status: PrimerAssayStatus = .selected, rank: Int? = nil,
        includeProbe: Bool = false, probeStrand: PrimerOligoStrand = .forward,
        assayStart: Int = 10, assayEnd: Int = 90, inputIDs: [UUID]? = nil,
        targets: [PrimerSchemeTarget]? = nil
    ) -> PrimerSchemeResultsDocument {
        PrimerSchemeResultsDocument(
            analysisID: analysisID, runID: runID, resultID: resultID,
            engine: .varvamp, engineVersion: "1.3.2", adapterVersion: "1.0.0",
            mode: mode, resolvedOptions: [:],
            results: [.init(id: resultID, inputIDs: inputIDs ?? [inputID],
                            targets: targets ?? [makeTarget(
                                mode: mode, status: status, rank: rank,
                                includeProbe: includeProbe, probeStrand: probeStrand,
                                assayStart: assayStart, assayEnd: assayEnd)])],
            artifacts: [], provenancePath: "provenance-v1.json")
    }

    private func makeTarget(
        mode: PrimerSchemeMode, sourceInputID: UUID? = nil,
        status: PrimerAssayStatus = .selected, rank: Int? = nil,
        includeProbe: Bool = false, probeStrand: PrimerOligoStrand = .forward,
        assayStart: Int = 10, assayEnd: Int = 90,
        assayMemberIDs: [UUID]? = nil
    ) -> PrimerSchemeTarget {
        var oligos = [
            PrimerSchemeOligo(id: forwardID, name: "LEFT_1", role: .forward,
                              sequence: "ACGTACGTAC", start: 10, end: 20,
                              strand: .forward, assayIDs: [assayID], pool: mode == .tiled ? "1" : nil,
                              nativeMetadata: [:]),
            PrimerSchemeOligo(id: reverseID, name: "RIGHT_1", role: .reverse,
                              sequence: "TGCATGCATG", start: 80, end: 90,
                              strand: .reverse, assayIDs: [assayID], pool: mode == .tiled ? "1" : nil,
                              nativeMetadata: [:]),
        ]
        if includeProbe {
            oligos.append(.init(id: probeID, name: "PROBE_1", role: .probe,
                                sequence: "ACGTRYSWKM", start: 40, end: 50,
                                strand: probeStrand, assayIDs: [assayID], pool: nil,
                                nativeMetadata: [:]))
        }
        let members = assayMemberIDs ?? oligos.map(\.id)
        return PrimerSchemeTarget(
            id: targetID, label: "target", referencePath: "generated/reference.fasta",
            referenceID: "generated-ref", referenceLength: 100,
            sourceInputID: sourceInputID ?? inputID,
            bindingProjectionPath: "maps/target.json",
            assays: [.init(id: assayID, start: assayStart, end: assayEnd,
                           memberIDs: members, pool: mode == .tiled ? "1" : nil,
                           status: status, rank: rank, nativeMetadata: [:])],
            oligos: oligos)
    }

    private func projection(
        sourceInputID: UUID? = nil,
        generatedReferencePath: String = "generated/reference.fasta"
    ) -> PrimerBindingProjection {
        PrimerBindingProjection(
            sourceInputID: sourceInputID ?? inputID, sourcePath: "/run/input.fasta",
            generatedReferencePath: generatedReferencePath,
            sourceLength: 100, generatedLength: 100,
            blocks: [.init(generatedStart: 0, generatedEnd: 100, sourceStart: 0,
                           sourceEnd: 100, kind: .mapped)])
    }
}

private extension PrimerSchemeTarget {
    func replacing(
        oligos: [PrimerSchemeOligo]? = nil,
        assays: [PrimerSchemeAssay]? = nil
    ) -> PrimerSchemeTarget {
        .init(id: id, label: label, referencePath: referencePath, referenceID: referenceID,
              referenceLength: referenceLength, sourceInputID: sourceInputID,
              bindingProjectionPath: bindingProjectionPath, assays: assays ?? self.assays,
              oligos: oligos ?? self.oligos)
    }
}

private extension PrimerSchemeAssay {
    func replacing(memberIDs: [UUID]) -> PrimerSchemeAssay {
        .init(id: id, start: start, end: end, memberIDs: memberIDs, pool: pool,
              status: status, rank: rank, nativeMetadata: nativeMetadata)
    }
}

private extension PrimerSchemeOligo {
    func replacing(sequence: String) -> PrimerSchemeOligo {
        .init(id: id, name: name, role: role, sequence: sequence, start: start, end: end,
              strand: strand, assayIDs: assayIDs, pool: pool, nativeMetadata: nativeMetadata)
    }
}
