#!/usr/bin/env swift
// build-primer-bundle.swift
// Authoring tool for .lungfishprimers bundles.
//
// Reads a BED6 primer file, fetches the canonical and equivalent reference
// accessions from NCBI eutils efetch, verifies their sequence bodies are
// byte-identical (refusing to emit on mismatch), computes primer/amplicon
// counts, and writes a manifest.json + primers.bed + primers.fasta?
// + PROVENANCE.md stub bundle.
//
// Standalone Swift script: depends only on Foundation. Invoke as either:
//   swift scripts/build-primer-bundle.swift --name … --bed … --output …
//   ./scripts/build-primer-bundle.swift  --name … --bed … --output …
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2024 Lungfish Contributors

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Argument parsing

struct Arguments {
    var name: String?
    var displayName: String?
    var description: String?
    var organism: String?
    var canonical: String?
    var equivalents: [String] = []
    var bed: String?
    var fasta: String?
    var sourceURL: String?
    var source: String = "built-in"
    var version: String = "1.0.0"
    var output: String?
    var help: Bool = false
}

let usage = """
Usage: swift scripts/build-primer-bundle.swift [options]

Required:
  --name             <NAME>            Manifest name (e.g. QIASeqDIRECT-SARS2)
  --display-name     <"DISPLAY NAME"> User-facing label
  --canonical        <ACCESSION>       Canonical reference accession (e.g. MN908947.3)
  --bed              <PATH>            BED6 primers file
  --output           <PATH>            Output bundle path (.lungfishprimers directory)

Optional:
  --description      <"PROSE">
  --organism         <"ORG">           e.g. "Severe acute respiratory syndrome coronavirus 2"
  --equivalent       <ACCESSION>       Equivalent reference accession (repeatable)
  --fasta            <PATH>            Optional primers.fasta to bundle
  --source-url       <URL>             Provenance URL (written to manifest.source_url)
  --source           <STRING>          Defaults to "built-in"
  --version          <STRING>          Defaults to "1.0.0"
  -h, --help         Print this message

Behavior:
  - Validates BED6+ rows whose chrom matches --canonical.
  - Fetches each accession from NCBI eutils efetch and SHA256-hashes the
    sequence body (header line stripped, all whitespace removed).
  - Refuses to emit if any equivalent's hash differs from the canonical's.
  - Computes primer_count and amplicon_count from the BED.
  - Writes manifest.json, primers.bed, optionally primers.fasta, and a
    PROVENANCE.md stub the maintainer is expected to overwrite.
"""

func parseArguments(_ argv: [String]) throws -> Arguments {
    var args = Arguments()
    var i = 1
    while i < argv.count {
        let token = argv[i]
        func next() throws -> String {
            i += 1
            guard i < argv.count else {
                throw ScriptError.missingValue(option: token)
            }
            return argv[i]
        }
        switch token {
        case "-h", "--help":
            args.help = true
        case "--name":
            args.name = try next()
        case "--display-name":
            args.displayName = try next()
        case "--description":
            args.description = try next()
        case "--organism":
            args.organism = try next()
        case "--canonical":
            args.canonical = try next()
        case "--equivalent":
            args.equivalents.append(try next())
        case "--bed":
            args.bed = try next()
        case "--fasta":
            args.fasta = try next()
        case "--source-url":
            args.sourceURL = try next()
        case "--source":
            args.source = try next()
        case "--version":
            args.version = try next()
        case "--output":
            args.output = try next()
        default:
            throw ScriptError.unknownArgument(token)
        }
        i += 1
    }
    return args
}

// MARK: - Errors

enum ScriptError: Error, CustomStringConvertible {
    case missingValue(option: String)
    case unknownArgument(String)
    case missingRequired(String)
    case bedNotReadable(String)
    case bedMalformedRow(line: Int, detail: String)
    case bedChromMismatch(line: Int, found: String, expected: String)
    case fetchFailure(accession: String, detail: String)
    case sequenceMismatch(canonical: String, canonicalHash: String, equivalent: String, equivalentHash: String)
    case outputExists(String)
    case outputCreate(String, underlying: Error)

