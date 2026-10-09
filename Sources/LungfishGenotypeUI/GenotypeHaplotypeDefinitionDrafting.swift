import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishKit

enum GenotypeHaplotypeDefinitionDrafting {
    static func withDefinitionFields(
        _ set: GenotypeHaplotypeDefinitionSet,
        id: String? = nil,
        assayID: String? = nil,
        displayName: String? = nil,
        speciesName: String? = nil,
        speciesCode: String? = nil,
        prefix: String? = nil
    ) -> GenotypeHaplotypeDefinitionSet {
        GenotypeHaplotypeDefinitionSet(
            id: id ?? set.id,
            assayID: assayID ?? set.assayID,
            displayName: displayName ?? set.displayName,
            speciesName: speciesName ?? set.speciesName,
            speciesCode: speciesCode ?? set.speciesCode,
            prefix: prefix ?? set.prefix,
            locusDefinitions: set.locusDefinitions,
            schemaVersion: set.schemaVersion,
            lastModified: set.lastModified,
            changeNote: set.changeNote
        )
    }

    static func renamingHaplotype(
        in set: GenotypeHaplotypeDefinitionSet,
        locusIndex: Int,
        haplotypeIndex: Int,
        name: String
    ) -> GenotypeHaplotypeDefinitionSet {
        replacingHaplotype(in: set, locusIndex: locusIndex, haplotypeIndex: haplotypeIndex) {
            GenotypeHaplotypeDefinition(
                name: name,
                diagnosticAlleles: $0.diagnosticAlleles,
                associatedAlleles: $0.associatedAlleles,
                primaryAlleles: $0.primaryAlleles,
                evidenceWeights: $0.evidenceWeights,
                colorTokenIndex: $0.colorTokenIndex,
                colorOverride: $0.colorOverride,
                minimumMatches: $0.minimumMatches
            )
        }
    }

    static func withDiagnosticAlleles(
        _ haplotype: GenotypeHaplotypeDefinition,
        alleles: [String]
    ) -> GenotypeHaplotypeDefinition {
        let associated = orderedUnion(haplotype.effectiveAssociatedAlleles, alleles)
        return GenotypeHaplotypeDefinition(
            name: haplotype.name,
            diagnosticAlleles: alleles,
            associatedAlleles: associated,
            primaryAlleles: haplotype.primaryAlleles,
            evidenceWeights: haplotype.evidenceWeights,
            colorTokenIndex: haplotype.colorTokenIndex,
            colorOverride: haplotype.colorOverride,
            minimumMatches: clampedMinimumMatches(haplotype.minimumMatches, alleleCount: alleles.count)
        )
    }

    static func addingAssociatedAllele(
        _ haplotype: GenotypeHaplotypeDefinition,
        allele: String
    ) -> GenotypeHaplotypeDefinition {
        let associated = orderedUnion(haplotype.effectiveAssociatedAlleles, [allele])
        return GenotypeHaplotypeDefinition(
            name: haplotype.name,
            diagnosticAlleles: haplotype.diagnosticAlleles,
            associatedAlleles: associated,
            primaryAlleles: haplotype.primaryAlleles,
            evidenceWeights: haplotype.evidenceWeights,
            colorTokenIndex: haplotype.colorTokenIndex,
            colorOverride: haplotype.colorOverride,
            minimumMatches: haplotype.minimumMatches
        )
    }

    static func withDiagnostic(
        _ haplotype: GenotypeHaplotypeDefinition,
        allele: String,
        isDiagnostic: Bool
    ) -> GenotypeHaplotypeDefinition {
        let associated = orderedUnion(haplotype.effectiveAssociatedAlleles, [allele])
        let existing = Set(haplotype.diagnosticAlleles)
        let diagnostic = associated.filter { (existing.contains($0) && $0 != allele) || (isDiagnostic && $0 == allele) }
        return withDiagnosticAlleles(haplotype, alleles: diagnostic)
    }

    static func removingAssociatedAllele(
        _ haplotype: GenotypeHaplotypeDefinition,
        allele: String
    ) -> GenotypeHaplotypeDefinition {
        let associated = haplotype.effectiveAssociatedAlleles.filter { $0 != allele }
        let diagnostic = haplotype.diagnosticAlleles.filter { $0 != allele }
        let primary = haplotype.primaryAlleles?.filter { $0 != allele }
        let weights = haplotype.evidenceWeights?.filter { $0.key != allele }
        return GenotypeHaplotypeDefinition(
            name: haplotype.name,
            diagnosticAlleles: diagnostic,
            associatedAlleles: associated,
            primaryAlleles: primary,
            evidenceWeights: weights,
            colorTokenIndex: haplotype.colorTokenIndex,
            colorOverride: haplotype.colorOverride,
            minimumMatches: clampedMinimumMatches(haplotype.minimumMatches, alleleCount: diagnostic.count)
        )
    }

    static func minimumMatchesLabel(
        for haplotype: GenotypeHaplotypeDefinition,
        requested: Int? = nil
    ) -> String {
        let count = haplotype.diagnosticAlleles.count
        let value = count == 0 ? 0 : max(1, min(requested ?? haplotype.effectiveMinimumMatches, count))
        return "Require \(value) of \(count) diagnostic alleles"
    }

