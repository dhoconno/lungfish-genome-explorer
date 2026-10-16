// TaxTriageParityLiveConformanceTests+Payloads.swift - BIO's per-sample compare of TaxTriage payload files by SHA-256
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane Q32, BIO's R7 of 2.10 and row 5 of BIO's 2.11 memo. A sample's payload is every file of the
// run's analysis folder whose name starts with the sample's name and a dot, as TaxTriage names its per-sample
// outputs (`report/<sample>.odr.txt`, `top/<sample>.top_report.tsv`, `combine/<sample>.combined.gcfmap.tsv`,
// `minimap2/<sample>.<sample>.dwnld.references.bam`). The longest sample name wins, so a sample named `S 1.v2`
// keeps `S 1.v2.odr.txt` from a sample named `S 1`. Records, hidden files and files below a hidden folder are
// left out, and so is a folder named as the sample, so a batch's sample folder pairs with a single result.
//
// Each file is hashed and saved (+Evidence.swift). BIO's memo names the report, the per-read output and the kept
// reads, and the 2.10 brief `.odr.txt` and `.top_report.tsv`. The compare asserts on the three kinds of the memo,
// which hold the brief's two files, and records every other file of the sample (QC pages, accession maps) without
// asserting on it, so BIO reads those from the evidence first. `all.odr.json`, the file of every sample, is no
// sample's payload. TaxTriageParityODRJSON (+Evidence.swift) names its differing keys and never asserts on them
// (BIO R3).
//
// On the real engine a BAM and its index compare by their canonical digest and not by their bytes (`canonicalDigest`,
// Q32 X1 ruling F2). Build-db's duplicate marking writes the absolute paths of each side's own folders into the
// `@PG` command lines, so two identical runs never give the same bytes. The file's own SHA-256 stays in the evidence.

import CryptoKit
import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// What a payload file of a sample holds, in the words of BIO's memo row 5.
enum TaxTriageParityPayloadKind: String, Sendable, CaseIterable {
    /// The organism report, the top report and the Kraken2 report.
    case report
    /// Kraken2's classification of each read.
    case perReadOutput = "per-read output"
    /// The reads TaxTriage keeps, an alignment with its index or a FASTQ.
    case keptReads = "kept reads"
    /// Any other file of the sample, recorded and not asserted.
    case other

    static func of(_ fileName: String) -> TaxTriageParityPayloadKind {
        let name = fileName.lowercased()
        let readSuffixes = [".bam", ".bam.bai", ".bai", ".csi", ".fastq", ".fastq.gz", ".fq", ".fq.gz"]
        if readSuffixes.contains(where: { name.hasSuffix($0) }) { return .keptReads }
        let reportSuffixes = [".odr.txt", ".organisms.report.txt", ".top_report.tsv"]
        if reportSuffixes.contains(where: { name.hasSuffix($0) }) || (name.contains("kraken") && name.contains("report")) {
            return .report
        }
        if name.contains("kraken") { return .perReadOutput }
        return .other
    }

    /// Whether a difference of this kind fails the compare.
    var isAsserted: Bool { self != .other }
}

/// One payload file of one sample on one side, by SHA-256.
struct TaxTriageParityPayload: Hashable, Sendable {
    let sample: String
    /// The file's path in the analysis folder without any folder named as the sample.
    let key: String
    /// The file's path relative to the side root.
    let path: String
    let kind: TaxTriageParityPayloadKind
    /// The digest the compare reads. On the real engine a BAM and its index carry their canonical digest
    /// (`TaxTriageParityPayloads.canonicalDigest`, Q32 X1 ruling F2) and every other file its SHA-256.
    let sha256: String
    /// The SHA-256 of the file's bytes.
    let rawSHA256: String
    let size: Int64

    func withSHA256(_ value: String) -> TaxTriageParityPayload {
        TaxTriageParityPayload(sample: sample, key: key, path: path, kind: kind, sha256: value, rawSHA256: rawSHA256, size: size)
    }
}

