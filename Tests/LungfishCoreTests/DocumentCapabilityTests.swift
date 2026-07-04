// DocumentCapabilityTests.swift - Tests for the capability-based document system
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

final class DocumentCapabilityTests: XCTestCase {

    // MARK: - OptionSet Behavior Tests

    func testEmptyCapability() {
        let caps: DocumentCapability = .none
        XCTAssertEqual(caps.rawValue, 0)
        XCTAssertTrue(caps.isEmpty)
        XCTAssertFalse(caps.contains(.nucleotideSequence))
    }

    func testSingleCapability() {
        let caps: DocumentCapability = .nucleotideSequence
        XCTAssertEqual(caps.rawValue, 1)
        XCTAssertTrue(caps.contains(.nucleotideSequence))
        XCTAssertFalse(caps.contains(.qualityScores))
    }

    func testMultipleCapabilities() {
        let caps: DocumentCapability = [.nucleotideSequence, .qualityScores, .alignment]
        XCTAssertTrue(caps.contains(.nucleotideSequence))
        XCTAssertTrue(caps.contains(.qualityScores))
        XCTAssertTrue(caps.contains(.alignment))
        XCTAssertFalse(caps.contains(.annotations))
    }

    func testCapabilityUnion() {
        let caps1: DocumentCapability = [.nucleotideSequence, .qualityScores]
        let caps2: DocumentCapability = [.qualityScores, .alignment]
        let union = caps1.union(caps2)

        XCTAssertTrue(union.contains(.nucleotideSequence))
        XCTAssertTrue(union.contains(.qualityScores))
        XCTAssertTrue(union.contains(.alignment))
    }

    func testCapabilityIntersection() {
        let caps1: DocumentCapability = [.nucleotideSequence, .qualityScores, .annotations]
        let caps2: DocumentCapability = [.qualityScores, .alignment, .annotations]
        let intersection = caps1.intersection(caps2)

        XCTAssertFalse(intersection.contains(.nucleotideSequence))
        XCTAssertTrue(intersection.contains(.qualityScores))
        XCTAssertTrue(intersection.contains(.annotations))
        XCTAssertFalse(intersection.contains(.alignment))
    }

    func testCapabilitySubtracting() {
        let caps: DocumentCapability = [.nucleotideSequence, .qualityScores, .alignment]
        let toRemove: DocumentCapability = [.qualityScores]
        let result = caps.subtracting(toRemove)

        XCTAssertTrue(result.contains(.nucleotideSequence))
        XCTAssertFalse(result.contains(.qualityScores))
        XCTAssertTrue(result.contains(.alignment))
    }

    func testCapabilityContainment() {
        let requirements: DocumentCapability = [.nucleotideSequence, .annotations]
        let provided: DocumentCapability = [.nucleotideSequence, .annotations, .richMetadata]

        XCTAssertTrue(provided.contains(requirements), "Should satisfy all requirements")
        XCTAssertFalse(requirements.contains(provided), "Requirements should not contain extra capabilities")
    }

    // MARK: - Common Combination Tests

    func testAnnotatedSequenceCombination() {
        let caps = DocumentCapability.annotatedSequence

        XCTAssertTrue(caps.contains(.nucleotideSequence))
        XCTAssertTrue(caps.contains(.annotations))
        XCTAssertTrue(caps.contains(.richMetadata))
        XCTAssertFalse(caps.contains(.qualityScores))
    }

    func testSequencingReadsCombination() {
        let caps = DocumentCapability.sequencingReads

        XCTAssertTrue(caps.contains(.nucleotideSequence))
        XCTAssertTrue(caps.contains(.qualityScores))
        XCTAssertFalse(caps.contains(.alignment))
    }

    func testAlignedReadsCombination() {
        let caps = DocumentCapability.alignedReads

        XCTAssertTrue(caps.contains(.nucleotideSequence))
        XCTAssertTrue(caps.contains(.qualityScores))
        XCTAssertTrue(caps.contains(.alignment))
        XCTAssertFalse(caps.contains(.sorted))
    }

    func testAnalysisReadyAlignmentCombination() {
        let caps = DocumentCapability.analysisReadyAlignment

        XCTAssertTrue(caps.contains(.nucleotideSequence))
        XCTAssertTrue(caps.contains(.qualityScores))
        XCTAssertTrue(caps.contains(.alignment))
        XCTAssertTrue(caps.contains(.sorted))
        XCTAssertTrue(caps.contains(.indexed))
    }

    // MARK: - Description Tests

    func testDescriptionEmpty() {
        let caps: DocumentCapability = .none
        XCTAssertEqual(caps.description, "DocumentCapability(none)")
    }

