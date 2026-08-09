// MappingViewerScaffold.swift - Shared test fixture that builds a synthetic
// `.lungfish` project containing a source reference bundle plus a prepared
// mapping viewer bundle whose payload directories are symlinked back into the
// source (mirroring production `MappingViewerBundlePreparer` layout).
//
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// A reusable on-disk fixture that reproduces the production mapping-viewer
/// bundle layout: a `.lungfish` project holding a real source `.lungfishref`
/// (with a genuine indexed genome payload) and a `viewer.lungfishref` whose
/// manifest-referenced top-level directories are symlinks into the source
/// bundle, exactly as `MappingViewerBundlePreparer` produces them.
///
/// The scaffold is deliberately payload-realistic so behavioural tests exercise
/// the real `IndexedFASTAReader` / `SyncBgzipFASTAReader` paths through the
/// symlinked `genome/` directory rather than a stubbed byte blob.
///
/// Both `LungfishAppTests` (which can inject the real
/// `MappingViewerBundlePreparer.prepareBaseBundle`) and lower-level
/// `LungfishIOTests` / `LungfishCoreTests` (which cannot reach `LungfishApp`)
/// can use this type: the viewer-bundle preparation step is injectable and
/// defaults to a built-in equivalent of the production preparer.
public struct MappingViewerScaffold: Sendable {

    /// Genome payload flavour to materialize in the source bundle.
    public enum PayloadKind: Sendable {
        /// Plain uncompressed FASTA + `.fai` (exercises `IndexedFASTAReader`).
        case plainFASTA
        /// Bgzip-compressed FASTA + `.fai` + `.gzi` (exercises
        /// `SyncBgzipFASTAReader`, the path production viewer bundles ship
        /// through). Requires a real `samtools` + `bgzip` on the system;
        /// `make` throws `ScaffoldError.toolsUnavailable` otherwise.
        case bgzip
    }

