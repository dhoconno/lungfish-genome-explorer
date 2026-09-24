import Foundation
import LungfishIO

struct PrimerSchemePreparedRow: Codable, Equatable, Sendable {
    let index: Int
    let sourceID: String
    let title: String
}

struct PrimerSchemePreparedInput: Sendable {
    let id: UUID
    let label: String
    let originalURL: URL
    let adapterInputURL: URL
    let adapterInputRelativePath: String
    let inspectionSHA256: String
    let rows: [PrimerSchemePreparedRow]
    let sourceArtifactPaths: [String]
    let artifacts: [PrimerAnalysisSourceArtifact]
}

struct PrimerSchemePreparedAuxiliaryInputs: Sendable {
    let options: PrimerSchemeDesignOptions
    let artifacts: [PrimerAnalysisSourceArtifact]
    let executedToStoredPaths: [String: String]
}

enum PrimerSchemeInputPreparation {
    private struct RowMap: Codable {
        let schemaVersion: Int
        let inputID: UUID
        let sourcePath: String
        let adapterInputPath: String
        let inspectionSHA256: String
        let rows: [PrimerSchemePreparedRow]
    }

    static func prepare(
        inputURLs: [URL], inputIDs: [URL: UUID],
        expectedInputChecksums: [URL: String], scratchRoot: URL
    ) throws -> [PrimerSchemePreparedInput] {
        guard !inputURLs.isEmpty, Set(inputURLs).count == inputURLs.count else {
            throw PrimerSchemeDesignError.invalidRequest("Select distinct sequence or alignment inputs.")
        }
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        var prepared: [PrimerSchemePreparedInput] = []
        for source in inputURLs {
            try Task.checkCancellation()
            guard let inputID = inputIDs[source] else {
                throw PrimerSchemeDesignError.invalidRequest("Every selected input requires a stable UUID.")
            }
            guard let expected = expectedInputChecksums[source], expected.count == 64,
                  expected == (try Primer3InputLoader.fingerprint(source)) else {
                throw PrimerSchemeDesignError.invalidRequest(
                    "An input changed after inspection or has no inspection checksum: \(source.lastPathComponent)")
            }
            let prefix = "source-inputs/\(inputID.uuidString)"
            let isMSA = Primer3InputLoader.isAlignmentBundle(source)
            let isReference = Primer3InputLoader.isReferenceBundle(source)
            guard isMSA || isReference || PrimalScheme3DesignPipeline.supportsInput(at: source) else {
                throw PrimerSchemeDesignError.invalidRequest(
                    "Inputs must be native MSA/reference bundles or uncompressed aligned nucleotide FASTA.")
            }
            let snapshotRelativePath = prefix + "/" + (isMSA ? "source.lungfishmsa" : isReference ? "source.lungfishref" : "source.fasta")
            let snapshot = scratchRoot.appendingPathComponent(snapshotRelativePath)
            try copySource(source, to: snapshot)
            guard try Primer3InputLoader.fingerprint(snapshot) == expected else {
                throw PrimerSchemeDesignError.invalidRequest("Input changed while being snapshotted: \(source.lastPathComponent)")
            }

            let adapterInput: URL
            let alignedRows: [Primer3AlignedRow]
            let rowIDs: [String]
            if isMSA {
                let bundle = try MultipleSequenceAlignmentBundle.load(from: snapshot)
                adapterInput = snapshot.appendingPathComponent("alignment/primary.aligned.fasta")
                alignedRows = try Primer3InputLoader.readAlignedRows(at: adapterInput, allowingRNAU: true)
                try Primer3InputLoader.validateAlignedRows(alignedRows, bundle: bundle)
                rowIDs = bundle.rows.map(\.id)
            } else if isReference {
                guard let resolved = Primer3InputLoader.fastaURL(for: snapshot),
                      Primer3InputLoader.isContained(resolved.resolvingSymlinksInPath(), in: snapshot.resolvingSymlinksInPath()) else {
                    throw PrimerSchemeDesignError.invalidRequest(
                        "Reference bundle primary FASTA must be stored inside the snapshotted bundle.")
                }
                adapterInput = resolved
                alignedRows = try Primer3InputLoader.readAlignedRows(at: resolved, allowingRNAU: true)
                guard alignedRows.count == 1 else {
                    throw PrimerSchemeDesignError.invalidRequest(
                        ".lungfishref input must contain exactly one sequence; import multiple sequences as an explicit alignment.")
                }
                rowIDs = ["reference-0"]
            } else {
                adapterInput = snapshot
                alignedRows = try Primer3InputLoader.readAlignedRows(at: snapshot, allowingRNAU: true)
                rowIDs = alignedRows.indices.map { "raw-\($0)" }
            }
            guard !alignedRows.isEmpty, Set(alignedRows.map { $0.sequence.count }).count == 1 else {
                throw PrimerSchemeDesignError.invalidRequest(
                    "Primer-scheme inputs must be actual equal-length alignments; no first-record fallback is allowed.")
            }
            let rows = alignedRows.enumerated().map {
                PrimerSchemePreparedRow(index: $0.offset, sourceID: rowIDs[$0.offset], title: $0.element.title)
            }
            let adapterRelativePath = relative(adapterInput, to: scratchRoot)
            let rowMapRelativePath = "input-metadata/\(inputID.uuidString)/rows.json"
            let rowMapURL = scratchRoot.appendingPathComponent(rowMapRelativePath)
            try FileManager.default.createDirectory(
                at: rowMapURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let rowMap = RowMap(schemaVersion: 1, inputID: inputID, sourcePath: source.path,
                                adapterInputPath: adapterRelativePath,
                                inspectionSHA256: expected, rows: rows)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rowMap).write(to: rowMapURL, options: .withoutOverwriting)

            var artifacts = try regularFiles(in: snapshot).map { file in
                PrimerAnalysisSourceArtifact(
                    sourceURL: file, relativePath: relative(file, to: scratchRoot),
                    role: "input", format: format(for: file))
            }
            artifacts.append(.init(sourceURL: rowMapURL, relativePath: rowMapRelativePath,
                                   role: "inputMetadata", format: "json"))
            prepared.append(.init(
                id: inputID, label: source.deletingPathExtension().lastPathComponent,
                originalURL: source, adapterInputURL: adapterInput,
                adapterInputRelativePath: adapterRelativePath, inspectionSHA256: expected,
                rows: rows, sourceArtifactPaths: artifacts.map(\.relativePath), artifacts: artifacts))
        }
        return prepared
    }