    func testDescriptionSingle() {
        let caps: DocumentCapability = .nucleotideSequence
        XCTAssertEqual(caps.description, "DocumentCapability([nucleotideSequence])")
    }

    func testDescriptionMultiple() {
        let caps: DocumentCapability = [.nucleotideSequence, .qualityScores]
        XCTAssertTrue(caps.description.contains("nucleotideSequence"))
        XCTAssertTrue(caps.description.contains("qualityScores"))
    }

    func testDisplayName() {
        let caps: DocumentCapability = [.nucleotideSequence, .annotations]
        let displayName = caps.displayName

        XCTAssertTrue(displayName.contains("Nucleotide Sequences"))
        XCTAssertTrue(displayName.contains("Annotations"))
    }

    func testShortLabel() {
        XCTAssertEqual(DocumentCapability.nucleotideSequence.shortLabel, "DNA/RNA")
        XCTAssertEqual(DocumentCapability.aminoAcidSequence.shortLabel, "Protein")
        XCTAssertEqual(DocumentCapability.qualityScores.shortLabel, "Quality")
        XCTAssertEqual(DocumentCapability.annotations.shortLabel, "Annot")
    }

    // MARK: - Individual Capabilities Tests

    func testIndividualCapabilities() {
        let caps: DocumentCapability = [.nucleotideSequence, .qualityScores, .alignment]
        let individual = caps.individualCapabilities

        XCTAssertEqual(individual.count, 3)
        XCTAssertTrue(individual.contains(.nucleotideSequence))
        XCTAssertTrue(individual.contains(.qualityScores))
        XCTAssertTrue(individual.contains(.alignment))
    }

    // MARK: - Codable Tests

    func testCodableRoundTrip() throws {
        let original: DocumentCapability = [.nucleotideSequence, .qualityScores, .annotations]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(DocumentCapability.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    // MARK: - CapabilityProvider Tests

    func testDocumentCapabilityWrapperSatisfies() {
        let wrapper = DocumentCapabilityWrapper(capabilities: [.nucleotideSequence, .annotations])

        XCTAssertTrue(wrapper.satisfies(requirements: .nucleotideSequence))
        XCTAssertTrue(wrapper.satisfies(requirements: [.nucleotideSequence, .annotations]))
        XCTAssertFalse(wrapper.satisfies(requirements: .qualityScores))
    }

    func testDocumentCapabilityWrapperHasCapability() {
        let wrapper = DocumentCapabilityWrapper(capabilities: [.nucleotideSequence, .qualityScores])

        XCTAssertTrue(wrapper.hasCapability(.nucleotideSequence))
        XCTAssertTrue(wrapper.hasCapability(.qualityScores))
        XCTAssertFalse(wrapper.hasCapability(.alignment))
    }

    func testDocumentCapabilityWrapperMissingCapabilities() {
        let wrapper = DocumentCapabilityWrapper(capabilities: [.nucleotideSequence])
        let requirements: DocumentCapability = [.nucleotideSequence, .qualityScores, .annotations]
        let missing = wrapper.missingCapabilities(for: requirements)

        XCTAssertFalse(missing.contains(.nucleotideSequence))
        XCTAssertTrue(missing.contains(.qualityScores))
        XCTAssertTrue(missing.contains(.annotations))
    }

    // MARK: - CapabilityValidator Tests

    func testValidatorSatisfied() {
        let validator = CapabilityValidator(required: .nucleotideSequence)
        let wrapper = DocumentCapabilityWrapper(capabilities: [.nucleotideSequence, .annotations])

        let result = validator.validate(wrapper)
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.missingCapabilities.isEmpty)
    }

    func testValidatorUnsatisfied() {
        let validator = CapabilityValidator(required: [.nucleotideSequence, .qualityScores])
        let wrapper = DocumentCapabilityWrapper(capabilities: [.nucleotideSequence])

        let result = validator.validate(wrapper)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.missingCapabilities.contains(.qualityScores))
    }

    func testValidatorWithOptionalCapabilities() {
        let validator = CapabilityValidator(
            required: .nucleotideSequence,
            optional: .annotations
        )
        let wrapper = DocumentCapabilityWrapper(capabilities: [.nucleotideSequence])

        let result = validator.validate(wrapper)
        XCTAssertTrue(result.isValid, "Optional capabilities should not cause validation failure")
    }

    func testValidatorWithRequirements() {
        let requirements = [
            CapabilityRequirement(.nucleotideSequence, reason: "Required for BLAST"),
            CapabilityRequirement(.qualityScores, isRequired: false, fallbackBehavior: .warn)
        ]
        let validator = CapabilityValidator(requirements: requirements)
        let wrapper = DocumentCapabilityWrapper(capabilities: [.nucleotideSequence])

        let result = validator.validate(wrapper)
        XCTAssertTrue(result.isValid, "Only required capabilities should cause validation failure")
    }

