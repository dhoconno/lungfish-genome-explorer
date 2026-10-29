// NaoMgsBamMaterializer+Orientation.swift - The strand a NAO-MGS mate is stored on in the BAM
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3

/// Which side of the strand fix a NAO-MGS BAM is on (Phase 3.1 lane NAO-BAM-STALE, ruling UX-NAO-BAM-STALE 3).
public enum NaoMgsBamOrientation: Sendable, Equatable {
    /// Every 0x10 record is stored on the reference strand, as the materializer has written them since `VN:1.1`.
    case referenceStrand
    /// The BAM was made before the strand fix, or nothing in its header says it was not.
    case beforeStrandFix
}

extension NaoMgsBamMaterializer {
    /// SAM stores a 0x10 record on the reference strand, SEQ reverse-complemented and QUAL reversed. NAO-MGS
    /// `query_seq` and `query_seq_rev` hold each mate as sequenced, and `prim_align_query_rc` names its strand.
    /// The helper sits in this file because `NaoMgsBamMaterializer.swift` is at the 800-line limit.
    static func referenceOriented(sequence: String, quality: String, reverse: Bool) -> (sequence: String, quality: String) {
        guard reverse else { return (sequence, quality) }
        let bases = String(sequence.reversed().map { complementOfBase[$0] ?? "N" })
        return (bases, quality == "*" ? quality : String(quality.reversed()))
    }

    /// The IUPAC complements in both cases. Any other character reads as `N`.
    private static let complementOfBase: [Character: Character] = [
        "A": "T", "T": "A", "C": "G", "G": "C", "N": "N", "R": "Y", "Y": "R", "K": "M", "M": "K",
        "B": "V", "V": "B", "D": "H", "H": "D", "S": "S", "W": "W",
        "a": "t", "t": "a", "c": "g", "g": "c", "n": "n", "r": "y", "y": "r", "k": "m", "m": "k",
        "b": "v", "v": "b", "d": "h", "h": "d", "s": "s", "w": "w",
    ]

    /// The `VN:` the materializer writes on its `@PG` line, and the first version that stores reverse-strand records
    /// on the reference strand. The writer and the check share it, so a later bump to 1.2 still passes the check.
    public static let headerVersion = "1.1"

    /// The `ID:` of the materializer's `@PG` line.
    static let headerProgramID = "lungfish-naomgs-materializer"

    /// The orientation of a BAM from the text of its header. A BAM counts as fixed when an `@PG` line has
    /// `ID:lungfish-naomgs-materializer` and a `VN:` of ``headerVersion`` or later, compared as numbers (major, then
    /// minor) and never as a string. Every other header, including one with no such line, is refused, since its
    /// orientation is unknown and a refusal states no false fact (ruling UX-NAO-BAM-STALE 3, the marker rule).
    public static func orientation(ofHeader header: String) -> NaoMgsBamOrientation {
        guard let fixed = versionNumbers(headerVersion) else { return .beforeStrandFix }
        for line in header.split(whereSeparator: \.isNewline) where line.hasPrefix("@PG") {
            let fields = line.split(separator: "\t")
            guard fields.contains(where: { $0 == "ID:\(headerProgramID)" }),
                  let field = fields.first(where: { $0.hasPrefix("VN:") }),
                  let version = versionNumbers(String(field.dropFirst(3))) else { continue }
            if (version.major, version.minor) >= (fixed.major, fixed.minor) { return .referenceStrand }
        }
        return .beforeStrandFix
    }

    /// The orientation of a BAM, read with one `samtools view -H`. Throws when samtools cannot read the header, so a
    /// caller never takes a file it could not read for a BAM made before the fix.
    public static func orientation(ofBAM bamURL: URL, samtoolsPath: String) throws -> NaoMgsBamOrientation {
        let spec = ToolProcessSpec(
            executableURL: URL(fileURLWithPath: samtoolsPath),
            arguments: ["view", "-H", bamURL.path],
            environment: ToolProcessSpec.inheritedEnvironment(),
            stderr: .discard,
            label: "samtools view -H"
        )
        let result = try ToolProcess.runBlocking(spec)
        guard result.isSuccess, let header = String(data: result.stdout, encoding: .utf8) else {
            throw NSError(
                domain: "NaoMgsBamMaterializer", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "samtools could not read the header of \(bamURL.lastPathComponent)"]
            )
        }
        return orientation(ofHeader: header)
    }

    /// Whether `virus_hits` holds a row of `sample`. The import deletes every stored read once it has written the BAMs,
    /// so a database after the import has the accessions of a sample and none of its reads, and a BAM written from it
    /// would hold a header and no reads (ruling UX-NAO-BAM-STALE 2). The materializer writes no BAM for such a sample.
    static func sampleHasVirusHits(db: OpaquePointer?, sample: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM virus_hits WHERE sample = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        _ = sample.withCString { sqlite3_bind_text(statement, 1, $0, -1, sqliteTransientDestructor) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// The major and minor number of a version such as `1.1` or `1.10`, nil when either is not a number.
    private static func versionNumbers(_ text: String) -> (major: Int, minor: Int)? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        if parts.count == 1 { return (major, 0) }
        guard let minor = Int(parts[1]) else { return nil }
        return (major, minor)
    }
}
