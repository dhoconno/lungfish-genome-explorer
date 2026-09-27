import Foundation

/// The lineage-assignment tools whose per-sample tables a Viral Recon run
/// leaves behind, and how to tell which tool wrote a given file.
///
/// viralrecon names Pangolin's table `<sample>.pangolin.csv` and Freyja's
/// `<sample>.demix.tsv`, but Nextclade's is plain `<sample>.csv`: only its
/// folder (`.../consensus/bcftools/nextclade/`) says which tool produced it.
/// The Inspector catalogue used to label rows by file name alone, so the
/// Nextclade row was shown under its bare file name.
public enum ViralReconLineageTool: String, Sendable, Equatable, CaseIterable {
    case pangolin
    case nextclade
    case freyja

    /// The tool that wrote `url`, from its enclosing folder first, then its
    /// file name, then (for a table already copied into a flat `lineage/`
    /// folder under a bare name) its header row.
    public static func classify(_ url: URL, fileManager: FileManager = .default) -> ViralReconLineageTool? {
        if let tool = fromFolder(url) { return tool }
        if let tool = fromFileName(url) { return tool }
        return fromHeader(url, fileManager: fileManager)
    }

    /// The enclosing folder names viralrecon uses for each tool.
    public static func fromFolder(_ url: URL) -> ViralReconLineageTool? {
        let folder = url.deletingLastPathComponent().lastPathComponent.lowercased()
        switch folder {
        case "pangolin": return .pangolin
        case "nextclade": return .nextclade
        case "demix", "freyja": return .freyja
        default: return nil
        }
    }

    public static func fromFileName(_ url: URL) -> ViralReconLineageTool? {
        let name = url.lastPathComponent.lowercased()
        if name.contains("pangolin") { return .pangolin }
        if name.contains("nextclade") { return .nextclade }
        if name.contains("demix") || name.contains("freyja") { return .freyja }
        return nil
    }

    /// Sniffs the header row: Pangolin's CSV starts `taxon,lineage,...`,
    /// Nextclade's CSV `seqName;clade;...` (semicolon separated, with a
    /// `clade` column), and Freyja's demix TSV carries `summarized` and
    /// `lineages` rows. Reads at most the first 4 KiB.
    public static func fromHeader(_ url: URL, fileManager: FileManager = .default) -> ViralReconLineageTool? {
        guard fileManager.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map { $0.lowercased() } ?? ""
        let columns = Set(firstLine.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) })
        if columns.contains("taxon"), columns.contains("lineage") { return .pangolin }
        if columns.contains("clade"), columns.contains("seqname") { return .nextclade }
        if columns.contains("summarized") || columns.contains("lineages") || text.lowercased().hasPrefix("\tsummarized") {
            return .freyja
        }
        return nil
    }

    /// The Inspector row label for the tool's table.
    public var rowLabel: String {
        switch self {
        case .pangolin: return "Pangolin Lineage"
        case .nextclade: return "Nextclade Clade"
        case .freyja: return "Freyja Variant Mix"
        }
    }

    /// The token a copied file name should carry so the tool is recoverable
    /// once the file leaves its folder: `S1.csv` from the nextclade folder is
    /// copied as `S1.nextclade.csv`.
    public var fileNameToken: String { rawValue }

    /// `url`'s file name with this tool's token inserted before the extension
    /// when the name does not already say which tool wrote it.
    public func qualifiedFileName(for url: URL) -> String {
        if Self.fromFileName(url) != nil { return url.lastPathComponent }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return ext.isEmpty ? "\(stem).\(fileNameToken)" : "\(stem).\(fileNameToken).\(ext)"
    }
}

extension ViralReconResultInventory {
    /// Whether a per-sample output file belongs to `sampleName`: viralrecon
    /// names every per-sample table `<sample>.<...>`, so a file belongs to a
    /// sample when its name is the sample or starts with `<sample>.` (a
    /// bare prefix match would hand `S10`'s files to `S1`).
    public static func fileBelongs(toSample sampleName: String, _ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == sampleName || name.hasPrefix("\(sampleName).")
    }
}