    public enum ScaffoldError: Error, LocalizedError {
        case toolsUnavailable(String)
        case toolFailed(tool: String, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .toolsUnavailable(let detail):
                return "Required tool unavailable for MappingViewerScaffold: \(detail)"
            case .toolFailed(let tool, let stderr):
                return "\(tool) failed while building MappingViewerScaffold: \(stderr)"
            }
        }
    }

    /// Signature of the viewer-bundle preparation step. Callers inject
    /// `MappingViewerBundlePreparer.prepareBaseBundle` to exercise the real
    /// production symlinking; the built-in default mirrors it.
    public typealias PreparerStep = @Sendable (_ sourceBundleURL: URL, _ viewerBundleURL: URL) throws -> Void

    /// Root of the synthetic project (`<tmp>/Test.lungfish`).
    public let projectRootURL: URL
    /// The source reference bundle
    /// (`<tmp>/Test.lungfish/Reference Sequences/src.lungfishref`).
    public let sourceBundleURL: URL
    /// The prepared viewer bundle
    /// (`<tmp>/Test.lungfish/Analyses/run/viewer.lungfishref`).
    public let viewerBundleURL: URL
    /// The payload flavour used to build the source genome.
    public let payloadKind: PayloadKind
    /// Chromosome names present in the genome, in file order.
    public let chromosomeNames: [String]

    public init(
        projectRootURL: URL,
        sourceBundleURL: URL,
        viewerBundleURL: URL,
        payloadKind: PayloadKind,
        chromosomeNames: [String]
    ) {
        self.projectRootURL = projectRootURL
        self.sourceBundleURL = sourceBundleURL
        self.viewerBundleURL = viewerBundleURL
        self.payloadKind = payloadKind
        self.chromosomeNames = chromosomeNames
    }

    // MARK: - Genome payload description

    /// A single contig's expected content, exposed so tests can assert
    /// byte-for-byte fetches (including at non-zero offsets and near the end).
    public struct Contig: Sendable, Equatable {
        public let name: String
        public let bases: String
        public let fastaDescription: String?

        public init(name: String, bases: String, fastaDescription: String?) {
            self.name = name
            self.bases = bases
            self.fastaDescription = fastaDescription
        }
    }

    /// The two-contig genome used by the scaffold. `chr1` is 40 bp and `chr2`
    /// is 20 bp so tests can assert a non-zero offset in `chr1`, the tail of
    /// `chr1`, and the resolution of a SECOND contig.
    public static let defaultContigs: [Contig] = [
        Contig(
            name: "chr1",
            bases: "ACGTACGTACGTACGTACGTTTTTGGGGCCCCAAAATTTT",
            fastaDescription: "test description"
        ),
        Contig(
            name: "chr2",
            bases: "GGGGCCCCAAAATTTTACGT",
            fastaDescription: "second contig"
        ),
    ]

    // MARK: - Construction

    /// Builds the synthetic project, source bundle, and viewer bundle.
    ///
    /// - Parameters:
    ///   - rootURL: A caller-owned temp directory (use
    ///     `FileManager.default.temporaryDirectory`). NEVER pass an external
    ///     volume, `~/Downloads`, or a scratchpad path. Note: on
    ///     `temporaryDirectory` (an APFS volume) the built-in preparer's
    ///     `createSymbolicLink` always succeeds, so the copy fallback is not
    ///     expected to fire — behavioural tests exercise the real symlink path.
    ///   - payloadKind: Plain FASTA or bgzip genome payload.
    ///   - contigs: Genome contigs (defaults to `defaultContigs`).
    ///   - viewerIdentifierMatchesSource: When `false`, the viewer manifest is
    ///     rewritten with a DIFFERENT `identifier` than the source (for the
    ///     mismatched-identity security negatives). Default `true`.
    ///   - includeOriginBundlePath: When `false`, the viewer manifest's
    ///     `originBundlePath` is stripped after preparation (for the
    ///     no-origin strict-rejection tests). Default `true`.
    ///   - preparer: The viewer-bundle preparation step. Defaults to the
    ///     built-in mirror of `MappingViewerBundlePreparer`. `LungfishAppTests`
    ///     should inject `MappingViewerBundlePreparer.prepareBaseBundle` to
    ///     exercise the real production code.
    ///   - samtoolsPath / bgzipPath: Override tool discovery (tests normally
    ///     leave these `nil`).
    public static func make(
        rootURL: URL = FileManager.default.temporaryDirectory,
        payloadKind: PayloadKind,
        contigs: [Contig] = defaultContigs,
        viewerIdentifierMatchesSource: Bool = true,
        includeOriginBundlePath: Bool = true,
        preparer: PreparerStep? = nil,
        samtoolsPath: URL? = nil,
        bgzipPath: URL? = nil
    ) throws -> MappingViewerScaffold {
        let fileManager = FileManager.default

        // Project root MUST carry the `.lungfish` extension so
        // `ProjectTempDirectory.findProjectRoot` resolves it as the enclosing
        // project (origin-scoping in Item 1 depends on this).
        let projectRoot = rootURL
            .appendingPathComponent("MappingViewerScaffold-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Test.lungfish", isDirectory: true)

        let referenceSequencesDir = projectRoot
            .appendingPathComponent("Reference Sequences", isDirectory: true)
        let sourceBundleURL = referenceSequencesDir
            .appendingPathComponent("src.lungfishref", isDirectory: true)
        let analysesRunDir = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("run", isDirectory: true)
        let viewerBundleURL = analysesRunDir
            .appendingPathComponent("viewer.lungfishref", isDirectory: true)

        try fileManager.createDirectory(at: referenceSequencesDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: analysesRunDir, withIntermediateDirectories: true)

        let sharedIdentifier = "mapping-viewer-scaffold.\(UUID().uuidString)"

        // Build the source bundle (real manifest + real genome payload).
        try buildSourceBundle(
            at: sourceBundleURL,
            identifier: sharedIdentifier,
            payloadKind: payloadKind,
            contigs: contigs,
            samtoolsPath: samtoolsPath,
            bgzipPath: bgzipPath
        )

        // Prepare the viewer bundle via the real (or built-in) preparer.
        let preparerStep = preparer ?? builtInPreparer
        try preparerStep(sourceBundleURL, viewerBundleURL)

        // Apply the identifier / origin knobs by rewriting the viewer manifest.
        if !viewerIdentifierMatchesSource || !includeOriginBundlePath {
            try rewriteViewerManifest(
                at: viewerBundleURL,
                overrideIdentifier: viewerIdentifierMatchesSource
                    ? nil
                    : "mapping-viewer-scaffold-mismatch.\(UUID().uuidString)",
                stripOriginBundlePath: !includeOriginBundlePath
            )
        }

        return MappingViewerScaffold(
            projectRootURL: projectRoot,
            sourceBundleURL: sourceBundleURL,
            viewerBundleURL: viewerBundleURL,
            payloadKind: payloadKind,
            chromosomeNames: contigs.map(\.name)
        )
    }

    /// Removes the scaffold's enclosing temp tree (the parent of the
    /// `Test.lungfish` project). Safe to call in `defer`.
    public func cleanUp() {
        let enclosing = projectRootURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: enclosing)
    }

    // MARK: - Source bundle

    private static func buildSourceBundle(
        at bundleURL: URL,
        identifier: String,
        payloadKind: PayloadKind,
        contigs: [Contig],
        samtoolsPath: URL?,
        bgzipPath: URL?
    ) throws {
        let fileManager = FileManager.default
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        let plainFASTAURL = genomeDir.appendingPathComponent("sequence.fa")
        try fastaText(for: contigs).write(to: plainFASTAURL, atomically: true, encoding: .utf8)

        let genomeInfo: GenomeInfo
        switch payloadKind {
        case .plainFASTA:
            let faiURL = genomeDir.appendingPathComponent("sequence.fa.fai")
            let chromosomes = try indexFASTA(
                plainFASTAURL: plainFASTAURL,
                faiURL: faiURL,
                contigs: contigs,
                samtoolsPath: samtoolsPath
            )
            genomeInfo = GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                gzipIndexPath: nil,
                totalLength: chromosomes.reduce(0) { $0 + $1.length },
                chromosomes: chromosomes
            )

        case .bgzip:
            let (gzURL, faiURL, gziURL) = try compressAndIndex(
                plainFASTAURL: plainFASTAURL,
                genomeDir: genomeDir,
                samtoolsPath: samtoolsPath,
                bgzipPath: bgzipPath
            )
            // The plain FASTA is not part of the shipped bundle; remove it so
            // the layout matches a production bgzip bundle exactly.
            try? fileManager.removeItem(at: plainFASTAURL)
            let chromosomes = try readFAIChromosomes(faiURL: faiURL, contigs: contigs)
            genomeInfo = GenomeInfo(
                path: "genome/\(gzURL.lastPathComponent)",
                indexPath: "genome/\(faiURL.lastPathComponent)",
                gzipIndexPath: "genome/\(gziURL.lastPathComponent)",
                totalLength: chromosomes.reduce(0) { $0 + $1.length },
                chromosomes: chromosomes
            )
        }

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Mapping Viewer Scaffold Source",
            identifier: identifier,
            source: SourceInfo(
                organism: "Fixture organism",
                assembly: "Fixture assembly",
                database: "Fixture"
            ),
            genome: genomeInfo
        )
        try manifest.save(to: bundleURL)
    }

    private static func fastaText(for contigs: [Contig]) -> String {
        var text = ""
        for contig in contigs {
            if let description = contig.fastaDescription, !description.isEmpty {
                text += ">\(contig.name) \(description)\n"
            } else {
                text += ">\(contig.name)\n"
            }
            text += contig.bases + "\n"
        }
        return text
    }

    // MARK: - Indexing (plain)

    /// Indexes a plain FASTA. Prefers a real `samtools faidx`; if no samtools is
    /// available, derives the `.fai` analytically (single-line-per-contig
    /// layout, so line width is deterministic).
    private static func indexFASTA(
        plainFASTAURL: URL,
        faiURL: URL,
        contigs: [Contig],
        samtoolsPath: URL?
    ) throws -> [ChromosomeInfo] {
        if let samtools = resolveSamtools(samtoolsPath) {
            try run(tool: "samtools", executable: samtools, arguments: ["faidx", plainFASTAURL.path])
            return try readFAIChromosomes(faiURL: faiURL, contigs: contigs)
        }

        // Analytic fallback: contigs are single-line, so offset is the byte
        // position just after the header line's newline.
        var chromosomes: [ChromosomeInfo] = []
        var runningOffset = 0
        var faiText = ""
        for contig in contigs {
            let headerLine: String
            if let description = contig.fastaDescription, !description.isEmpty {
                headerLine = ">\(contig.name) \(description)\n"
            } else {
                headerLine = ">\(contig.name)\n"
            }
            let headerBytes = headerLine.utf8.count
            let seqBytes = contig.bases.utf8.count
            let offset = runningOffset + headerBytes
            let lineBases = contig.bases.count
            let lineWidth = lineBases + 1
            chromosomes.append(
                ChromosomeInfo(
                    name: contig.name,
                    length: Int64(contig.bases.count),
                    offset: Int64(offset),
                    lineBases: lineBases,
                    lineWidth: lineWidth,
                    fastaDescription: contig.fastaDescription
                )
            )
            faiText += "\(contig.name)\t\(contig.bases.count)\t\(offset)\t\(lineBases)\t\(lineWidth)\n"
            runningOffset = offset + seqBytes + 1
        }
        try faiText.write(to: faiURL, atomically: true, encoding: .utf8)
        return chromosomes
    }

    // MARK: - Indexing (bgzip)

    private static func compressAndIndex(
        plainFASTAURL: URL,
        genomeDir: URL,
        samtoolsPath: URL?,
        bgzipPath: URL?
    ) throws -> (gz: URL, fai: URL, gzi: URL) {
        guard let bgzip = resolveBgzip(bgzipPath) else {
            throw ScaffoldError.toolsUnavailable("bgzip not found (required for .bgzip payload)")
        }
        guard let samtools = resolveSamtools(samtoolsPath) else {
            throw ScaffoldError.toolsUnavailable("samtools not found (required for .bgzip payload)")
        }

        // `bgzip -kf` keeps the plain FASTA and writes `<name>.gz`.
        try run(tool: "bgzip", executable: bgzip, arguments: ["-kf", plainFASTAURL.path])
        let gzURL = genomeDir.appendingPathComponent(plainFASTAURL.lastPathComponent + ".gz")

        // `samtools faidx` on a bgzip file emits BOTH `<gz>.fai` and `<gz>.gzi`.
        try run(tool: "samtools", executable: samtools, arguments: ["faidx", gzURL.path])
        let faiURL = genomeDir.appendingPathComponent(gzURL.lastPathComponent + ".fai")
        let gziURL = genomeDir.appendingPathComponent(gzURL.lastPathComponent + ".gzi")

        guard FileManager.default.fileExists(atPath: faiURL.path),
              FileManager.default.fileExists(atPath: gziURL.path) else {
            throw ScaffoldError.toolFailed(
                tool: "samtools faidx",
                stderr: "expected .fai and .gzi were not produced"
            )
        }
        return (gzURL, faiURL, gziURL)
    }

    /// Parses a samtools `.fai`, merging in the known `fastaDescription`
    /// (`.fai` does not carry the defline description).
    private static func readFAIChromosomes(faiURL: URL, contigs: [Contig]) throws -> [ChromosomeInfo] {
        // Guard against duplicate contig names: `Dictionary(uniqueKeysWithValues:)`
        // traps at runtime on a duplicate key, so build a last-writer-wins map
        // explicitly instead.
        var descriptions: [String: String?] = [:]
        for contig in contigs {
            descriptions[contig.name] = contig.fastaDescription
        }
        let text = try String(contentsOf: faiURL, encoding: .utf8)
        var chromosomes: [ChromosomeInfo] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 5,
                  let length = Int64(fields[1]),
                  let offset = Int64(fields[2]),
                  let lineBases = Int(fields[3]),
                  let lineWidth = Int(fields[4]) else { continue }
            let name = String(fields[0])
            chromosomes.append(
                ChromosomeInfo(
                    name: name,
                    length: length,
                    offset: offset,
                    lineBases: lineBases,
                    lineWidth: lineWidth,
                    fastaDescription: descriptions[name] ?? nil
                )
            )
        }
        return chromosomes
    }

    // MARK: - Built-in preparer (mirrors MappingViewerBundlePreparer)

    /// A self-contained copy of the production preparer's symlink+manifest
    /// logic, used when the caller cannot import `LungfishApp`. It symlinks each
    /// manifest-referenced top-level directory into the source bundle and
    /// records `originBundlePath` (project-relative preferred, filesystem
    /// fallback), matching `MappingViewerBundlePreparer` semantics.
    public static let builtInPreparer: PreparerStep = { sourceBundleURL, viewerBundleURL in
        let fileManager = FileManager.default
        let sourceManifest = try BundleManifest.load(from: sourceBundleURL)

        if fileManager.fileExists(atPath: viewerBundleURL.path) {
            try fileManager.removeItem(at: viewerBundleURL)
        }
        try fileManager.createDirectory(at: viewerBundleURL, withIntermediateDirectories: true)

        for itemName in referencedTopLevelItems(in: sourceManifest).sorted() {
            let sourceItem = sourceBundleURL.appendingPathComponent(itemName)
            guard fileManager.fileExists(atPath: sourceItem.path) else { continue }
            let viewerItem = viewerBundleURL.appendingPathComponent(itemName)
            if fileManager.fileExists(atPath: viewerItem.path) {
                try fileManager.removeItem(at: viewerItem)
            }
            do {
                try fileManager.createSymbolicLink(at: viewerItem, withDestinationURL: sourceItem)
            } catch {
                try fileManager.copyItem(at: sourceItem, to: viewerItem)
            }
        }

        let originBundlePath = FASTQBundle.projectRelativePath(
            for: sourceBundleURL,
            from: viewerBundleURL
        ) ?? filesystemRelativePath(from: viewerBundleURL, to: sourceBundleURL)

        let manifest = BundleManifest(
            formatVersion: sourceManifest.formatVersion,
            name: sourceManifest.name,
            identifier: sourceManifest.identifier,
            description: sourceManifest.description,
            originBundlePath: originBundlePath,
            createdDate: sourceManifest.createdDate,
            modifiedDate: Date(),
            source: sourceManifest.source,
            genome: sourceManifest.genome,
            annotations: sourceManifest.annotations,
            variants: sourceManifest.variants,
            tracks: sourceManifest.tracks,
            alignments: [],
            metadata: sourceManifest.metadata,
            browserSummary: nil
        )
        try manifest.save(to: viewerBundleURL)
    }

    private static func referencedTopLevelItems(in manifest: BundleManifest) -> Set<String> {
        var items = Set<String>()
        if let genome = manifest.genome {
            insertTopLevelItem(from: genome.path, into: &items)
            insertTopLevelItem(from: genome.indexPath, into: &items)
            if let gzipIndexPath = genome.gzipIndexPath {
                insertTopLevelItem(from: gzipIndexPath, into: &items)
            }
        }
        for annotation in manifest.annotations {
            insertTopLevelItem(from: annotation.path, into: &items)
            if let databasePath = annotation.databasePath {
                insertTopLevelItem(from: databasePath, into: &items)
            }
        }
        for variant in manifest.variants {
            insertTopLevelItem(from: variant.path, into: &items)
            insertTopLevelItem(from: variant.indexPath, into: &items)
            if let databasePath = variant.databasePath {
                insertTopLevelItem(from: databasePath, into: &items)
            }
        }
        for track in manifest.tracks {
            insertTopLevelItem(from: track.path, into: &items)
        }
        items.remove(BundleManifest.filename)
        items.remove("alignments")
        return items
    }

    private static func insertTopLevelItem(from path: String, into items: inout Set<String>) {
        guard !path.isEmpty, !path.hasPrefix("/") else { return }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = components.first else { return }
        items.insert(String(first))
    }

    private static func filesystemRelativePath(from baseURL: URL, to targetURL: URL) -> String {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents
        var common = 0
        while common < min(baseComponents.count, targetComponents.count),
              baseComponents[common] == targetComponents[common] {
            common += 1
        }
        let up = Array(repeating: "..", count: max(0, baseComponents.count - common))
        let down = Array(targetComponents.dropFirst(common))
        let parts = up + down
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    // MARK: - Viewer-manifest knobs

    private static func rewriteViewerManifest(
        at viewerBundleURL: URL,
        overrideIdentifier: String?,
        stripOriginBundlePath: Bool
    ) throws {
        let existing = try BundleManifest.load(from: viewerBundleURL)
        let manifest = BundleManifest(
            formatVersion: existing.formatVersion,
            name: existing.name,
            identifier: overrideIdentifier ?? existing.identifier,
            description: existing.description,
            originBundlePath: stripOriginBundlePath ? nil : existing.originBundlePath,
            createdDate: existing.createdDate,
            modifiedDate: existing.modifiedDate,
            source: existing.source,
            genome: existing.genome,
            annotations: existing.annotations,
            variants: existing.variants,
            tracks: existing.tracks,
            alignments: existing.alignments,
            metadata: existing.metadata,
            browserSummary: nil,
            warnings: existing.warnings,
            recordStore: existing.recordStore
        )
        try manifest.save(to: viewerBundleURL)
    }

    // MARK: - Tool discovery

    private static func resolveSamtools(_ override: URL?) -> URL? {
        if let override { return override }
        return BamFixtureBuilder.locateSamtools().map { URL(fileURLWithPath: $0) }
    }

    private static func resolveBgzip(_ override: URL?) -> URL? {
        if let override { return override }
        // bgzip ships alongside samtools in every managed/homebrew install.
        if let samtools = BamFixtureBuilder.locateSamtools() {
            let candidate = URL(fileURLWithPath: samtools)
                .deletingLastPathComponent()
                .appendingPathComponent("bgzip")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        let fallbacks = ["/opt/homebrew/bin/bgzip", "/usr/local/bin/bgzip", "/usr/bin/bgzip"]
        for path in fallbacks where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func run(tool: String, executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ScaffoldError.toolFailed(tool: tool, stderr: stderr)
        }
    }
}
