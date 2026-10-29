// MetagenomicsDatabaseReceiptReference.swift - A classifier database as its install receipt vouches for it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// The install receipt of a classifier database, checked against the files it lists, one lookup for every record that
/// names a database (DB-IDENTITY, Phase 3.1, BIO-DB-IDENTITY section 3).
///
/// An install writes its receipt into the folder it installed, with the payload aggregate SHA-256 over every file below
/// that folder and the size of those files. A run reads the receipt once, checks that the outputs it lists add up to its
/// own digest and size, and records that digest. No database file is read or hashed at run time (decision E9 as amended
/// by 2.13 vote V2-1). A full rehash stays the explicit `MetagenomicsDatabaseConformanceIdentity.verify`.
///
/// Kraken2 looks for the receipt in the folder its tool reads (``Kraken2DatabaseReceipt``). An EsViritu archive unpacks
/// into a version folder below the install root, so its receipt sits in the parent of the folder its tool reads, and its
/// lookup also tries that one parent (`allowingParentReceipt`). The reference's path is then the folder that holds the
/// receipt, which is the folder the aggregate covers, while a record's `databasePath` stays the folder the tool read.
public enum MetagenomicsDatabaseReceiptReference {
    /// The workflow name of a database install receipt, the record an install writes into the database folder.
    public static let installWorkflowName = "metagenomics.database.install"

    /// A receipt that names a database folder and says its install ended 0.
    public struct Found: Sendable, Equatable {
        /// The folder that holds the receipt, which is the folder its digest covers.
        public let receiptRoot: URL
        /// The first of the receipt's requested catalog version and workflow version that names something, never a
        /// placeholder (``DatabaseReceiptPlaceholder``).
        public let catalogVersion: String?
        /// The database as a reference input, with the aggregate SHA-256 and size the receipt holds and the receipt as
        /// its source provenance. Nil when the receipt does not add up to its own digest and size, or disagrees with
        /// the registry's digest.
        public let reference: ProvenanceFileDescriptor?
    }

    /// The receipt that names `databasePath`, or nil when none does. With `allowingParentReceipt` the lookup tries the
    /// folder first and then its parent once. A parent's receipt counts only when its `intendedFinalPath` names that
    /// parent, and the folder lies inside the parent by construction. A receipt that names the folder but does not add
    /// up is still found, with no reference, so a record can say why it records no digest.
    public static func resolve(
        databasePath: URL,
        registryDigest: String? = nil,
        allowingParentReceipt: Bool = false
    ) -> Found? {
        let folder = databasePath.standardizedFileURL
        var roots = [folder]
        if allowingParentReceipt {
            let parent = folder.deletingLastPathComponent().standardizedFileURL
            if parent.path != folder.path {
                roots.append(parent)
            }
        }
        for root in roots {
            if let found = found(in: root, registryDigest: registryDigest) {
                return found
            }
        }
        return nil
    }

    /// The resolved defaults that state how far the receipt pins a record's database. A receipt that adds up gives the
    /// status `pinned` and the digest as `databaseDigest`. Without one the status is `unpinned` and no digest is
    /// recorded, and a receipt that does not add up also gives `databaseIdentityNote` with the folder it sits in. With no
    /// receipt at all the record says nothing more, as before. The note speaks of the receipt's own digest, so a caller
    /// passes no registry digest to ``resolve(databasePath:registryDigest:allowingParentReceipt:)``.
    public static func identityFacts(of found: Found?) -> [String: ParameterValue] {
        if let digest = found?.reference?.checksumSHA256 {
            return [
                "databaseIdentityStatus": .string(DatabaseIdentityStatus.pinned.rawValue),
                "databaseDigest": .string(digest),
            ]
        }
        var facts: [String: ParameterValue] = [
            "databaseIdentityStatus": .string(DatabaseIdentityStatus.unpinned.rawValue),
        ]
        if let found {
            facts["databaseIdentityNote"] = .string(
                "The install receipt in \(found.receiptRoot.path) does not add up to its own digest, "
                    + "so this run records no digest."
            )
        }
        return facts
    }