    var description: String {
        switch self {
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .unknownArgument(let token):
            return "Unknown argument: \(token)."
        case .missingRequired(let name):
            return "Missing required argument: --\(name)."
        case .bedNotReadable(let path):
            return "Cannot read BED file at \(path)."
        case .bedMalformedRow(let line, let detail):
            return "Malformed BED row at line \(line): \(detail)."
        case .bedChromMismatch(let line, let found, let expected):
            return "BED row \(line) chrom \(found) does not match canonical \(expected)."
        case .fetchFailure(let accession, let detail):
            return "Failed to fetch \(accession): \(detail)."
        case .sequenceMismatch(let canonical, let canonicalHash, let equivalent, let equivalentHash):
            return """
            Reference sequence mismatch.
              \(canonical) SHA256 = \(canonicalHash)
              \(equivalent) SHA256 = \(equivalentHash)
            Refusing to emit bundle.
            """
        case .outputExists(let path):
            return "Output directory already exists: \(path). Remove or pass a fresh path."
        case .outputCreate(let path, let underlying):
            return "Failed to create output \(path): \(underlying.localizedDescription)"
        }
    }
}

// MARK: - BED parsing

struct BEDStats {
    var primerCount: Int
    var ampliconCount: Int
}

func validateAndCountBED(path: String, canonicalChrom: String) throws -> BEDStats {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else {
        throw ScriptError.bedNotReadable(path)
    }
    var primerCount = 0
    var amplicons = Set<String>()
    var lineNumber = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        lineNumber += 1
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        let fields = trimmed.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6 else {
            throw ScriptError.bedMalformedRow(
                line: lineNumber,
                detail: "expected at least 6 tab-separated fields, found \(fields.count)"
            )
        }
        let chrom = fields[0]
        if chrom != canonicalChrom {
            throw ScriptError.bedChromMismatch(line: lineNumber, found: chrom, expected: canonicalChrom)
        }
        guard Int(fields[1]) != nil, Int(fields[2]) != nil else {
            throw ScriptError.bedMalformedRow(line: lineNumber, detail: "start/end must be integers")
        }
        let strand = fields[5]
        guard strand == "+" || strand == "-" else {
            throw ScriptError.bedMalformedRow(line: lineNumber, detail: "strand must be + or -, found \(strand)")
        }
        primerCount += 1
        amplicons.insert(ampliconName(from: fields[3]))
    }
    return BEDStats(primerCount: primerCount, ampliconCount: amplicons.count)
}

/// Strip the trailing `_LEFT` / `_RIGHT` segment plus any preceding `-N`
/// variant tag from a primer name. e.g. `QIAseq_221-2_LEFT` → `QIAseq_221`.
func ampliconName(from primerName: String) -> String {
    var name = primerName
    if name.hasSuffix("_LEFT") {
        name.removeLast("_LEFT".count)
    } else if name.hasSuffix("_RIGHT") {
        name.removeLast("_RIGHT".count)
    }
    // Strip a trailing `-N` variant tag (digits only).
    if let dashIndex = name.lastIndex(of: "-") {
        let afterDash = name.index(after: dashIndex)
        let suffix = name[afterDash...]
        if !suffix.isEmpty && suffix.allSatisfy({ $0.isASCII && $0.isNumber }) {
            name.removeSubrange(dashIndex..<name.endIndex)
        }
    }
    return name
}

// MARK: - NCBI fetch

func fetchSequence(accession: String) throws -> String {
    let urlString = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=\(accession)&rettype=fasta&retmode=text"
    guard let url = URL(string: urlString) else {
        throw ScriptError.fetchFailure(accession: accession, detail: "invalid URL: \(urlString)")
    }
    FileHandle.standardError.write(Data("→ fetching \(accession) from NCBI eutils…\n".utf8))
    let semaphore = DispatchSemaphore(value: 0)
    var body: Data?
    var responseCode = -1
    var fetchError: Error?
    let task = URLSession.shared.dataTask(with: url) { data, response, error in
        body = data
        if let http = response as? HTTPURLResponse {
            responseCode = http.statusCode
        }
        fetchError = error
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()
    if let fetchError {
        throw ScriptError.fetchFailure(accession: accession, detail: fetchError.localizedDescription)
    }
    guard responseCode == 200 else {
        throw ScriptError.fetchFailure(accession: accession, detail: "HTTP \(responseCode)")
    }
    guard let data = body, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
        throw ScriptError.fetchFailure(accession: accession, detail: "empty response")
    }
    return text
}

