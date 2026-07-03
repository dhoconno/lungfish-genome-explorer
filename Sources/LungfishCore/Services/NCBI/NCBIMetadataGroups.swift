// NCBIMetadataGroups.swift - NCBI Entrez E-utilities integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: NCBI Integration Lead (Role 12)

import Foundation

// MARK: - NCBIAssemblySummary Metadata Conversion

/// Formats a base pair count into a human-readable string (e.g., "56.4 Mb").
///
/// Module-level free function to avoid `@MainActor` isolation issues when called
/// from `@Sendable` contexts.
private func formatAssemblyBp(_ value: Int) -> String {
    if value >= 1_000_000_000 {
        return String(format: "%.1f Gb", Double(value) / 1_000_000_000)
    }
    if value >= 1_000_000 {
        return String(format: "%.1f Mb", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.1f Kb", Double(value) / 1_000)
    }
    return "\(value) bp"
}

extension NCBIAssemblySummary {

    /// Converts the assembly summary into categorized metadata groups for bundle storage.
    ///
    /// Groups:
    /// - **Assembly**: Name, accession, status, level, coverage, N50 statistics, length, chromosome count
    /// - **Taxonomy**: Organism, species, taxonomy ID
    /// - **Source**: Submitter, organization, BioSample, BioProject
    ///
    /// - Returns: Array of metadata groups with non-nil fields populated.
    public func toMetadataGroups() -> [MetadataGroup] {
        var groups: [MetadataGroup] = []

        // Assembly group
        var assemblyItems: [MetadataItem] = []
        if let v = assemblyName { assemblyItems.append(MetadataItem(label: "Assembly Name", value: v)) }
        if let v = assemblyAccession { assemblyItems.append(MetadataItem(label: "Accession", value: v)) }
        if let v = assemblyStatus { assemblyItems.append(MetadataItem(label: "Status", value: v)) }
        if let v = assemblyLevel { assemblyItems.append(MetadataItem(label: "Level", value: v)) }
        if let v = refseqCategory { assemblyItems.append(MetadataItem(label: "RefSeq Category", value: v)) }
        if let v = releaseType { assemblyItems.append(MetadataItem(label: "Release Type", value: v)) }
        if let v = coverage { assemblyItems.append(MetadataItem(label: "Coverage", value: "\(v)x")) }
        if let v = contigN50 { assemblyItems.append(MetadataItem(label: "Contig N50", value: formatAssemblyBp(v))) }
        if let v = scaffoldN50 { assemblyItems.append(MetadataItem(label: "Scaffold N50", value: formatAssemblyBp(v))) }
        if let v = totalSequenceLength { assemblyItems.append(MetadataItem(label: "Total Length", value: "\(v) bp")) }
        if let v = chromosomeCount { assemblyItems.append(MetadataItem(label: "Chromosomes", value: v)) }
        if !assemblyItems.isEmpty { groups.append(MetadataGroup(name: "Assembly", items: assemblyItems)) }

        // Taxonomy group
        var taxItems: [MetadataItem] = []
        if let v = organism { taxItems.append(MetadataItem(label: "Organism", value: v)) }
        if let v = speciesName, v != organism { taxItems.append(MetadataItem(label: "Species", value: v)) }
        if let v = taxid { taxItems.append(MetadataItem(label: "Taxonomy ID", value: String(v))) }
        if !taxItems.isEmpty { groups.append(MetadataGroup(name: "Taxonomy", items: taxItems)) }

        // Source group
        var sourceItems: [MetadataItem] = []
        if let v = submitter { sourceItems.append(MetadataItem(label: "Submitter", value: v)) }
        if let v = submitterOrganization { sourceItems.append(MetadataItem(label: "Organization", value: v)) }
        if let v = biosampleAccession { sourceItems.append(MetadataItem(label: "BioSample", value: v)) }
        if let v = bioprojectAccession { sourceItems.append(MetadataItem(label: "BioProject", value: v)) }
        if !sourceItems.isEmpty { groups.append(MetadataGroup(name: "Source", items: sourceItems)) }

        return groups
    }
}

// MARK: - VirusReport Metadata Conversion

extension VirusReport {

    /// Converts the virus report into categorized metadata groups for bundle storage.
    ///
    /// Groups:
    /// - **Virus**: Organism name, pangolin classification, taxonomy ID
    /// - **Host**: Host organism, host taxonomy ID
    /// - **Collection**: Isolate name, collection date, geographic location, region, purpose of sampling
    /// - **Record**: Accession, source database, completeness, sequence length, protein count, release/update dates
    /// - **Links**: BioSample, BioProject accessions
    ///
    /// - Returns: Array of metadata groups with non-nil fields populated.
    public func toMetadataGroups() -> [MetadataGroup] {
        var groups: [MetadataGroup] = []

        // Virus group
        var virusItems: [MetadataItem] = []
        if let v = virus?.organismName { virusItems.append(MetadataItem(label: "Organism", value: v)) }
        if let v = virus?.pangolinClassification { virusItems.append(MetadataItem(label: "Pangolin Classification", value: v)) }
        if let v = virus?.taxId { virusItems.append(MetadataItem(label: "Taxonomy ID", value: String(v))) }
        if !virusItems.isEmpty { groups.append(MetadataGroup(name: "Virus", items: virusItems)) }

        // Host group
        var hostItems: [MetadataItem] = []
        if let v = host?.organismName { hostItems.append(MetadataItem(label: "Host Organism", value: v)) }
        if let v = host?.taxId { hostItems.append(MetadataItem(label: "Host Taxonomy ID", value: String(v))) }
        if !hostItems.isEmpty { groups.append(MetadataGroup(name: "Host", items: hostItems)) }

        // Collection group
        var collectionItems: [MetadataItem] = []
        if let v = isolate?.name { collectionItems.append(MetadataItem(label: "Isolate", value: v)) }
        if let v = isolate?.collectionDate { collectionItems.append(MetadataItem(label: "Collection Date", value: v)) }
        if let v = location?.geographicLocation { collectionItems.append(MetadataItem(label: "Location", value: v)) }
        if let v = location?.geographicRegion { collectionItems.append(MetadataItem(label: "Geographic Region", value: v)) }
        if let v = purposeOfSampling { collectionItems.append(MetadataItem(label: "Purpose of Sampling", value: v)) }
        if !collectionItems.isEmpty { groups.append(MetadataGroup(name: "Collection", items: collectionItems)) }

        // Record group
        var recordItems: [MetadataItem] = []
        if let v = accession { recordItems.append(MetadataItem(label: "Accession", value: v)) }
        if let v = sourceDatabase { recordItems.append(MetadataItem(label: "Source Database", value: v)) }
        if let v = completeness { recordItems.append(MetadataItem(label: "Completeness", value: v)) }
        if let v = length { recordItems.append(MetadataItem(label: "Length", value: "\(v) bp")) }
        if let v = proteinCount { recordItems.append(MetadataItem(label: "Protein Count", value: String(v))) }
        if let v = releaseDate { recordItems.append(MetadataItem(label: "Release Date", value: v)) }
        if let v = updateDate { recordItems.append(MetadataItem(label: "Update Date", value: v)) }
        if !recordItems.isEmpty { groups.append(MetadataGroup(name: "Record", items: recordItems)) }

        // Links group
        var linkItems: [MetadataItem] = []
        if let v = biosample { linkItems.append(MetadataItem(label: "BioSample", value: v)) }
        if let bioprojects, !bioprojects.isEmpty {
            linkItems.append(MetadataItem(label: "BioProject", value: bioprojects.joined(separator: ", ")))
        }
        if !linkItems.isEmpty { groups.append(MetadataGroup(name: "Links", items: linkItems)) }

        return groups
    }
}