enum TaxTriageParityPayloads {
    /// The payload differences the live compare declares, each with its count in a case. The list only shrinks.
    static let declared: [TaxTriageParityKnownDifference] = [
        TaxTriageParityKnownDifference(
            counts: [.x1: 1],
            scope: .pair(.a, .c),
            id: "report: *: only in C: top/*.top_report.tsv",
            reason: "Side A's build-db cleanup deletes top/ (performCleanupForSingleResult in BuildDbCommand+TaxTriageCore.swift), "
                + "and the executor's finalize keeps it (2.8 T5, row 258), as the folder compare declares",
            closedBy: TaxTriageParityKnownDifferences.guiRoute
        ),
    ]

    /// The folders side A's cleanup deletes after a run (`performCleanupForSingleResult`, BuildDbCommand+TaxTriageCore.swift:479-514),
    /// and `fastp/` for its FASTQ files. A file that only side C holds in one of them is the GUI route's cleanup. A against C
    /// records it in `payload-compare.txt` and does not fail on it. The `top/` declaration above keeps its own count.
    static let cleanedByTheGUIRoute: Set<String> = [
        "count", "filterkraken", "get", "map", "samtools", "bedtools", "top", "mergedsubspecies", "mergedkrakenreport",
    ]

    /// Whether `difference` names a file only side C holds in a folder that side A's cleanup deletes.
    static func isCleanedByTheGUIRoute(_ difference: TaxTriageParityDifference) -> Bool {
        guard let marker = difference.id.range(of: ": only in C: ") else { return false }
        let key = String(difference.id[marker.upperBound...])
        let parts = key.split(separator: "/").map(String.init)
        guard parts.count > 1, let folder = parts.first else { return false }
        let name = key.lowercased()
        return cleanedByTheGUIRoute.contains(folder) || (folder == "fastp" && (name.hasSuffix(".fastq") || name.hasSuffix(".gz")))
    }

    /// Whether `fact` is one of side A's record-against-disk facts that the legacy GUI route's cleanup leaves false
    /// (Q32 X1 ruling F3). The id ends ` that does not exist` and the file it names, below the analysis folder, lies in
    /// a folder of `cleanedByTheGUIRoute` or is a FASTQ of `fastp/`. A name with another digest is not one, and a top
    /// report is never one, since the counted `*top/*.top_report.tsv` entry of TaxTriageParityKnownDifferences stays.
    static func isRemovedByTheGUIRouteCleanup(_ fact: TaxTriageParityDifference) -> Bool {
        let ending = " that does not exist"
        guard fact.id.hasSuffix(ending), let names = fact.id.range(of: " names "),
              let analyses = fact.id.range(of: "/Analyses/", range: names.upperBound..<fact.id.endIndex) else { return false }
        // Below `<project>/Analyses/` come the analysis folder, the file's folder and the file.
        let parts = fact.id[analyses.upperBound...].dropLast(ending.count).split(separator: "/").map(String.init)
        guard parts.count > 2, let name = parts.last?.lowercased(), !name.hasSuffix(".top_report.tsv") else { return false }
        return cleanedByTheGUIRoute.contains(parts[1]) || (parts[1] == "fastp" && (name.hasSuffix(".fastq") || name.hasSuffix(".gz")))
    }

    /// The sample names of `run`, as the request and the engine wrote them: the case's samples, the result's and the
    /// organism reports'.
    static func sampleNames(of run: TaxTriageParitySideRun, parityCase: TaxTriageParityCase) -> [String] {
        var names = Set(parityCase.bundlePaths.map { TaxTriageParitySampleFacts.forBundle($0).sampleID })
        if let analysis = run.analysisFolder, let result = try? TaxTriageResult.load(from: analysis) {
            names.formUnion(result.config.samples.map(\.sampleId))
            names.formUnion(result.reportFiles.compactMap(TaxTriageOrganismReport.sampleID(fromReportFile:)))
        }
        return names.sorted()
    }

    /// Each payload file of the run's analysis folder, none when the run made no folder. With `samtools` a BAM and
    /// its index carry their canonical digest (`canonicalDigest`), as the real engine's pass reads them.
    static func payloads(
        of run: TaxTriageParitySideRun, parityCase: TaxTriageParityCase, samtools: URL?
    ) throws -> [TaxTriageParityPayload] {
        guard let analysisPath = run.analysisPath, let analysis = run.analysisFolder,
              FileManager.default.fileExists(atPath: analysis.path) else { return [] }
        return try payloads(
            in: analysis, samples: sampleNames(of: run, parityCase: parityCase), pathPrefix: analysisPath, samtools: samtools
        )
    }

