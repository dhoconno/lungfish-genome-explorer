import Foundation

/// The input of `DemuxDualAnchorXCUITests`, written into the project before it opens (lane DEMUX-XCUI, 5.4). It is the
/// input of the walk rows A and B of the fix of DEMUX-DUAL-UNANCHORED (`preview-notes.md` section 4, `make-dual-ends.py`
/// and `make-dual-96.py`), written by the same generators on the same seeds, so the reads and the 96 pairs are the ones
/// a walker would make. The bundle holds 270 reads of 116 bases, with cached statistics so the dashboard opens with no
/// seqkit. `Barcode Definitions/` holds `Dual Two.csv` (two pairs, no header row) and `Dual 96.csv` (96 distinct pairs),
/// where the dialog's Project File picker looks.
nonisolated enum DemuxDualAnchorFixture {
    static let bundleName = "DUALENDS-270"
    static let twoName = "Dual Two.csv"
    static let ninetySixName = "Dual 96.csv"
    static let readLength = 116
    static let readTotal = 270
    /// Both strands of each pair whole at the two ends, 60 reads of each, and 30 reads that carry no barcode.
    static let expectedCounts = ["S1": 120, "S2": 120, "unassigned": 30]

    /// The two pairs of `Dual Two.csv` as `id,i7,i5`, which is the file's whole content.
    static let pairs: [(id: String, i7: String, i5: String)] = [("S1", "ATTACTCG", "TATAGCCT"), ("S2", "TCCGGAGA", "ATAGAGGC")]

    static func readsURL(in project: URL) -> URL {
        project.appendingPathComponent("\(bundleName).lungfishfastq/reads.fastq")
    }

    static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base -> Character in
            switch base {
            case "A": return "T"
            case "C": return "G"
            case "G": return "C"
            case "T": return "A"
            default: return base
            }
        })
    }

    /// The generator of both scripts, `state = (state * 1103515245 + 12345) % 2147483648` and the bases `ACGT` by
    /// `(state >> 16) & 3`. The product stays under 2^63, so the wrapping operators change nothing.
    struct Generator {
        var state: UInt64

        mutating func bases(_ count: Int) -> String {
            let alphabet = Array("ACGT")
            var out: [Character] = []
            for _ in 0..<count {
                state = (state &* 1_103_515_245 &+ 12_345) % 2_147_483_648
                out.append(alphabet[Int((state >> 16) & 3)])
            }
            return String(out)
        }
    }

    /// `make-dual-ends.py`, in its order: for each pair 60 reads as the molecule reads (i7, a 100-base insert, i5), 60 as the
    /// other strand (the reverse complement of i5, an insert, the reverse complement of i7), then 30 reads of 116 bases.
    static func makeReads() -> [(name: String, sequence: String)] {
        var generator = Generator(state: 20_261_117)
        var reads: [(name: String, sequence: String)] = []
        for pair in pairs {
            for number in 0..<60 {
                reads.append(("\(pair.id)_fwd_\(String(format: "%02d", number))", pair.i7 + generator.bases(100) + pair.i5))
            }
            for number in 0..<60 {
                reads.append(("\(pair.id)_rev_\(String(format: "%02d", number))",
                              reverseComplement(pair.i5) + generator.bases(100) + reverseComplement(pair.i7)))
            }
        }
        for number in 0..<30 { reads.append(("none_\(String(format: "%02d", number))", generator.bases(readLength))) }
        return reads
    }

    /// `make-dual-96.py`, which draws i7 and then i5 of eight bases from the seed 96 and keeps a pair only when neither is
    /// its own reverse complement and neither was used before.
    static func ninetySixRows() -> [String] {
        var generator = Generator(state: 96)
        var seenI7 = Set<String>()
        var seenI5 = Set<String>()
        var rows: [String] = []
        while rows.count < 96 {
            let i7 = generator.bases(8)
            let i5 = generator.bases(8)
            if i7 == reverseComplement(i7) || i5 == reverseComplement(i5) || seenI7.contains(i7) || seenI5.contains(i5) { continue }
            seenI7.insert(i7)
            seenI5.insert(i5)
            rows.append("P\(String(format: "%02d", rows.count + 1)),\(i7),\(i5)")
        }
        return rows
    }

    /// The bundle with cached statistics and the two definitions in `Barcode Definitions/`.
    static func add(to project: URL) throws {
        let reads = makeReads()
        let bundle = project.appendingPathComponent("\(bundleName).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let quality = String(repeating: "I", count: readLength)
        let text = reads.map { "@\($0.name)\n\($0.sequence)\n+\n\(quality)\n" }.joined()
        try text.write(to: readsURL(in: project), atomically: true, encoding: .utf8)
        let bases = reads.count * readLength
        let gc = reads.reduce(0) { total, read in total + read.sequence.filter { $0 == "G" || $0 == "C" }.count }
        let statistics: [String: Any] = ["readCount": reads.count, "baseCount": bases, "meanReadLength": Double(readLength),
                                         "minReadLength": readLength, "maxReadLength": readLength, "medianReadLength": readLength,
                                         "n50ReadLength": readLength, "meanQuality": 40.0, "q20Percentage": 100.0,
                                         "q30Percentage": 100.0, "gcContent": Double(gc) / Double(bases),
                                         "readLengthHistogram": ["\(readLength)": reads.count], "qualityScoreHistogram": [40, bases],
                                         "perPositionQuality": [Any]()]
        try JSONSerialization.data(withJSONObject: ["computedStatistics": statistics], options: [.prettyPrinted, .sortedKeys])
            .write(to: bundle.appendingPathComponent("reads.fastq.lungfish-meta.json"))
        let definitions = project.appendingPathComponent("Barcode Definitions", isDirectory: true)
        try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
        let two = pairs.map { "\($0.id),\($0.i7),\($0.i5)" }.joined(separator: "\n") + "\n"
        try two.write(to: definitions.appendingPathComponent(twoName), atomically: true, encoding: .utf8)
        try (ninetySixRows().joined(separator: "\n") + "\n").write(to: definitions.appendingPathComponent(ninetySixName), atomically: true, encoding: .utf8)
    }

    /// Every sample bundle and every demultiplex manifest the project holds besides the input bundle, as paths under the
    /// project. A refused run leaves this list as it found it.
    static func madeFiles(in project: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil) else { return [] }
        let found = walker.compactMap { item -> String? in
            guard let url = item as? URL else { return nil }
            let name = url.lastPathComponent
            let isInput = name == "\(bundleName).lungfishfastq" || url.path.contains("/\(bundleName).lungfishfastq/")
            if isInput { return nil }
            let isBundle = url.pathExtension == "lungfishfastq"
            let isManifest = name == "demux-manifest.json"
            let isRunFolder = url.path.contains("/Analyses/") && name.hasPrefix("demultiplex")
            return isBundle || isManifest || isRunFolder ? url.path.replacingOccurrences(of: project.path, with: "") : nil
        }
        return found.sorted()
    }

    /// The read names of the sample file that `sample` got in the run folder. A Cutadapt run holds a sample's reads as
    /// `<sample>.lungfishfastq/<sample>.fastq.gz`, which is Cutadapt's own output moved into the bundle, with
    /// `<sample>.fastq.gz.lungfish-provenance.json` beside it (`DemultiplexingPipeline.swift:731-734`, the full mode that a run
    /// takes when its input is a plain bundle and not a derived one). An Exact Bare run writes `<sample>.fastq`, which
    /// `ExactBareFixture.readCount(ofBarcode:in:)` reads. Run new-2 looked only for `.fastq` here and found no file in the three
    /// bundles. A read name is the text after `@` up to the first blank, and the bundle's `preview.fastq` is never the file.
    static func readNames(ofSample sample: String, in runFolder: URL) throws -> [String] {
        let manager = FileManager.default
        let bundle = runFolder.appendingPathComponent("\(sample).lungfishfastq", isDirectory: true)
        guard manager.fileExists(atPath: bundle.path) else {
            let held = ((try? manager.contentsOfDirectory(atPath: runFolder.path)) ?? []).sorted().joined(separator: ", ")
            throw fixtureError(1, "The run folder holds no \(bundle.lastPathComponent), only \(held)")
        }
        let held = try manager.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil).map(\.lastPathComponent).sorted()
        let files = held.filter { ($0.hasSuffix(".fastq") || $0.hasSuffix(".fastq.gz")) && $0 != "preview.fastq" }
        guard files.count == 1, let file = files.first else {
            throw fixtureError(2, "\(bundle.lastPathComponent) holds \(files.count) FASTQ files, not one, among \(held.joined(separator: ", "))")
        }
        let raw = try Data(contentsOf: bundle.appendingPathComponent(file))
        let text = file.hasSuffix(".gz") ? try gunzip(raw) : raw
        let lines = text.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        // A well-formed FASTQ ends with a newline, so the last piece is empty and the rest is four lines to a read.
        guard lines.last?.isEmpty == true, (lines.count - 1) % 4 == 0 else {
            throw fixtureError(3, "\(file) holds \(lines.count - 1) lines, which are not four to a read")
        }
        return stride(from: 0, to: lines.count - 1, by: 4).map { index in
            let header = String(decoding: lines[index], as: UTF8.self)
            return String(header.dropFirst().prefix { $0 != " " && $0 != "\t" })
        }
    }

    /// The reads of the sample file that `sample` got in the run folder.
    static func readCount(ofSample sample: String, in runFolder: URL) throws -> Int {
        try readNames(ofSample: sample, in: runFolder).count
    }

    /// What the names of a sample's reads start with, as the input names its reads (`make-dual-ends.py`): `S1_fwd_00`, `S2_rev_59`,
    /// `none_07`.
    static func readNamePrefix(ofSample sample: String) -> String {
        sample == "unassigned" ? "none_" : "\(sample)_"
    }

    /// A gzip file as RFC 1952 lays it out, a header, one deflate stream and a trailer of the CRC-32 and the length. The Compression
    /// framework reads a bare deflate stream (it names it zlib), so the header and the trailer are cut off here and the length
    /// in the trailer is checked against what came out, which fails on a file of two members or on a cut file.
    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else {
            throw fixtureError(4, "The file is not a gzip file, and starts with \(bytes.prefix(4).map { String($0, radix: 16) })")
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            let extra = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extra
        }
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {
            while offset < bytes.count - 8, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { throw fixtureError(5, "The gzip header runs to the end of the file") }
        let deflated = Data(bytes[offset..<(bytes.count - 8)])
        let inflated = try (deflated as NSData).decompressed(using: .zlib) as Data
        let trailer = bytes[(bytes.count - 4)...]
        let length = trailer.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) }
        guard UInt64(inflated.count) & 0xFFFF_FFFF == length else {
            throw fixtureError(6, "The gzip trailer says \(length) bytes and \(inflated.count) came out of the deflate stream")
        }
        return inflated
    }

    private static func fixtureError(_ code: Int, _ words: String) -> NSError {
        NSError(domain: "DemuxDualAnchorFixture", code: code, userInfo: [NSLocalizedDescriptionKey: words])
    }

    /// The account's managed tool store. The smoke launches the app with an empty home, so the app under test is told
    /// where Cutadapt is installed, the way an installed app finds it in a person's own home.
    static func accountToolRoot() -> URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".lungfish", isDirectory: true)
    }

    static func cutadaptURL() -> URL {
        accountToolRoot().appendingPathComponent("conda/envs/cutadapt/bin/cutadapt")
    }
}
