import Foundation

/// The lineage-assignment tools whose per-sample tables a Viral Recon run
/// leaves behind, and how to tell which tool wrote a given file.
///
/// viralrecon names Pangolin's table `<sample>.pangolin.csv`, but Nextclade's
/// is plain `<sample>.csv` and Freyja's plain `<sample>.tsv`: only their
/// folders (`.../consensus/bcftools/nextclade/`, `variants/freyja/demix/`)
/// say which tool produced them.
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

extension ViralReconLineageTool {
    /// The results folder, under the results directory, that holds this
    /// tool's per-sample tables in an Illumina run of viralrecon 3.0.0.
    public var resultsFolder: String {
        switch self {
        case .pangolin: return "variants/ivar/consensus/bcftools/pangolin"
        case .nextclade: return "variants/ivar/consensus/bcftools/nextclade"
        case .freyja: return "variants/freyja/demix"
        }
    }

    /// The one file name this tool's table has for `sampleName` in viralrecon
    /// 3.0.0: Pangolin's `--outfile ${prefix}.pangolin.csv`, Nextclade's
    /// published `${prefix}.csv` and Freyja demix's `--output ${prefix}.tsv`,
    /// where the prefix is the sample's id.
    ///
    /// A table belongs to a sample only when its name is exactly this. A
    /// prefix match on `<sample>.` handed `S1` the tables of `S1.1`, a name
    /// viralrecon accepts (trust session FIX-VR, F2).
    public func tableFileName(forSample sampleName: String) -> String {
        switch self {
        case .pangolin: return "\(sampleName).pangolin.csv"
        case .nextclade: return "\(sampleName).csv"
        case .freyja: return "\(sampleName).tsv"
        }
    }
}