    /// A SHA-256 as 64 lower-case hex digits, with or without a `sha256:` prefix, or nil.
    public static func normalizedSHA256(_ value: String?) -> String? {
        guard var value else { return nil }
        if value.lowercased().hasPrefix("sha256:") {
            value = String(value.dropFirst("sha256:".count))
        }
        let normalized = value.lowercased()
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            return nil
        }
        return normalized
    }

    private static func found(in root: URL, registryDigest: String?) -> Found? {
        guard let receipt = ProvenanceRecorder.loadEnvelope(from: root),
              receipt.workflowName == installWorkflowName,
              receipt.exitStatus == 0,
              receipt.options.resolvedDefaults["intendedFinalPath"]?.stringValue == root.path else {
            return nil
        }
        let installed = receipt.options.resolvedDefaults
        return Found(
            receiptRoot: root,
            catalogVersion: DatabaseReceiptPlaceholder.firstNamed(
                among: [installed["requestedCatalogVersion"]?.stringValue, receipt.workflowVersion]
            ),
            reference: reference(of: receipt, in: root, registryDigest: registryDigest)
        )
    }

    private static func reference(of receipt: ProvenanceEnvelope, in root: URL, registryDigest: String?) -> ProvenanceFileDescriptor? {
        guard let receiptDigest = normalizedSHA256(receipt.options.resolvedDefaults["payloadAggregateSHA256"]?.stringValue),
              let size = verifiedSize(receipt, root: root, aggregateDigest: receiptDigest) else {
            return nil
        }
        if let registryDigest, normalizedSHA256(registryDigest) != receiptDigest {
            return nil
        }
        return ProvenanceFileDescriptor(
            path: root.path,
            checksumSHA256: receiptDigest,
            fileSize: size,
            format: .unknown,
            role: .reference,
            sourceProvenancePath: root.appendingPathComponent(ProvenanceWriter.provenanceFilename).path
        )
    }

    private static func verifiedSize(
        _ receipt: ProvenanceEnvelope,
        root: URL,
        aggregateDigest: String
    ) -> UInt64? {
        guard !receipt.outputs.isEmpty else { return nil }
        let rootPath = root.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var seenPaths = Set<String>()
        var rows: [(relativePath: String, checksum: String, size: UInt64)] = []
        var total: UInt64 = 0
        for descriptor in receipt.outputs {
            let outputPath = URL(fileURLWithPath: descriptor.path).standardizedFileURL.path
            guard descriptor.role == .output,
                  outputPath.hasPrefix(rootPrefix),
                  seenPaths.insert(outputPath).inserted,
                  let checksum = normalizedSHA256(descriptor.checksumSHA256),
                  let size = descriptor.fileSize else {
                return nil
            }
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow else { return nil }
            total = sum
            rows.append((String(outputPath.dropFirst(rootPrefix.count)), checksum, size))
        }
        let lines = rows
            .sorted { $0.relativePath < $1.relativePath }
            .map { "\($0.relativePath)\t\($0.checksum)\t\($0.size)\n" }
            .joined()
        let computed = SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
        guard computed == aggregateDigest,
              let claimed = receipt.options.resolvedDefaults["payloadTotalSizeBytes"]?.integerValue,
              claimed >= 0,
              UInt64(claimed) == total else {
            return nil
        }
        return total
    }
}

/// The install receipt of a Kraken2 database, checked against the files it lists. The check is
/// ``MetagenomicsDatabaseReceiptReference`` with its parent lookup off, so a Kraken2 record reads the receipt in the
/// database's own folder only and its bytes do not move.
public enum Kraken2DatabaseReceipt {
    /// The database as a reference input, with the aggregate SHA-256 and size its install receipt holds, or nil when the
    /// receipt is missing, failed, names another folder, does not add up to its own digest and size, or disagrees with
    /// the registry's digest.
    public static func verifiedReference(databasePath: URL, registryDigest: String?) -> ProvenanceFileDescriptor? {
        MetagenomicsDatabaseReceiptReference.resolve(databasePath: databasePath, registryDigest: registryDigest)?.reference
    }

    /// A SHA-256 as 64 lower-case hex digits, with or without a `sha256:` prefix, or nil.
    public static func normalizedSHA256(_ value: String?) -> String? {
        MetagenomicsDatabaseReceiptReference.normalizedSHA256(value)
    }
}
