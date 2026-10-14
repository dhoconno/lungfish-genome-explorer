// PathoplexusBundleMetadata.swift - The Pathoplexus record's metadata groups in a bundle manifest
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "PathoplexusBundleMetadata")

/// Appends Pathoplexus-specific metadata to a bundle's manifest.
///
/// Reads the existing manifest, creates a new one with appended Pathoplexus metadata group,
/// and writes it back. This preserves all GenBank metadata while adding provenance info.
package func appendPathoplexusMetadata(_ meta: PathoplexusMetadata, organism: String, toBundleAt bundleURL: URL) {
    do {
        let existing = try BundleManifest.load(from: bundleURL)

        // Build Pathoplexus metadata groups

        // Record group
        var recordItems: [MetadataItem] = []
        let ppVersion = meta.accessionVersion ?? meta.accession
        let encodedVersion = ppVersion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ppVersion
        let ppRecordURL = "https://pathoplexus.org/\(organism)/search?accession=\(encodedVersion)"
        recordItems.append(MetadataItem(label: "Accession", value: meta.accession, url: ppRecordURL))
        if let v = meta.accessionVersion { recordItems.append(MetadataItem(label: "Version", value: v, url: ppRecordURL)) }
        if let v = meta.displayName { recordItems.append(MetadataItem(label: "Display Name", value: v)) }
        if let v = meta.bestINSDCAccession {
            let genbankURL = "https://www.ncbi.nlm.nih.gov/nuccore/\(v)"
            recordItems.append(MetadataItem(label: "INSDC Accession", value: v, url: genbankURL))
        }
        if let v = meta.bioprojectAccession, !v.isEmpty {
            recordItems.append(MetadataItem(label: "BioProject", value: v, url: "https://www.ncbi.nlm.nih.gov/bioproject/\(v)"))
        }
        if let v = meta.biosampleAccession, !v.isEmpty {
            recordItems.append(MetadataItem(label: "BioSample", value: v, url: "https://www.ncbi.nlm.nih.gov/biosample/\(v)"))
        }
        if let v = meta.ncbiSourceDb, !v.isEmpty { recordItems.append(MetadataItem(label: "NCBI Source", value: v)) }
        if let v = meta.dataUseTerms { recordItems.append(MetadataItem(label: "Data Use Terms", value: v)) }
        if let v = meta.versionStatus { recordItems.append(MetadataItem(label: "Version Status", value: v)) }

        // Classification group
        var classItems: [MetadataItem] = []
        if let v = meta.organism { classItems.append(MetadataItem(label: "Organism", value: v)) }
        if let v = meta.ncbiVirusName, !v.isEmpty { classItems.append(MetadataItem(label: "Virus Name", value: v)) }
        if let v = meta.ncbiVirusTaxId {
            classItems.append(MetadataItem(label: "Taxonomy ID", value: "\(v)", url: "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=\(v)"))
        }
        if let v = meta.subtype, !v.isEmpty { classItems.append(MetadataItem(label: "Subtype", value: v)) }
        if let v = meta.clade { classItems.append(MetadataItem(label: "Clade", value: v)) }
        if let v = meta.lineage { classItems.append(MetadataItem(label: "Lineage", value: v)) }

        // Sample group
        var sampleItems: [MetadataItem] = []
        if let v = meta.bestLocation { sampleItems.append(MetadataItem(label: "Location", value: v)) }
        if let v = meta.sampleCollectionDate { sampleItems.append(MetadataItem(label: "Collection Date", value: v)) }
        if let v = meta.hostNameScientific { sampleItems.append(MetadataItem(label: "Host (Scientific)", value: v)) }
        if let v = meta.hostNameCommon { sampleItems.append(MetadataItem(label: "Host (Common)", value: v)) }
        if let v = meta.purposeOfSampling, !v.isEmpty { sampleItems.append(MetadataItem(label: "Sampling Purpose", value: v)) }

        // Sequencing group
        var seqItems: [MetadataItem] = []
        if let v = meta.length { seqItems.append(MetadataItem(label: "Length", value: "\(v) bp")) }
        if let v = meta.sequencedByOrganization, !v.isEmpty { seqItems.append(MetadataItem(label: "Sequencing Lab", value: v)) }
        if let v = meta.sequencingInstrument, !v.isEmpty { seqItems.append(MetadataItem(label: "Instrument", value: v)) }
        if let v = meta.purposeOfSequencing, !v.isEmpty { seqItems.append(MetadataItem(label: "Sequencing Purpose", value: v)) }
        if let n = meta.consensusSequenceSoftwareName, !n.isEmpty {
            let ver = meta.consensusSequenceSoftwareVersion.map { " \($0)" } ?? ""
            seqItems.append(MetadataItem(label: "Consensus Software", value: "\(n)\(ver)"))
        }

        // Quality group
        var qualItems: [MetadataItem] = []
        if let v = meta.depthOfCoverage { qualItems.append(MetadataItem(label: "Depth of Coverage", value: String(format: "%.1fx", v))) }
        if let v = meta.breadthOfCoverage { qualItems.append(MetadataItem(label: "Breadth of Coverage", value: String(format: "%.1f%%", v * 100))) }
        if let v = meta.completeness { qualItems.append(MetadataItem(label: "Completeness", value: String(format: "%.1f%%", v * 100))) }
        if let v = meta.qualityControlDetermination, !v.isEmpty { qualItems.append(MetadataItem(label: "QC Determination", value: v)) }
        if let v = meta.totalSnps, v > 0 { qualItems.append(MetadataItem(label: "Total SNPs", value: "\(v)")) }
        if let v = meta.totalDeletedNucs, v > 0 { qualItems.append(MetadataItem(label: "Total Deletions", value: "\(v)")) }
        if let v = meta.totalInsertedNucs, v > 0 { qualItems.append(MetadataItem(label: "Total Insertions", value: "\(v)")) }
        if let v = meta.totalUnknownNucs, v > 0 { qualItems.append(MetadataItem(label: "Unknown Nucs", value: "\(v)")) }

        // Provenance group
        var provItems: [MetadataItem] = []
        if let v = meta.groupName, !v.isEmpty { provItems.append(MetadataItem(label: "Submitter Group", value: v)) }
        if let v = meta.authors, !v.isEmpty { provItems.append(MetadataItem(label: "Authors", value: v)) }
        if let v = meta.submittedDate { provItems.append(MetadataItem(label: "Submitted", value: v)) }
        if let v = meta.releasedDate { provItems.append(MetadataItem(label: "Released", value: v)) }

        var groups = existing.metadata ?? []
        groups.append(MetadataGroup(name: "Pathoplexus Record", items: recordItems))
        if !classItems.isEmpty { groups.append(MetadataGroup(name: "Classification", items: classItems)) }
        if !sampleItems.isEmpty { groups.append(MetadataGroup(name: "Sample", items: sampleItems)) }
        if !seqItems.isEmpty { groups.append(MetadataGroup(name: "Sequencing", items: seqItems)) }
        if !qualItems.isEmpty { groups.append(MetadataGroup(name: "Quality", items: qualItems)) }
        if !provItems.isEmpty { groups.append(MetadataGroup(name: "Provenance", items: provItems)) }

        // Create updated manifest with Pathoplexus metadata appended
        let updated = BundleManifest(
            formatVersion: existing.formatVersion,
            name: existing.name,
            identifier: existing.identifier,
            description: existing.description,
            createdDate: existing.createdDate,
            modifiedDate: Date(),
            source: existing.source,
            genome: existing.genome,
            annotations: existing.annotations,
            variants: existing.variants,
            tracks: existing.tracks,
            alignments: existing.alignments,
            metadata: groups
        )

        try updated.save(to: bundleURL)
        logger.info("appendPathoplexusMetadata: Added Pathoplexus metadata group to \(bundleURL.lastPathComponent)")
    } catch {
        logger.error("appendPathoplexusMetadata: Failed to append metadata: \(error)")
    }

}
