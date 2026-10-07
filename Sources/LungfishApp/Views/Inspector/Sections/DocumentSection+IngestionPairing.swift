// DocumentSection+IngestionPairing.swift - The Inspector's Pairing row names pairs and single reads by their count
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension DocumentSectionViewModel {

    /// Updates the view model with ingestion metadata. The read roles of the
    /// dataset shown before go with it, and a bundle's own come from
    /// ``updateIngestionReadRoles(fromBundle:)``.
    func updateIngestionMetadata(_ ingestion: IngestionMetadata?) {
        ingestionMetadata = ingestion
        ingestionReadRoles = nil
    }

    /// Reads the read roles the FASTQ sidecar of `bundleURL` records. Nil
    /// when the bundle has no primary FASTQ or its sidecar records none.
    func updateIngestionReadRoles(fromBundle bundleURL: URL) {
        ingestionReadRoles = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL)
            .flatMap { FASTQMetadataStore.load(for: $0)?.readClassification }
    }

    /// The read roles the Pairing row reads. They are the bundle's FASTQ
    /// sidecar's, else the derived manifest's, else the roles of a mixed
    /// payload's files.
    var ingestionPairingRoles: ReadClassification? {
        if let ingestionReadRoles { return ingestionReadRoles }
        guard let manifest = fastqDerivativeManifest else { return nil }
        if let roles = manifest.readClassification { return roles }
        if case .fullMixed(let roles) = manifest.payload { return roles }
        return nil
    }

    /// The text of the Ingestion group's Pairing row.
    ///
    /// A file whose read roles hold pairs and single reads is labelled
    /// `single_end` by its count, the one convention every importer
    /// follows, so no tool pairs it by position. Printed as stored, a paired
    /// SRA run imported with its reads whose mate is missing read "Single
    /// End". The row names what such a file holds instead, for example
    /// "Pairs and single reads (129 pairs + 6 singles)", and the stored label
    /// stays as it is. Every other file shows its stored pairing as before.
    nonisolated static func pairingRowText(_ mode: IngestionMetadata.PairingMode, roles: ReadClassification?) -> String {
        if let roles, roles.pairedReadCount > 0, roles.mergedReadCount + roles.unpairedReadCount > 0 {
            return "Pairs and single reads (\(roles.compositionLabel))"
        }
        return mode.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
