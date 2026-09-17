import Foundation
import LungfishIO

/// Restores the exact consumed identifiers and sequence policy of a saved input.
/// Headers alone are insufficient: different MSAs can reuse the same allele names.
enum PrimalScheme3ParentResolver {
    struct SavedInput {
        let id: UUID
        let sourceRows: [Primer3AlignedRow]
        let consumedRows: [Primer3AlignedRow]
        let preservesAmbiguity: Bool
        let evidenceFiles: [String: URL]

        func matches(_ rows: [Primer3AlignedRow]) -> Bool {
            rows.count == sourceRows.count && zip(rows, sourceRows).allSatisfy {
                $0.title == $1.title && $0.sequence.uppercased() == $1.sequence.uppercased()
            }
        }
    }

    static func resolve(_ url: URL) throws -> URL {
        if isNative(url) { return url }
        let nativeRoot = url.appendingPathComponent("native", isDirectory: true)
        let candidates = (try? FileManager.default.contentsOfDirectory(at: nativeRoot,
            includingPropertiesForKeys: nil))?.filter(isNative) ?? []
        guard candidates.count == 1 else {
            throw invalid(candidates.isEmpty ? "The parent contains no saved native result." :
                "The parent contains multiple results. Select the native output directory for the desired result.")
        }
        return candidates[0]
    }

    static func savedInputs(parent: URL, native: URL) throws -> [SavedInput]? {
        var root = parent.standardizedFileURL
        while root.pathExtension.lowercased() != "lungfishprimeranalysis" && root.path != "/" {
            root.deleteLastPathComponent()
        }
        guard root.pathExtension.lowercased() == "lungfishprimeranalysis" else { return nil }
        let manifest = try JSONDecoder().decode(PrimerAnalysisManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.schemaVersion == PrimerAnalysisManifest.currentSchemaVersion else {
            throw invalid("Unsupported parent analysis schema.")
        }
        let matches = manifest.results.filter { result in
            result.artifactPaths.contains { path in
                root.appendingPathComponent(path).standardizedFileURL == native.appendingPathComponent("primer.bed").standardizedFileURL
            }
        }
        guard matches.count == 1, let result = matches.first,
              Set(result.inputIDs).count == result.inputIDs.count else {
            throw invalid("The selected native result is not uniquely described by the parent manifest.")
        }
        return try result.inputIDs.map { id in
            let inputMatches = manifest.inputs.filter { $0.id == id }
            guard inputMatches.count == 1, let input = inputMatches.first else {
                throw invalid("Parent result input identity is ambiguous.")
            }
            func uniquePath(_ predicate: (String) -> Bool) throws -> String {
                let paths = input.artifactPaths.filter(predicate)
                guard paths.count == 1, let path = paths.first else {
                    throw invalid("Parent input is missing an unambiguous source, consumed FASTA, or row map.")
                }
                return path
            }
            func verified(_ path: String) throws -> URL {
                let file = root.appendingPathComponent(path).standardizedFileURL
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                      Primer3InputLoader.isContained(file.resolvingSymlinksInPath(), in: root.resolvingSymlinksInPath()) else {
                    throw invalid("Parent input artifact escapes its analysis bundle.")
                }
                let descriptors = manifest.artifacts.filter { $0.relativePath == path }
                guard descriptors.count == 1, let descriptor = descriptors.first,
                      try ProvenanceFileHasher.sha256(of: file) == descriptor.sha256,
                      try ProvenanceFileHasher.fileSize(of: file) == descriptor.byteSize else {
                    throw invalid("Parent input artifact does not match its saved checksum: \(path)")
                }
                return file
            }
            let consumedPath = try uniquePath { $0.hasPrefix("inputs/") && $0.hasSuffix(".fasta") }
            let mapPath = try uniquePath { $0.hasSuffix("-row-map.json") }
            let sourcePaths = input.artifactPaths.filter { $0.hasPrefix("source-inputs/") }
            let sourcePath: String
            if let aligned = sourcePaths.first(where: { $0.hasSuffix("/alignment/primary.aligned.fasta") }) {
                sourcePath = aligned
            } else if let fasta = sourcePaths.first(where: { $0.hasSuffix("/source.fasta") }) {
                sourcePath = fasta
            } else {
                let fasta = sourcePaths.filter { ["fasta", "fa", "fna"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
                guard fasta.count == 1, let path = fasta.first else { throw invalid("Cannot resolve the saved parent source FASTA.") }
                sourcePath = path
            }
            let sourceRows = try Primer3InputLoader.readAlignedRows(at: verified(sourcePath), allowingRNAU: true)
            let consumed = try Primer3InputLoader.readAlignedRows(at: verified(consumedPath))
            let map = try JSONSerialization.jsonObject(with: Data(contentsOf: verified(mapPath))) as? [String: Any]
            guard let entries = map?["rows"] as? [[String: Any]], entries.count == sourceRows.count,
                  consumed.count == sourceRows.count else { throw invalid("Parent row-map dimensions disagree with its FASTA files.") }
            for index in sourceRows.indices {
                guard entries[index]["rowIndex"] as? Int == index,
                      entries[index]["originalHeader"] as? String == sourceRows[index].title,
                      entries[index]["normalizedHeader"] as? String == consumed[index].title else {
                    throw invalid("Parent row-map identifiers disagree with its source and consumed FASTA.")
                }
            }
            let preserved = Primer3InputLoader.normalizeForPrimalScheme(sourceRows, ambiguityPolicy: .preserve).rows
            let missing = Primer3InputLoader.normalizeForPrimalScheme(sourceRows, ambiguityPolicy: .missingCoverage).rows
            let isPreserved = zip(preserved, consumed).allSatisfy { $0.sequence == $1.sequence }
            guard isPreserved || zip(missing, consumed).allSatisfy({ $0.sequence == $1.sequence }) else {
                throw invalid("Parent consumed sequences use an unsupported or inconsistent normalization.")
            }
            return SavedInput(id: id, sourceRows: sourceRows, consumedRows: consumed, preservesAmbiguity: isPreserved,
                evidenceFiles: ["manifest.json": root.appendingPathComponent("manifest.json"),
                    sourcePath: try verified(sourcePath), consumedPath: try verified(consumedPath), mapPath: try verified(mapPath)])
        }
    }

    private static func isNative(_ url: URL) -> Bool {
        ["primer.bed", "reference.fasta", "config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }
    private static func invalid(_ message: String) -> PrimalScheme3DesignError { .invalidRequest(message) }
}