    /// Each file below `analysis` whose name starts with one of `samples` and a dot, the longest name first, by
    /// sample and key. `pathPrefix` goes before each file's path in the folder. `samtools` is set on the real engine.
    static func payloads(
        in analysis: URL, samples: [String], pathPrefix: String, samtools: URL?
    ) throws -> [TaxTriageParityPayload] {
        let longestFirst = samples.sorted { $0.count > $1.count }
        var found: [TaxTriageParityPayload] = []
        var keys: Set<String> = []
        for relative in TaxTriageParityComparison.Rules.relativeFiles(under: analysis) {
            let components = relative.split(separator: "/").map(String.init)
            guard let name = components.last, !components.contains(where: { $0.hasPrefix(".") }),
                  !TaxTriageParityComparison.Rules.isRecordName(relative),
                  let sample = longestFirst.first(where: { name.hasPrefix($0 + ".") }) else { continue }
            var key = (components.dropLast().filter { $0 != sample } + [name]).joined(separator: "/")
            while keys.contains("\(sample)/\(key)") { key += "#again" }
            keys.insert("\(sample)/\(key)")
            let file = analysis.appendingPathComponent(relative)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let raw = try ClassifierParityFixtures.sha256(of: file)
            found.append(TaxTriageParityPayload(
                sample: sample,
                key: key,
                path: pathPrefix.isEmpty ? relative : "\(pathPrefix)/\(relative)",
                kind: .of(name),
                sha256: try samtools.map { try canonicalDigest(of: file, samtools: $0) } ?? raw,
                rawSHA256: raw,
                size: Int64(size)
            ))
        }
        return found.sorted { ($0.sample, $0.key) < ($1.sample, $1.key) }
    }

    // MARK: - Canonical digests

    /// The digest the real engine's compare reads for `file` (Q32 X1 ruling F2). Build-db's duplicate marking writes
    /// the absolute paths of the side's own folders and a random scratch folder into the `CL:` field of four `@PG`
    /// lines, so two identical runs never give the same BAM or index bytes. A BAM compares by `samtools view -H
    /// --no-PG` with the `CL:` field of each `@PG` line removed, followed by `samtools view --no-PG`, so a differing
    /// record, header line or `@PG` ID, PN, PP or VN still differs. A `.bai` or `.csi` whose BAM, its name without
    /// that suffix, sits beside it compares by `samtools idxstats` of that BAM, since the virtual offsets of an index
    /// move with the compressed header. Any other file gets its SHA-256. A samtools exit other than 0 throws.
    static func canonicalDigest(of file: URL, samtools: URL) throws -> String {
        let name = file.lastPathComponent
        let lowered = name.lowercased()
        if lowered.hasSuffix(".bam") {
            let header = try samtoolsOutput(samtools, ["view", "-H", "--no-PG", file.path])
            let records = try samtoolsOutput(samtools, ["view", "--no-PG", file.path])
            return hexDigest(of: withoutCommandLines(header) + records)
        }
        for suffix in [".bai", ".csi"] where lowered.hasSuffix(suffix) {
            let bam = file.deletingLastPathComponent().appendingPathComponent(String(name.dropLast(suffix.count)))
            if bam.pathExtension.lowercased() == "bam", FileManager.default.fileExists(atPath: bam.path) {
                return hexDigest(of: try samtoolsOutput(samtools, ["idxstats", bam.path]))
            }
        }
        return try ClassifierParityFixtures.sha256(of: file)
    }