    static func withColorOverride(
        _ haplotype: GenotypeHaplotypeDefinition,
        color: AnnotationColor?
    ) -> GenotypeHaplotypeDefinition {
        GenotypeHaplotypeDefinition(
            name: haplotype.name,
            diagnosticAlleles: haplotype.diagnosticAlleles,
            associatedAlleles: haplotype.associatedAlleles,
            primaryAlleles: haplotype.primaryAlleles,
            evidenceWeights: haplotype.evidenceWeights,
            colorTokenIndex: haplotype.colorTokenIndex,
            colorOverride: color,
            minimumMatches: haplotype.minimumMatches
        )
    }

    static func withMinimumMatches(
        _ haplotype: GenotypeHaplotypeDefinition,
        minimumMatches: Int
    ) -> GenotypeHaplotypeDefinition {
        let clamped = clampedMinimumMatches(minimumMatches, alleleCount: haplotype.diagnosticAlleles.count)
        let stored = clamped == haplotype.diagnosticAlleles.count ? nil : clamped
        return GenotypeHaplotypeDefinition(
            name: haplotype.name,
            diagnosticAlleles: haplotype.diagnosticAlleles,
            associatedAlleles: haplotype.associatedAlleles,
            primaryAlleles: haplotype.primaryAlleles,
            evidenceWeights: haplotype.evidenceWeights,
            colorTokenIndex: haplotype.colorTokenIndex,
            colorOverride: haplotype.colorOverride,
            minimumMatches: stored
        )
    }

    static func validationMessages(for set: GenotypeHaplotypeDefinitionSet) -> [String] {
        var messages: [String] = []
        let trimmedName = set.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            messages.append("Definition name is required.")
        }
        if set.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Definition ID is required.")
        }
        if set.assayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Assay ID is required.")
        }
        if set.speciesName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || set.speciesCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Species name and code are required.")
        }
        if set.prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append("Allele prefix is required.")
        }
        let locusNames = set.locusDefinitions.map { $0.locus.trimmingCharacters(in: .whitespacesAndNewlines) }
        if locusNames.contains(where: \.isEmpty) {
            messages.append("Locus names are required.")
        }
        if hasDuplicates(locusNames.filter { !$0.isEmpty }) {
            messages.append("Duplicate locus names are not allowed.")
        }
        for locus in set.locusDefinitions {
            let haplotypeNames = locus.haplotypes.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            if haplotypeNames.contains(where: \.isEmpty) {
                messages.append("Haplotype name is required.")
            }
            if hasDuplicates(haplotypeNames.filter { !$0.isEmpty }) {
                messages.append("Duplicate haplotype names are not allowed within \(locus.locus).")
            }
            if locus.haplotypes.contains(where: { $0.diagnosticAlleles.isEmpty }) {
                messages.append("Each haplotype needs at least one diagnostic allele.")
            }
        }
        var seen = Set<String>()
        return messages.filter { seen.insert($0).inserted }
    }

    private static func replacingHaplotype(
        in set: GenotypeHaplotypeDefinitionSet,
        locusIndex: Int,
        haplotypeIndex: Int,
        transform: (GenotypeHaplotypeDefinition) -> GenotypeHaplotypeDefinition
    ) -> GenotypeHaplotypeDefinitionSet {
        guard set.locusDefinitions.indices.contains(locusIndex) else { return set }
        var loci = set.locusDefinitions
        var haplotypes = loci[locusIndex].haplotypes
        guard haplotypes.indices.contains(haplotypeIndex) else { return set }
        haplotypes[haplotypeIndex] = transform(haplotypes[haplotypeIndex])
        loci[locusIndex] = GenotypeHaplotypeLocusDefinition(
            locus: loci[locusIndex].locus,
            sourceLocus: loci[locusIndex].sourceLocus,
            haplotypes: haplotypes
        )
        return GenotypeHaplotypeDefinitionSet(
            id: set.id,
            assayID: set.assayID,
            displayName: set.displayName,
            speciesName: set.speciesName,
            speciesCode: set.speciesCode,
            prefix: set.prefix,
            locusDefinitions: loci,
            schemaVersion: set.schemaVersion,
            lastModified: set.lastModified,
            changeNote: set.changeNote
        )
    }

    private static func clampedMinimumMatches(_ minimumMatches: Int?, alleleCount: Int) -> Int? {
        guard let minimumMatches else { return nil }
        return clampedMinimumMatchesValue(minimumMatches, alleleCount: alleleCount)
    }

    private static func clampedMinimumMatchesValue(_ minimumMatches: Int, alleleCount: Int) -> Int {
        max(1, min(minimumMatches, max(1, alleleCount)))
    }

    private static func orderedUnion(_ first: [String], _ second: [String]) -> [String] {
        var seen = Set<String>()
        return (first + second).filter { seen.insert($0).inserted }
    }

    private static func hasDuplicates(_ values: [String]) -> Bool {
        var seen = Set<String>()
        for value in values {
            if !seen.insert(value).inserted { return true }
        }
        return false
    }
}
