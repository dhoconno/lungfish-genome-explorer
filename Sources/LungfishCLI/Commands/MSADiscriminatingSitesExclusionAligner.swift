import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Runs the managed MAFFT to add exclusion sequences onto a target alignment.
enum MSADiscriminatingSitesExclusionAligner {
    struct Aligned {
        let rows: [(name: String, sequence: String)]
        let command: String
        /// The FASTA actually read, which for a reference bundle is the
        /// resolved primary sequence rather than the bundle directory.
        let resolvedExclusionFASTAURL: URL
    }

    /// Accepts a FASTA file or a `.lungfishref` bundle, whose primary FASTA is
    /// resolved the same way the primer-design inputs resolve it.
    static func align(targetAlignmentURL: URL, exclusionsURL: URL) throws -> Aligned {
        let fastaURL = try resolvedFASTA(for: exclusionsURL)
        let targets = try DiscriminatingSitesFASTA.read(at: targetAlignmentURL)
        guard let expectedWidth = targets.first?.sequence.count else {
            throw DiscriminatingSitesExclusionAligner.Failure.noExclusionSequences(targetAlignmentURL.path)
        }

        let executable = CoreToolLocator.managedExecutableURL(
            environment: "mafft",
            executableName: "mafft",
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw DiscriminatingSitesExclusionAligner.Failure.executableMissing(executable.path)
        }

        // MAFFT reads the exclusion FASTA as a plain file, so a bgzipped
        // reference bundle is decompressed into the scratch directory first.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lungfish-discriminating-sites-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let stagedExclusions = try stage(fastaURL: fastaURL, into: scratch)

        let arguments = DiscriminatingSitesExclusionAligner.arguments(
            exclusionsPath: stagedExclusions.path,
            targetAlignmentPath: targetAlignmentURL.path)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = scratch
        var environment = ProcessInfo.processInfo.environment
        environment["MAFFT_BINARIES"] = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("libexec/mafft").path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DiscriminatingSitesExclusionAligner.Failure.failed(
                process.terminationStatus,
                String(data: errorData, encoding: .utf8) ?? "")
        }

        let combinedURL = scratch.appendingPathComponent("combined.aligned.fasta")
        try outputData.write(to: combinedURL, options: .atomic)
        let combined = try DiscriminatingSitesFASTA.read(at: combinedURL)
        let exclusions = try DiscriminatingSitesExclusionAligner.split(
            combined: combined.map { .init(name: $0.name, sequence: $0.sequence) },
            targetCount: targets.count,
            expectedWidth: expectedWidth)
        guard !exclusions.isEmpty else {
            throw DiscriminatingSitesExclusionAligner.Failure.noExclusionSequences(exclusionsURL.path)
        }
        return Aligned(
            rows: exclusions.map { (name: $0.name, sequence: $0.sequence) },
            command: ([executable.path] + arguments).joined(separator: " "),
            resolvedExclusionFASTAURL: fastaURL)
    }

    private static func resolvedFASTA(for url: URL) throws -> URL {
        guard url.pathExtension.lowercased() == "lungfishref" else { return url }
        guard let resolved = SequenceInputResolver.resolvePrimarySequenceURL(for: url) else {
            throw DiscriminatingSitesExclusionAligner.Failure.noExclusionSequences(url.path)
        }
        return resolved
    }

    private static func stage(fastaURL: URL, into scratch: URL) throws -> URL {
        guard fastaURL.pathExtension.lowercased() == "gz" else { return fastaURL }
        let staged = scratch.appendingPathComponent("exclusions.fasta")
        let text = try GzipInputStream(url: fastaURL).readAllSync()
        try Data(text.utf8).write(to: staged, options: .atomic)
        return staged
    }
}

/// Minimal aligned-FASTA reader shared by the discriminating-sites paths.
enum DiscriminatingSitesFASTA {
    /// Names are reduced to their first whitespace-delimited token, matching how
    /// MAFFT echoes headers and how the rest of LGE addresses accessions.
    static func read(at url: URL) throws -> [(name: String, sequence: String)] {
        let text: String
        if url.pathExtension.lowercased() == "gz" {
            text = try GzipInputStream(url: url).readAllSync()
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        var rows: [(name: String, sequence: String)] = []
        var name: String?
        var chunks: [String] = []
        func flush() {
            guard let name else { return }
            rows.append((name: name, sequence: chunks.joined()))
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(">") {
                flush()
                name = line.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init)
                    ?? String(line.dropFirst())
                chunks = []
            } else {
                chunks.append(line)
            }
        }
        flush()
        return rows
    }
}
