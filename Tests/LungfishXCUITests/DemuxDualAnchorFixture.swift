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