    func testValidatorSuggestedActions() {
        let requirements = [
            CapabilityRequirement(.sorted),
            CapabilityRequirement(.indexed)
        ]
        let validator = CapabilityValidator(requirements: requirements)
        let wrapper = DocumentCapabilityWrapper(capabilities: .none)

        let result = validator.validate(wrapper)

        if case .unsatisfied(_, let details) = result {
            let sortedMismatch = details.first { $0.capability == .sorted }
            XCTAssertNotNil(sortedMismatch?.suggestedAction)
            XCTAssertTrue(sortedMismatch?.suggestedAction?.contains("samtools sort") ?? false)

            let indexedMismatch = details.first { $0.capability == .indexed }
            XCTAssertNotNil(indexedMismatch?.suggestedAction)
            XCTAssertTrue(indexedMismatch?.suggestedAction?.contains("samtools index") ?? false)
        } else {
            XCTFail("Expected unsatisfied result")
        }
    }

    // MARK: - CapabilityRequirement Tests

    func testCapabilityRequirementDefaults() {
        let requirement = CapabilityRequirement(.nucleotideSequence)

        XCTAssertEqual(requirement.capability, .nucleotideSequence)
        XCTAssertTrue(requirement.isRequired)
        XCTAssertNil(requirement.reason)
        XCTAssertEqual(requirement.fallbackBehavior, .error)
    }

    func testCapabilityRequirementCustom() {
        let requirement = CapabilityRequirement(
            .qualityScores,
            isRequired: false,
            reason: "Quality scores improve alignment accuracy",
            fallbackBehavior: .warn
        )

        XCTAssertEqual(requirement.capability, .qualityScores)
        XCTAssertFalse(requirement.isRequired)
        XCTAssertEqual(requirement.reason, "Quality scores improve alignment accuracy")
        XCTAssertEqual(requirement.fallbackBehavior, .warn)
    }

    // MARK: - Sequence Capabilities Tests

    func testDNASequenceCapabilities() throws {
        let sequence = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCG")
        let caps = sequence.capabilities

        XCTAssertTrue(caps.contains(.nucleotideSequence))
        XCTAssertFalse(caps.contains(.aminoAcidSequence))
        XCTAssertFalse(caps.contains(.qualityScores))
    }

    func testRNASequenceCapabilities() throws {
        let sequence = try Sequence(name: "test", alphabet: .rna, bases: "AUCGAUCG")
        let caps = sequence.capabilities

        XCTAssertTrue(caps.contains(.nucleotideSequence))
        XCTAssertFalse(caps.contains(.aminoAcidSequence))
    }

    func testProteinSequenceCapabilities() throws {
        let sequence = try Sequence(name: "test", alphabet: .protein, bases: "MKTLLILAVVAAALA")
        let caps = sequence.capabilities

        XCTAssertFalse(caps.contains(.nucleotideSequence))
        XCTAssertTrue(caps.contains(.aminoAcidSequence))
    }

    func testSequenceWithQualityScores() throws {
        let qualityScores: [UInt8] = [30, 30, 30, 30, 30, 30, 30, 30]
        let sequence = try Sequence(
            name: "test",
            alphabet: .dna,
            bases: "ATCGATCG",
            qualityScores: qualityScores
        )
        let caps = sequence.capabilities

        XCTAssertTrue(caps.contains(.nucleotideSequence))
        XCTAssertTrue(caps.contains(.qualityScores))
    }

    func testCircularSequenceCapabilities() throws {
        var sequence = try Sequence(name: "plasmid", alphabet: .dna, bases: "ATCGATCG")
        sequence.isCircular = true
        let caps = sequence.capabilities

        XCTAssertTrue(caps.contains(.nucleotideSequence))
        XCTAssertTrue(caps.contains(.circularTopology))
    }

    // MARK: - GenomicDocument Capabilities Tests

    @MainActor
    func testEmptyDocumentCapabilities() {
        let document = GenomicDocument(name: "empty")
        let caps = document.computeCapabilities()

        XCTAssertTrue(caps.isEmpty)
    }

    @MainActor
    func testDocumentWithDNASequence() throws {
        let document = GenomicDocument(name: "test")
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATCG")
        document.addSequence(sequence)

        let caps = document.computeCapabilities()

        XCTAssertTrue(caps.contains(.nucleotideSequence))
        XCTAssertFalse(caps.contains(.annotations))
    }

    @MainActor
    func testDocumentWithAnnotations() throws {
        let document = GenomicDocument(name: "test")
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATCG")
        document.addSequence(sequence)

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "test_gene",
            start: 0,
            end: 8,
            strand: .forward
        )
        document.addAnnotation(annotation, to: sequence.id)