/// Returns the lower-cased hex SHA256 of the FASTA's sequence body
/// (everything after the first newline, with all whitespace removed).
///
/// Throws when the FASTA lacks a header, lacks a body separator, or has
/// an empty body after whitespace removal — these all indicate a malformed
/// efetch response and would otherwise hash to a value that compares equal
/// across two empty responses, falsely passing the equivalence check.
func sequenceHash(fasta: String, accession: String) throws -> String {
    guard fasta.hasPrefix(">") else {
        throw ScriptError.fetchFailure(accession: accession, detail: "response is not a FASTA (missing > header)")
    }
    guard let firstNewline = fasta.firstIndex(of: "\n") else {
        throw ScriptError.fetchFailure(accession: accession, detail: "FASTA has no body (no newline after header)")
    }
    let body = fasta[fasta.index(after: firstNewline)...]
    var bytes = [UInt8]()
    bytes.reserveCapacity(body.utf8.count)
    for byte in body.utf8 where byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
        bytes.append(byte)
    }
    guard !bytes.isEmpty else {
        throw ScriptError.fetchFailure(accession: accession, detail: "FASTA body is empty after whitespace stripping")
    }
    return SHA256.hexDigest(bytes)
}

// MARK: - SHA256 (pure Swift, Foundation only)

enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hexDigest(_ message: [UInt8]) -> String {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        var padded = message
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0x00)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> shift) & 0xFF))
        }

        for blockStart in stride(from: 0, to: padded.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let base = blockStart + i * 4
                w[i] = (UInt32(padded[base]) << 24)
                    | (UInt32(padded[base + 1]) << 16)
                    | (UInt32(padded[base + 2]) << 8)
                    | UInt32(padded[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let mj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ mj
                hh = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }

        var hex = ""
        hex.reserveCapacity(64)
        for word in h {
            hex += String(format: "%08x", word)
        }
        return hex
    }

    @inline(__always)
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return (x >> n) | (x << (32 - n))
    }
}

// MARK: - Manifest emission

func emitBundle(args: Arguments, stats: BEDStats) throws {
    let outputPath = args.output!
    let outputURL = URL(fileURLWithPath: outputPath)
    let fm = FileManager.default

    if fm.fileExists(atPath: outputPath) {
        try fm.removeItem(at: outputURL)
    }
    do {
        try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
    } catch {
        throw ScriptError.outputCreate(outputPath, underlying: error)
    }

    // Build manifest dictionary preserving snake_case keys.
    var refs: [[String: Any]] = []
    refs.append(["accession": args.canonical!, "canonical": true])
    for accession in args.equivalents {
        refs.append(["accession": accession, "equivalent": true])
    }

    let createdISO = ISO8601DateFormatter().string(from: Date())

    var manifest: [String: Any] = [
        "schema_version": 1,
        "name": args.name!,
        "display_name": args.displayName!,
        "reference_accessions": refs,
        "primer_count": stats.primerCount,
        "amplicon_count": stats.ampliconCount,
        "source": args.source,
        "version": args.version,
        "created": createdISO,
    ]
    if let description = args.description {
        manifest["description"] = description
    }
    if let organism = args.organism {
        manifest["organism"] = organism
    }
    if let sourceURL = args.sourceURL {
        manifest["source_url"] = sourceURL
    }

    // Emit manifest with a stable, human-readable key order.
    let keyOrder: [String] = [
        "schema_version", "name", "display_name", "description", "organism",
        "reference_accessions", "primer_count", "amplicon_count",
        "source", "source_url", "version", "created"
    ]

    var manifestText = "{\n"
    var emittedKeys: [String] = []
    for key in keyOrder where manifest[key] != nil {
        emittedKeys.append(key)
    }
    for (idx, key) in emittedKeys.enumerated() {
        let value = manifest[key]!
        let serialized = try jsonEncode(value, indent: 2)
        let trailingComma = idx < emittedKeys.count - 1 ? "," : ""
        manifestText += "  \"\(key)\": \(serialized)\(trailingComma)\n"
    }
    manifestText += "}\n"
    try manifestText.write(
        to: outputURL.appendingPathComponent("manifest.json"),
        atomically: true,
        encoding: .utf8
    )

    // Copy primers.bed.
    let bedDest = outputURL.appendingPathComponent("primers.bed")
    if fm.fileExists(atPath: bedDest.path) {
        try fm.removeItem(at: bedDest)
    }
    try fm.copyItem(
        at: URL(fileURLWithPath: args.bed!),
        to: bedDest
    )

    // Copy primers.fasta if provided.
    if let fastaPath = args.fasta {
        let fastaDest = outputURL.appendingPathComponent("primers.fasta")
        if fm.fileExists(atPath: fastaDest.path) {
            try fm.removeItem(at: fastaDest)
        }
        try fm.copyItem(at: URL(fileURLWithPath: fastaPath), to: fastaDest)
    }

    // PROVENANCE.md stub. The maintainer is expected to overwrite this by hand
    // (see PLAN.md task 11 step 4) before committing the bundle.
    let stub = """
    # PROVENANCE — \(args.displayName!)

    Generated by `scripts/build-primer-bundle.swift` on \(createdISO).
    Source BED: \(URL(fileURLWithPath: args.bed!).lastPathComponent)
    Canonical reference: \(args.canonical!)
    Equivalent references: \(args.equivalents.isEmpty ? "(none)" : args.equivalents.joined(separator: ", "))

    Replace this file with hand-curated provenance prose before committing.
    """
    try stub.write(
        to: outputURL.appendingPathComponent("PROVENANCE.md"),
        atomically: true,
        encoding: .utf8
    )
}

