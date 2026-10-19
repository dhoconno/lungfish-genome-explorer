// ProvenanceWriter+PriorSignatures.swift - Which signature a write with no key removes, and the history a record keeps of them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ProvenanceWriter {
    /// The raw key as a record's bytes hold it, which the writer scans for before it decodes a file.
    private static let priorSignaturesKeyBytes = Data("\"priorSignatures\"".utf8)

    /// The signature that a write with no key at `url` removes, when it verifies against the bytes in place.
    ///
    /// It returns nil when this writer holds a provider (a keyed write replaces the pair and removes nothing), when
    /// `<url>.signature.json` does not exist, and when `ProvenanceSignatureVerifier.verify` throws. A pair that fails
    /// says nothing true about the record, so it is removed and not named (BIO 4). The check reads the file while the
    /// old bytes are still in place, so a caller runs it before the new bytes replace them.
    func signatureThisWriteDrops(at url: URL) -> ProvenancePriorSignature? {
        guard signingProvider == nil,
              FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: url).path),
              let verified = try? ProvenanceSignatureVerifier.verify(provenanceURL: url) else {
            return nil
        }
        return ProvenancePriorSignature(verified)
    }

    /// `envelope` with the signature history of the record it is about to replace at `url`.
    ///
    /// The list is built in this order, with exact duplicates dropped.
    /// 1. The caller's `envelope.priorSignatures`.
    /// 2. The old file's list. It is carried when the old file has no pair and when its pair verifies. It is not
    ///    carried when the pair fails, since then the old bytes were edited after they were signed.
    /// 3. The pair this write removes, when it verified. That is a write with no provider and an empty
    ///    `envelope.signatures`, which are the conditions under which `writeSidecar` removes the pair.
    ///
    /// It reads the old file once and decodes it only when its bytes contain `"priorSignatures"`. It verifies only
    /// when a pair exists and only when there is something to carry or to name. It runs synchronously inside the
    /// caller's durability transaction and writes nothing.
    func envelopeKeepingSignatureHistory(
        _ envelope: ProvenanceEnvelope,
        replacing url: URL
    ) throws -> ProvenanceEnvelope {
        guard let oldBytes = try? Data(contentsOf: url) else { return envelope }
        let carriesHistory = oldBytes.range(of: Self.priorSignaturesKeyBytes) != nil
        let hasPair = FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: url).path)
        let removesPair = hasPair && signingProvider == nil && envelope.signatures.isEmpty
        guard carriesHistory || removesPair else { return envelope }

        var verified: ProvenanceSignatureVerificationResult?
        var pairFailed = false
        if hasPair {
            do {
                verified = try ProvenanceSignatureVerifier.verify(provenanceURL: url)
            } catch {
                pairFailed = true
            }
        }

        var history = envelope.priorSignatures
        if carriesHistory, !pairFailed,
           let old = try? ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: oldBytes) {
            history += old.priorSignatures
        }
        if removesPair, let verified {
            history.append(ProvenancePriorSignature(verified))
        }

        var merged: [ProvenancePriorSignature] = []
        for entry in history where !merged.contains(entry) {
            merged.append(entry)
        }
        guard merged != envelope.priorSignatures else { return envelope }
        var result = envelope
        result.priorSignatures = merged
        return result
    }
}
