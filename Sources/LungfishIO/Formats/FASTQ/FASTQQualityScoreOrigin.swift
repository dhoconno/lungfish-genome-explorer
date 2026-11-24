// FASTQQualityScoreOrigin.swift - Whether the quality scores of a FASTQ file in a bundle were measured
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where the quality scores of the reads in a `.lungfishfastq` bundle come from (Phase 5.6 S1 sweep, lane QUALITY-2,
/// ruling BIO-QUALITY F1).
///
/// Reads built from sequence counts carry a written score of Q40 on every base that no instrument measured. Every view
/// or tool that measures such reads gets Q40 back as a measurement, so each asks this reader first and shows no score
/// for the reads it marks. The mark is the manifest's `qualityScoresArePlaceholders`. The access is `package`, since the
/// app, the workflow module and the tests share one package and no other client needs the type.
package enum FASTQQualityScoreOrigin {

    /// Whether the reads of `fastqURL` carry placeholder scores. `fastqURL` is a FASTQ file inside a `.lungfishfastq`
    /// bundle or the bundle itself. A file that sits in no bundle is false.
    ///
    /// A bundle whose own manifest holds no mark is read through its ancestors: a dataset made from a Fluidigm bundle
    /// before the mark existed (a subsample, a filter, a trim or a demultiplex) holds the written Q40 and none of the
    /// marks, so each manifest's `parentBundleRelativePath` is followed, resolved as the derived-bundle code resolves it,
    /// and the reads count as placeholder when any ancestor's manifest says so. The walk stops with false at a missing
    /// bundle, a bundle with no derived manifest, a bundle it has already seen or the sixteenth step, and it writes
    /// nothing (lane FLUIDIGM-CHILDREN F8, ruling BIO-FLUIDIGM-CHILDREN).
    ///
    /// Last, and also for a bundle with no derived manifest, the dataset's own reads are read: the reads count as
    /// placeholder when the first 64 records each carry the name `u000001;size=N` and a quality line of only `I`, the
    /// form `CountedFASTQMaterializer` writes. Every route that lost the manifest chain (Merge into New Bundle, a
    /// read-ID or classifier extraction, the ONT barcode demultiplex, a deleted or moved source) keeps those reads, so a
    /// delete, a move, a copy or an export keeps the mark. Nothing is written, and any read error gives false (lane
    /// FLUIDIGM-UNLINKED, ruling BIO-FLUIDIGM-UNLINKED).
    package static func readsCarryPlaceholderScores(fastqURL: URL) -> Bool {
        guard let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: fastqURL) else {
            return false
        }
        let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL)
        if let manifest, manifestChainCarriesPlaceholderScores(manifest, in: bundleURL) {
            return true
        }
        return ownReadsAreCountedReads(in: bundleURL, fastqURL: fastqURL, manifest: manifest)
    }

    /// How many records of a dataset's own reads the counted-read test looks at.
    private static let countedReadSampleSize = 64

    /// Ends the scan of a file early. It is no error.
    private struct StopReading: Error {}

    /// Whether the file that holds the dataset's own reads carries the counted-read signature: a `.full` payload's
    /// file, a `.demuxedVirtual` child's `preview.fastq`, or the bundle's physical FASTQ.
    private static func ownReadsAreCountedReads(
        in bundleURL: URL, fastqURL: URL, manifest: FASTQDerivedBundleManifest?
    ) -> Bool {
        let file: URL?
        switch manifest?.payload {
        case .full(let filename)?:
            file = bundleMember(filename, in: bundleURL)
        case .demuxedVirtual(_, _, let previewFilename, _, _)?:
            file = bundleMember(previewFilename, in: bundleURL)
        default:
            file = FASTQBundle.resolvePrimaryFASTQURL(for: fastqURL)
        }
        guard let file else { return false }
        return fileHoldsCountedReads(file)
    }

    /// `filename` inside `bundleURL`, or nil when it names a place outside the bundle.
    private static func bundleMember(_ filename: String, in bundleURL: URL) -> URL? {
        let root = bundleURL.standardizedFileURL
        let member = root.appendingPathComponent(filename).standardizedFileURL
        return member.path.hasPrefix(root.path + "/") ? member : nil
    }

    /// True when at least one record is read and each of the first 64 records has a first name token that begins
    /// `u`, six or more digits, `;size=` and a digit, and a quality line of only `I`. Plain or gzip, the same line
    /// reader the FASTQ reader uses. A file that cannot be read, an empty file and a file that is not FASTQ give false.
    private static func fileHoldsCountedReads(_ file: URL) -> Bool {
        var lineIndex = 0
        var records = 0
        var counted = true
        do {
            try file.forEachLineAutoDecompressing { line in
                defer { lineIndex += 1 }
                switch lineIndex % 4 {
                case 0:
                    if line.isEmpty {
                        if records == 0 { counted = false }
                        throw StopReading()
                    }
                    guard Self.hasCountedReadName(line) else {
                        counted = false
                        throw StopReading()
                    }
                case 3:
                    guard line.utf8.allSatisfy({ $0 == UInt8(ascii: "I") }) else {
                        counted = false
                        throw StopReading()
                    }
                    records += 1
                    if records >= Self.countedReadSampleSize { throw StopReading() }
                default:
                    break
                }
            }
        } catch is StopReading {
            // A bounded early exit, or the end of the records.
        } catch {
            return false
        }
        return counted && records > 0
    }

    /// Whether a header line reads `@u`, six or more digits, `;size=` and a digit: `^u[0-9]{6,};size=[0-9]+` on the
    /// first name token. LGE's own zero-padded counted name, which no instrument and no common tool writes.
    private static func hasCountedReadName(_ header: String) -> Bool {
        var rest = header.utf8.dropFirst()
        guard header.utf8.first == UInt8(ascii: "@"), rest.first == UInt8(ascii: "u") else { return false }
        rest = rest.dropFirst()
        let digits = rest.prefix(while: { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") })
        guard digits.count >= 6 else { return false }
        rest = rest.dropFirst(digits.count)
        let marker = Array(";size=".utf8)
        guard rest.starts(with: marker) else { return false }
        rest = rest.dropFirst(marker.count)
        guard let first = rest.first else { return false }
        return first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9")
    }

    /// The own mark and the walk through the ancestors' manifests (lane FLUIDIGM-CHILDREN F8).
    private static func manifestChainCarriesPlaceholderScores(
        _ manifest: FASTQDerivedBundleManifest, in bundleURL: URL
    ) -> Bool {
        if carryPlaceholderScores(manifest) {
            return true
        }
        var visited: Set<String> = [bundleURL.standardizedFileURL.path]
        var current = bundleURL.standardizedFileURL
        var currentManifest = manifest
        for _ in 0..<16 {
            let parent = FASTQBundle.resolveBundle(relativePath: currentManifest.parentBundleRelativePath, from: current)
                .standardizedFileURL
            guard !visited.contains(parent.path),
                  FASTQBundle.isBundleURL(parent),
                  FileManager.default.fileExists(atPath: parent.path),
                  let parentManifest = FASTQBundle.loadDerivedManifest(in: parent) else {
                return false
            }
            if carryPlaceholderScores(parentManifest) {
                return true
            }
            visited.insert(parent.path)
            current = parent
            currentManifest = parentManifest
        }
        return false
    }

    /// The same reading for a manifest in hand. True when the manifest holds the mark. A bundle made before the field
    /// existed is recognized by what both Fluidigm materializers wrote beside it, a demultiplex operation and a library
    /// prep that begins "Fluidigm Access Array" ("Fluidigm Access Array MHC amplicon" for the amplicon route).
    package static func carryPlaceholderScores(_ manifest: FASTQDerivedBundleManifest) -> Bool {
        if manifest.qualityScoresArePlaceholders == true {
            return true
        }
        return manifest.operation.kind == .demultiplex
            && manifest.provenance?.libraryPrep?.hasPrefix("Fluidigm Access Array") == true
    }
}