/// Small JSON serialiser that emits arrays/dicts/scalars at the given indent.
/// We hand-roll this so the manifest stays stable and human-diffable; using
/// JSONSerialization without sortedKeys produces unstable orderings.
func jsonEncode(_ value: Any, indent: Int) throws -> String {
    if let s = value as? String {
        return jsonString(s)
    }
    if let n = value as? Int {
        return String(n)
    }
    if let n = value as? Double {
        return String(n)
    }
    if let b = value as? Bool {
        return b ? "true" : "false"
    }
    if let arr = value as? [Any] {
        if arr.isEmpty { return "[]" }
        var out = "[\n"
        for (idx, item) in arr.enumerated() {
            let serialized = try jsonEncode(item, indent: indent + 2)
            let pad = String(repeating: " ", count: indent + 2)
            out += "\(pad)\(serialized)"
            if idx < arr.count - 1 { out += "," }
            out += "\n"
        }
        out += String(repeating: " ", count: indent) + "]"
        return out
    }
    if let dict = value as? [String: Any] {
        if dict.isEmpty { return "{}" }
        // Preserve insertion-friendly order: known keys first, then any extras alpha.
        let preferred = ["accession", "canonical", "equivalent"]
        var keys: [String] = []
        for k in preferred where dict[k] != nil { keys.append(k) }
        for k in dict.keys.sorted() where !keys.contains(k) { keys.append(k) }
        var out = "{\n"
        for (idx, key) in keys.enumerated() {
            let pad = String(repeating: " ", count: indent + 2)
            let serialized = try jsonEncode(dict[key]!, indent: indent + 2)
            out += "\(pad)\(jsonString(key)): \(serialized)"
            if idx < keys.count - 1 { out += "," }
            out += "\n"
        }
        out += String(repeating: " ", count: indent) + "}"
        return out
    }
    throw NSError(
        domain: "build-primer-bundle",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported manifest value: \(value)"]
    )
}

func jsonString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}

// MARK: - Main

@discardableResult
func run(_ argv: [String]) -> Int32 {
    let args: Arguments
    do {
        args = try parseArguments(argv)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n\n".utf8))
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 2
    }
    if args.help || argv.count <= 1 {
        print(usage)
        return args.help ? 0 : 2
    }

    func require(_ value: String?, name: String) throws -> String {
        guard let value, !value.isEmpty else { throw ScriptError.missingRequired(name) }
        return value
    }

    do {
        _ = try require(args.name, name: "name")
        _ = try require(args.displayName, name: "display-name")
        _ = try require(args.canonical, name: "canonical")
        _ = try require(args.bed, name: "bed")
        _ = try require(args.output, name: "output")

        let stats = try validateAndCountBED(path: args.bed!, canonicalChrom: args.canonical!)

        let canonicalFasta = try fetchSequence(accession: args.canonical!)
        let canonicalHash = try sequenceHash(fasta: canonicalFasta, accession: args.canonical!)
        FileHandle.standardError.write(Data("  \(args.canonical!) SHA256 = \(canonicalHash)\n".utf8))
        for accession in args.equivalents {
            let other = try fetchSequence(accession: accession)
            let otherHash = try sequenceHash(fasta: other, accession: accession)
            FileHandle.standardError.write(Data("  \(accession) SHA256 = \(otherHash)\n".utf8))
            if otherHash != canonicalHash {
                throw ScriptError.sequenceMismatch(
                    canonical: args.canonical!,
                    canonicalHash: canonicalHash,
                    equivalent: accession,
                    equivalentHash: otherHash
                )
            }
        }

        try emitBundle(args: args, stats: stats)

        let equivalents = args.equivalents.isEmpty
            ? ""
            : ", SHA256 match confirmed for \(args.canonical!) ≡ \(args.equivalents.joined(separator: " ≡ "))"
        print("built \(args.name!) (\(stats.primerCount) primers, \(stats.ampliconCount) amplicons)\(equivalents)")
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 1
    }
}

exit(run(CommandLine.arguments))
