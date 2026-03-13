import Foundation

// MARK: - Read Annotation File I/O

/// Reads and writes `read-annotations.tsv` files that store per-read annotations
/// for FASTQ derivative bundles. Each annotation marks a region of a read's ROOT
/// sequence (e.g., barcode match position, adapter boundary, quality-trimmed region).
///
/// **Format:**
/// ```
/// #format lungfish-read-annotations-v1
/// read_id\tmate\ttype\tstart\tend\tstrand\tlabel\tmetadata
/// read1\t0\tbarcode_5p\t0\t24\t+\tBC1001\tkit=SQK-NBD114-96;error_rate=0.15
/// ```
///
/// - `start`/`end` are 0-based, half-open coordinates in the ROOT sequence.
/// - `metadata` is a semicolon-delimited `key=value` string (may be empty).
public enum ReadAnnotationFile {

    public static let filename = "read-annotations.tsv"
    public static let formatHeader = "#format lungfish-read-annotations-v1"

    // MARK: - Annotation Record

    public struct Annotation: Sendable, Equatable {
        /// Read identifier (normalized, without /1 /2 suffix).
        public let readID: String
        /// Mate number: 0 = single-end, 1 = R1, 2 = R2.
        public let mate: Int
        /// Annotation type string (e.g., "barcode_5p", "adapter_3p").
        public let annotationType: String
        /// 0-based inclusive start position in ROOT sequence.
        public let start: Int
        /// 0-based exclusive end position in ROOT sequence.
        public let end: Int
        /// Strand: "+" or "-".
        public let strand: String
        /// Human-readable label (e.g., "BC1001", "VNP adapter").
        public let label: String
        /// Additional key-value metadata pairs.
        public let metadata: [String: String]

        public init(
            readID: String,
            mate: Int = 0,
            annotationType: String,
            start: Int,
            end: Int,
            strand: String = "+",
            label: String,
            metadata: [String: String] = [:]
        ) {
            self.readID = readID
            self.mate = mate
            self.annotationType = annotationType
            self.start = start
            self.end = end
            self.strand = strand
            self.label = label
            self.metadata = metadata
        }

        /// The span of this annotation in bases.
        public var length: Int { max(0, end - start) }
    }

    // MARK: - Write

    /// Writes annotations to a TSV file atomically.
    public static func write(_ annotations: [Annotation], to url: URL) throws {
        let fm = FileManager.default
        let tmpURL = url.appendingPathExtension("tmp")
        fm.createFile(atPath: tmpURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmpURL)
        do {
            if let headerData = "\(formatHeader)\nread_id\tmate\ttype\tstart\tend\tstrand\tlabel\tmetadata\n"
                .data(using: .utf8) {
                handle.write(headerData)
            }

            for annotation in annotations {
                let metadataStr = annotation.metadata
                    .sorted(by: { $0.key < $1.key })
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: ";")
                let line = "\(annotation.readID)\t\(annotation.mate)\t\(annotation.annotationType)\t\(annotation.start)\t\(annotation.end)\t\(annotation.strand)\t\(annotation.label)\t\(metadataStr)\n"
                if let data = line.data(using: .utf8) {
                    handle.write(data)
                }
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: tmpURL)
            throw error
        }
        // POSIX rename is atomic on same filesystem
        if rename(tmpURL.path, url.path) != 0 {
            try? fm.removeItem(at: url)
            try fm.moveItem(at: tmpURL, to: url)
        }
    }

    // MARK: - Load

    /// Loads all annotations from a TSV file.
    public static func load(from url: URL) throws -> [Annotation] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var annotations: [Annotation] = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") || line.hasPrefix("read_id") { continue }
            if let annotation = parseLine(line) {
                annotations.append(annotation)
            }
        }
        return annotations
    }

    /// Loads annotations only for the specified read IDs (memory-efficient filter).
    public static func load(from url: URL, readIDs: Set<String>) throws -> [Annotation] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var annotations: [Annotation] = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") || line.hasPrefix("read_id") { continue }
            // Quick check: first column is read_id — skip if not in set
            guard let tabIdx = line.firstIndex(of: "\t") else { continue }
            let readID = String(line[line.startIndex..<tabIdx])
            guard readIDs.contains(readID) else { continue }
            if let annotation = parseLine(line) {
                annotations.append(annotation)
            }
        }
        return annotations
    }

    // MARK: - Merge

    /// Merges parent annotations with new annotations, filtering to only include
    /// annotations for the given read IDs. Used during lineage propagation.
    public static func mergeAndFilter(
        parentURL: URL?,
        newAnnotations: [Annotation],
        readIDs: Set<String>
    ) throws -> [Annotation] {
        var result: [Annotation] = []

        // Load and filter parent annotations
        if let parentURL, FileManager.default.fileExists(atPath: parentURL.path) {
            let parentAnnotations = try load(from: parentURL, readIDs: readIDs)
            result.append(contentsOf: parentAnnotations)
        }

        // Add new annotations (already filtered to relevant reads by caller)
        result.append(contentsOf: newAnnotations.filter { readIDs.contains($0.readID) })

        return result
    }

    // MARK: - Private

    private static func parseLine(_ line: some StringProtocol) -> Annotation? {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard cols.count >= 7 else { return nil }

        let readID = String(cols[0])
        guard let mate = Int(cols[1]),
              let start = Int(cols[3]),
              let end = Int(cols[4]),
              start >= 0, end >= start else { return nil }

        let annotationType = String(cols[2])
        let strand = String(cols[5])
        let label = String(cols[6])

        // Parse metadata (column 7, semicolon-delimited key=value pairs)
        var metadata: [String: String] = [:]
        if cols.count >= 8 {
            let metaStr = String(cols[7])
            if !metaStr.isEmpty {
                for pair in metaStr.split(separator: ";") {
                    if let eqIdx = pair.firstIndex(of: "=") {
                        let key = String(pair[pair.startIndex..<eqIdx])
                        let value = String(pair[pair.index(after: eqIdx)...])
                        metadata[key] = value
                    }
                }
            }
        }

        return Annotation(
            readID: readID,
            mate: mate,
            annotationType: annotationType,
            start: start,
            end: end,
            strand: strand,
            label: label,
            metadata: metadata
        )
    }
}