    static func prepareAuxiliaryInputs(
        options: PrimerSchemeDesignOptions, scratchRoot: URL
    ) throws -> PrimerSchemePreparedAuxiliaryInputs {
        var resolved = options
        var artifacts: [PrimerAnalysisSourceArtifact] = []
        var mappings: [String: String] = [:]

        func copyRegular(_ source: URL, relativePath: String, role: String) throws -> URL {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard source.isFileURL, source.path.hasPrefix("/"), values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw PrimerSchemeDesignError.invalidRequest(
                    "Auxiliary primer-design inputs must be absolute regular non-symlink files: \(source.path)")
            }
            let before = try ProvenanceFileHasher.sha256(of: source)
            let destination = scratchRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            guard try ProvenanceFileHasher.sha256(of: destination) == before,
                  try ProvenanceFileHasher.fileSize(of: destination)
                    == ProvenanceFileHasher.fileSize(of: source) else {
                throw PrimerSchemeDesignError.invalidRequest(
                    "Auxiliary input changed while being snapshotted: \(source.lastPathComponent)")
            }
            artifacts.append(.init(sourceURL: destination, relativePath: relativePath,
                                   role: role, format: format(for: source)))
            mappings[source.path] = relativePath
            return destination
        }

        func copyBlastPrefix(_ raw: String) throws -> String {
            let prefix = URL(fileURLWithPath: raw).standardizedFileURL
            guard prefix.path.hasPrefix("/"), !prefix.lastPathComponent.isEmpty else {
                throw PrimerSchemeDesignError.invalidRequest("BLAST database prefix must be absolute.")
            }
            let parent = prefix.deletingLastPathComponent()
            let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
                throw PrimerSchemeDesignError.invalidRequest(
                    "BLAST database parent must be an existing non-symlink directory.")
            }
            let base = prefix.lastPathComponent
            let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            if names.contains(base + ".nal") {
                throw PrimerSchemeDesignError.invalidRequest(
                    "BLAST alias databases are not supported unless every alias dependency can be captured; select the concrete database prefix.")
            }
            let pattern = try NSRegularExpression(
                pattern: "^" + NSRegularExpression.escapedPattern(for: base)
                    + "(?:\\.([0-9]{2}))?\\.(nhr|nin|nsq|ndb|njs|nog|nos|not|ntf|nto)$")
            var components: [(name: String, volume: String, kind: String)] = []
            for name in names.sorted() {
                let range = NSRange(name.startIndex..<name.endIndex, in: name)
                guard let match = pattern.firstMatch(in: name, range: range),
                      let kindRange = Range(match.range(at: 2), in: name) else { continue }
                let volume = match.range(at: 1).location == NSNotFound ? "single"
                    : String(name[Range(match.range(at: 1), in: name)!])
                components.append((name, volume, String(name[kindRange])))
            }
            guard !components.isEmpty else {
                throw PrimerSchemeDesignError.invalidRequest(
                    "No nucleotide BLAST database components were found for prefix \(raw).")
            }
            var completeCoreVolumes = 0
            for group in Dictionary(grouping: components, by: \.volume).values {
                let kinds = Set(group.map(\.kind))
                let core = Set(["nhr", "nin", "nsq"])
                if kinds.isDisjoint(with: core) { continue }
                guard core.isSubset(of: kinds) else {
                    throw PrimerSchemeDesignError.invalidRequest(
                        "BLAST database component set is incomplete; every volume needs .nhr, .nin, and .nsq files.")
                }
                completeCoreVolumes += 1
            }
            guard completeCoreVolumes > 0 else {
                throw PrimerSchemeDesignError.invalidRequest(
                    "BLAST database component set has metadata but no complete nucleotide index volume.")
            }
            let directory = "auxiliary-inputs/blast/\(UUID().uuidString.lowercased())"
            for component in components {
                _ = try copyRegular(parent.appendingPathComponent(component.name),
                                    relativePath: directory + "/" + component.name,
                                    role: "blastDatabase")
            }
            let storedPrefix = directory + "/" + base
            mappings[prefix.path] = storedPrefix
            return scratchRoot.appendingPathComponent(storedPrefix).path
        }

        if var olivar = resolved.olivar {
            if let path = olivar.blastDatabasePath {
                olivar.blastDatabasePath = try copyBlastPrefix(path)
            }
            resolved.olivar = olivar
        }
        if var varvamp = resolved.varvamp {
            if let path = varvamp.compatiblePrimersPath {
                let source = URL(fileURLWithPath: path).standardizedFileURL
                let relative = "auxiliary-inputs/compatible-primers/" + source.lastPathComponent
                varvamp.compatiblePrimersPath = try copyRegular(
                    source, relativePath: relative, role: "compatiblePrimers").path
            }
            if let path = varvamp.blastDatabasePath {
                varvamp.blastDatabasePath = try copyBlastPrefix(path)
            }
            resolved.varvamp = varvamp
        }
        return .init(options: resolved, artifacts: artifacts,
                     executedToStoredPaths: mappings)
    }

    static func regularFiles(in url: URL) throws -> [URL] {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else {
            throw PrimerSchemeDesignError.invalidRequest("Symbolic-link scientific payloads are unsupported.")
        }
        if values.isRegularFile == true { return [url] }
        guard values.isDirectory == true else {
            throw PrimerSchemeDesignError.invalidRequest("Scientific input contains an unsupported file type.")
        }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { try regularFiles(in: $0) }
    }

    static func copySource(_ source: URL, to destination: URL) throws {
        let files = try regularFiles(in: source)
        let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if isDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        for file in files {
            try Task.checkCancellation()
            let target = isDirectory
                ? destination.appendingPathComponent(relative(file, to: source)) : destination
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: target)
        }
    }

    static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path
        let prefix = root.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    static func format(for url: URL) -> String {
        let value = url.pathExtension.lowercased()
        return value.isEmpty ? "binary" : value
    }
}