    /// `header` with the field that starts `CL:` removed from each `@PG` line. Every other field and line stays.
    static func withoutCommandLines(_ header: String) -> String {
        header.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("@PG\t") else { return String(line) }
            return line.split(separator: "\t", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix("CL:") }
                .joined(separator: "\t")
        }
        .joined(separator: "\n")
    }

    private static func samtoolsOutput(_ samtools: URL, _ arguments: [String]) throws -> String {
        let result = try ProcessRunner.run(samtools, arguments, timeout: 120)
        guard result.status == 0 else {
            throw LiveNextflowError.misconfigured("samtools \(arguments.joined(separator: " ")) exited \(result.status), \(result.stderr)")
        }
        return result.stdout
    }

    private static func hexDigest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// How `candidate`'s payloads differ from `reference`'s, one difference per file: a sample with no payload on a
    /// side, a file only one side holds, or a file whose SHA-256 differs. The id starts with the file's kind.
    static func differences(
        reference: [TaxTriageParityPayload], _ referenceSide: TaxTriageParitySide,
        candidate: [TaxTriageParityPayload], _ candidateSide: TaxTriageParitySide
    ) -> [TaxTriageParityDifference] {
        func index(_ payloads: [TaxTriageParityPayload]) -> [String: TaxTriageParityPayload] {
            Dictionary(payloads.map { ("\($0.sample)\u{0}\($0.key)", $0) }, uniquingKeysWith: { first, _ in first })
        }
        let byReference = index(reference)
        let byCandidate = index(candidate)
        var found: [TaxTriageParityDifference] = []
        for sample in Set(reference.map(\.sample)).union(candidate.map(\.sample)).sorted() {
            for (side, payloads) in [(referenceSide, reference), (candidateSide, candidate)] where !payloads.contains(where: { $0.sample == sample }) {
                found.append(TaxTriageParityDifference(id: "report: \(sample): no payload in \(side)", detail: ""))
            }
        }
        for name in Set(byReference.keys).union(byCandidate.keys).sorted() {
            switch (byReference[name], byCandidate[name]) {
            case let (a?, c?) where a.sha256 != c.sha256:
                found.append(TaxTriageParityDifference(
                    id: "\(a.kind.rawValue): \(a.sample): differs: \(a.key)",
                    detail: "\(referenceSide) \(a.sha256) \(a.size) bytes, \(candidateSide) \(c.sha256) \(c.size) bytes"
                ))
            case let (a?, nil):
                found.append(TaxTriageParityDifference(id: "\(a.kind.rawValue): \(a.sample): only in \(referenceSide): \(a.key)", detail: a.sha256))
            case let (nil, c?):
                found.append(TaxTriageParityDifference(id: "\(c.kind.rawValue): \(c.sample): only in \(candidateSide): \(c.key)", detail: c.sha256))
            default:
                break
            }
        }
        return found
    }

    /// One line per asserted difference that no payload declaration holds, and per declaration that matches another
    /// number of differences than its count, as TaxTriageParityKnownDifferences.failures reads its own list. A
    /// difference of a file of kind `other` is recorded and never fails.
    static func failures(
        found: [TaxTriageParityDifference],
        parityCase: TaxTriageParityCase,
        scope: TaxTriageParityScope
    ) -> [String] {
        let asserted = found.filter { difference in
            !difference.id.hasPrefix(TaxTriageParityPayloadKind.other.rawValue + ":")
        }
        let entries = declared.filter { $0.counts[parityCase] != nil && $0.scope == scope }
        var lines = asserted
            .filter { difference in !entries.contains { $0.matches(difference) } }
            .filter { difference in !(scope == .pair(.a, .c) && isCleanedByTheGUIRoute(difference)) }
            .map { "not declared: \($0)" }
        for entry in entries {
            let matched = asserted.filter(entry.matches)
            let count = entry.counts[parityCase] ?? 0
            if matched.count != count {
                lines.append("\(matched.count) payload differences match, \(count) declared for \(parityCase.rawValue): \(entry.id)")
            }
        }
        return lines
    }

    /// One line per expected sample that `side` holds no payload of an asserted kind for. Without it a side that kept
    /// nothing compares equal to another side that kept nothing.
    static func missing(in payloads: [TaxTriageParityPayload], side: TaxTriageParitySide, expectedSamples: [String]) -> [String] {
        expectedSamples
            .filter { sample in !payloads.contains { $0.sample == sample && $0.kind.isAsserted } }
            .map { "side \(side) holds no report, per-read output or kept reads for \($0)" }
    }
}