        let caps = document.computeCapabilities()

        XCTAssertTrue(caps.contains(.nucleotideSequence))
        XCTAssertTrue(caps.contains(.annotations))
    }

    @MainActor
    func testDocumentWithMetadata() throws {
        let document = GenomicDocument(name: "test")
        document.metadata.organism = "Homo sapiens"
        document.metadata.accession = "NC_000001"

        let caps = document.computeCapabilities()

        XCTAssertTrue(caps.contains(.richMetadata))
    }

    @MainActor
    func testDocumentWithVariantAnnotations() throws {
        let document = GenomicDocument(name: "test")
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATCG")
        document.addSequence(sequence)

        let snp = SequenceAnnotation(
            type: .snp,
            name: "rs12345",
            start: 4,
            end: 5,
            strand: .forward
        )
        document.addAnnotation(snp, to: sequence.id)

        let caps = document.computeCapabilities()

        XCTAssertTrue(caps.contains(.annotations))
        XCTAssertTrue(caps.contains(.variants))
    }

    @MainActor
    func testDocumentWithPrimerAnnotations() throws {
        let document = GenomicDocument(name: "test")
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATCGATCGATCG")
        document.addSequence(sequence)

        let primer = SequenceAnnotation(
            type: .primer,
            name: "forward_primer",
            start: 0,
            end: 8,
            strand: .forward
        )
        document.addAnnotation(primer, to: sequence.id)

        let caps = document.computeCapabilities()

        XCTAssertTrue(caps.contains(.primers))
    }

    @MainActor
    func testReferenceDocumentType() throws {
        let document = GenomicDocument(name: "reference", documentCategory: .reference)
        let sequence = try Sequence(name: "chr1", alphabet: .dna, bases: "ATCGATCG")
        document.addSequence(sequence)

        let caps = document.computeCapabilities()

        XCTAssertTrue(caps.contains(.referenceSequence))
    }

    @MainActor
    func testAlignmentDocumentType() throws {
        let document = GenomicDocument(name: "alignment", documentCategory: .alignment)
        let sequence = try Sequence(name: "aligned_seq", alphabet: .dna, bases: "ATCGATCG")
        document.addSequence(sequence)

        let caps = document.computeCapabilities()

        XCTAssertTrue(caps.contains(.multipleAlignment))
    }

    @MainActor
    func testDocumentSatisfiesRequirements() throws {
        let document = GenomicDocument(name: "test")
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATCG")
        document.addSequence(sequence)

        XCTAssertTrue(document.satisfiesRequirements(.nucleotideSequence))
        XCTAssertFalse(document.satisfiesRequirements(.qualityScores))
    }

    @MainActor
    func testDocumentMissingCapabilities() throws {
        let document = GenomicDocument(name: "test")
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATCG")
        document.addSequence(sequence)

        let requirements: DocumentCapability = [.nucleotideSequence, .qualityScores, .annotations]
        let missing = document.missingCapabilitiesForRequirements(requirements)

        XCTAssertFalse(missing.contains(.nucleotideSequence))
        XCTAssertTrue(missing.contains(.qualityScores))
        XCTAssertTrue(missing.contains(.annotations))
    }

    @MainActor
    func testDocumentValidation() throws {
        let document = GenomicDocument(name: "test")
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATCG")
        document.addSequence(sequence)

        let validator = CapabilityValidator(required: .nucleotideSequence)
        let result = document.validate(with: validator)

        XCTAssertTrue(result.isValid)
    }

    @MainActor
    func testDocumentCapabilitiesUseSnapshotProviderForGenericValidation() throws {
        let document = GenomicDocument(name: "test")
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "ATCGATCG")
        document.addSequence(sequence)

        let provider = DocumentCapabilityWrapper(capabilities: document.computeCapabilities())
        let validator = CapabilityValidator(required: .nucleotideSequence)

        XCTAssertTrue(validator.validate(provider).isValid)
    }

    func testGenomicDocumentDoesNotExposeMisleadingCapabilityProviderConformance() throws {
        let sourceURL = Self.repositoryRoot()
            .appendingPathComponent("Sources/LungfishCore/Capabilities/GenomicDocument+Capabilities.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(
            source.contains("extension GenomicDocument: CapabilityProvider"),
            "GenomicDocument is MainActor-isolated; use computeCapabilities() plus DocumentCapabilityWrapper instead of direct CapabilityProvider conformance."
        )
        XCTAssertFalse(
            source.contains("return .none"),
            "The old nonisolated CapabilityProvider shim silently reported no capabilities and must not be reintroduced."
        )
    }

    private static func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
