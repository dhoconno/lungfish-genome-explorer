import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO

/// Exports the genotype bundle as a "pivot" XLSX matching the layout used
/// by the lab's notebook-style collaborator template.
///
/// Sheet layout (single sheet, named after the bundle's analysis):
///
///     Row 1: "Animal ID" |  -  |  -  | sample1 | sample2 | ...
///     Row 2: "GS ID"     | Total | Average | sample1 | sample2 | ...
///     Row 3: "Mapped Read Count" | total | average | per-sample counts
///     Row 4: "total_read_count"  |   -   |   -    | per-sample counts
///     Row 5: "percent_reads_unmapped" | - | - | per-sample %
///     Rows 6-19: "MHC-X Haplotype {1,2}" — 14 rows (A,B,DRB,DQA,DQB,DPA,DPB
///                × H1,H2) populated from `haplotypeAnalysis` if present.
///     Row 20: "Comments" | "Subtotal" | "# Obs." | per-sample noncalled
///             haplotype summary
///     Rows 21+: Allele groups. Each group starts with a bold "{species}-X
///             alleles" header row, followed by allele rows sorted by name.
///             Per-sample values are the `passed_unique_reads` count for that
///             allele in that sample (blank if zero).
///
/// Read counts honour the dropout-filtered evaluator (currently
/// `GenotypeDropoutEvaluator` with no thresholds — the persisted analysis
/// is authoritative for haplotype calls). Future work could expose CLI
/// flags to pass per-locus thresholds the same way the inspector does.
///
/// This is provenance-`inspectOnly` (`cli.genotype` policy) — it never
/// modifies the bundle or its sidecar.
struct GenotypeExportPivotXlsxSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-pivot-xlsx",
        abstract: "Export the genotype bundle as a pivot-format XLSX (samples across, alleles down)."
    )

    @Option(name: [.long, .customShort("b")], help: "Path to the .lungfishgenotype bundle.")
    var bundle: String

    @Option(name: [.long, .customShort("o")], help: "Output XLSX path.")
    var output: String

    func validate() throws {
        if bundle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--bundle must not be empty.")
        }
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--output must not be empty.")
        }
    }

    func run() async throws {
        let startedAt = Date()
        let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true)
        let result = try ONTGenotypeResultBundle.loadResult(from: bundleURL)
        // Pick up any analyst-saved dropout/per-locus EQ from the bundle
        // sidecar so the pivot xlsx reflects the same calls the GUI shows
        // — without requiring the analyst to re-export from the inspector.
        let sidecar = try? ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        let workbook = PivotWorkbookBuilder.build(from: result, sidecar: sidecar)

        let outputURL = URL(fileURLWithPath: output)
        let buildDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-genotype-pivot-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: buildDir) }
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        try Self.writeXLSX(to: outputURL, buildDir: buildDir, workbook: workbook)
        try await GenotypeExportProvenanceSupport.record(
            workflowName: "genotype.export.pivot-xlsx",
            toolName: "lungfish genotype export-pivot-xlsx",
            command: [
                "lungfish", "genotype", "export-pivot-xlsx",
                "--bundle", bundleURL.path,
                "--output", outputURL.path,
            ],
            bundleURL: bundleURL,
            outputURLs: [outputURL],
            outputDirectory: outputURL.deletingLastPathComponent(),
            optionPaths: [
                "bundle": bundleURL,
                "output": outputURL,
            ],
            additionalInputURLs: GenotypeActiveHaplotypeAnalysisResolver.activeDefinitionFileURL(
                for: result,
                bundleURL: bundleURL,
                sidecar: sidecar
            ).map { [$0] } ?? [],
            startedAt: startedAt
        )

        let summary: [String: Any] = [
            "bundle": bundleURL.path,
            "output": outputURL.path,
            "sampleCount": workbook.samples.count,
            "alleleCount": workbook.alleleRowCount,
            "alleleGroupCount": workbook.groups.count,
            "haplotypeAnalysisPresent": result.haplotypeAnalysis != nil
        ]
        let summaryData = try JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(summaryData)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    // MARK: - Workbook shape

    struct PivotWorkbook: Equatable {
        let sheetName: String
        let samples: [String]
        /// Per-sample mapped read count (passed alignments after filtering).
        let mappedReadCounts: [Int?]
        /// Per-sample total reads from the sample summary (input).
        let totalReadCounts: [Int?]
        /// Per-sample percent of reads unmapped (`100 - retained_percent`).
        let percentReadsUnmapped: [Double?]
        /// 14 haplotype rows in canonical order (A H1/H2 ... DPB H1/H2).
        /// Each entry: row label, per-sample call (nil = blank).
        let haplotypeRows: [HaplotypeRow]
        /// Per-sample non-called haplotype summary string for the Comments row.
        let commentsRow: [String?]
        /// Allele groups in canonical numeric-prefix order.
        let groups: [AlleleGroup]

        var alleleRowCount: Int { groups.reduce(0) { $0 + $1.alleles.count } }
    }

    struct HaplotypeRow: Equatable {
        let label: String
        /// Per-sample call (matches `samples` order).
        let values: [String?]
    }

    struct AlleleGroup: Equatable {
        let label: String
        let alleles: [AlleleRow]
    }

    struct AlleleRow: Equatable {
        let name: String
        /// Per-sample read count; `nil` means blank (zero).
        let counts: [Int?]
    }

    // MARK: - Building the workbook

    enum PivotWorkbookBuilder {
        /// Canonical seven loci × two haplotype slots, in the same order as
        /// the lab's reference workbook.
        static let canonicalLoci: [String] = [
            "MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB",
        ]

        /// Map allele prefix → display label suffix. The species code prefix
        /// (e.g. `Mafa`) is filled in at build time.
        static let prefixGroups: [(prefix: String, suffix: String)] = [
            ("01", "-F alleles"),
            ("02", "-G alleles"),
            ("04", "-AG alleles"),
            ("05", "-A major alleles"),
            ("06", "-A minor alleles"),
            ("07", "-70 alleles"),
            ("10", "-L alleles"),
            ("11", "-E alleles"),
            ("12", "-B alleles"),
            ("13", "-DRB alleles"),
            ("14", "-DQA/DQB alleles"),
            ("15", "-DPA/DPB alleles"),
        ]

        static func build(from result: ONTGenotypeResultBundleData) -> PivotWorkbook {
            build(from: result, sidecar: nil)
        }

        static func build(from result: ONTGenotypeResultBundleData, sidecar: GenotypeAnnotationSidecar?) -> PivotWorkbook {
            let samples = result.samples.map(\.sample)
            let mappedReadCounts = result.samples.map { Optional($0.passedAlignments) }
            let totalReadCounts = result.samples.map(\.sampleTotalReads)
            let percentReadsUnmapped: [Double?] = result.samples.map { sample in
                guard let retained = sample.sampleUniqueRetainedPercent else { return nil }
                return max(0, min(100, 100 - retained))
            }

            let activeAnalysis = GenotypeActiveHaplotypeAnalysisResolver.activeAnalysis(
                for: result,
                sidecar: sidecar
            )
            let haplotypeRows = makeHaplotypeRows(samples: samples, analysis: activeAnalysis)
            let commentsRow = makeCommentsRow(samples: samples, analysis: activeAnalysis)

            // Build allele groups. Group key is the leading numeric prefix
            // of the genotype name (e.g. `01_M1_F_01_w_06` → "01").
            // Per (sample × genotype) count = sum of passedUniqueReads
            // across all calls with that genotype for that sample.
            var countsByGenotypeBySample: [String: [String: Int]] = [:]
            for call in result.calls {
                countsByGenotypeBySample[call.genotype, default: [:]][call.sample, default: 0] += call.passedUniqueReads
            }
            let genotypesByPrefix: [String: [String]] = Dictionary(
                grouping: Array(countsByGenotypeBySample.keys),
                by: { leadingNumericPrefix($0) ?? "??" }
            )
            let speciesPrefix = speciesPrefix(from: result.haplotypeAnalysis)

            var groups: [AlleleGroup] = []
            // Emit groups in canonical prefix order, skipping any that
            // contain no observed genotypes.
            var seenPrefixes = Set<String>()
            for (prefix, suffix) in prefixGroups {
                seenPrefixes.insert(prefix)
                guard let names = genotypesByPrefix[prefix], !names.isEmpty else { continue }
                let alleles = makeAlleleRows(
                    genotypeNames: names,
                    samples: samples,
                    countsByGenotypeBySample: countsByGenotypeBySample
                )
                groups.append(AlleleGroup(label: speciesPrefix + suffix, alleles: alleles))
            }
            // Trailing bucket for any unexpected prefix so nothing is lost.
            let leftover = genotypesByPrefix.keys.filter { !seenPrefixes.contains($0) }.sorted()
            for prefix in leftover {
                guard let names = genotypesByPrefix[prefix], !names.isEmpty else { continue }
                let alleles = makeAlleleRows(
                    genotypeNames: names,
                    samples: samples,
                    countsByGenotypeBySample: countsByGenotypeBySample
                )
                let label = prefix == "??"
                    ? "Other alleles"
                    : "\(speciesPrefix)-\(prefix) alleles"
                groups.append(AlleleGroup(label: label, alleles: alleles))
            }

            let sheetName = sanitizedSheetName(result.manifest.analysisName)

            return PivotWorkbook(
                sheetName: sheetName,
                samples: samples,
                mappedReadCounts: mappedReadCounts,
                totalReadCounts: totalReadCounts,
                percentReadsUnmapped: percentReadsUnmapped,
                haplotypeRows: haplotypeRows,
                commentsRow: commentsRow,
                groups: groups
            )
        }

        private static func makeHaplotypeRows(
            samples: [String],
            analysis: GenotypeHaplotypeAnalysis?
        ) -> [HaplotypeRow] {
            var rows: [HaplotypeRow] = []
            // Build (sample → locus → call) map from the persisted analysis.
            var callsBySampleLocus: [String: [String: GenotypeHaplotypeLocusCall]] = [:]
            if let analysis {
                for sample in analysis.samples {
                    var locusMap: [String: GenotypeHaplotypeLocusCall] = [:]
                    for call in sample.calls {
                        locusMap[call.locus] = call
                    }
                    callsBySampleLocus[sample.sample] = locusMap
                }
            }
            for locus in canonicalLoci {
                for slot in 1...2 {
                    let label = "\(locus) Haplotype \(slot)"
                    let values: [String?] = samples.map { sample in
                        guard let call = callsBySampleLocus[sample]?[locus] else { return nil }
                        let raw = slot == 1 ? call.haplotype1 : call.haplotype2
                        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    rows.append(HaplotypeRow(label: label, values: values))
                }
            }
            return rows
        }

        private static func makeCommentsRow(
            samples: [String],
            analysis: GenotypeHaplotypeAnalysis?
        ) -> [String?] {
            guard let analysis else {
                return Array(repeating: nil, count: samples.count)
            }
            let callsBySample: [String: [GenotypeHaplotypeLocusCall]] = Dictionary(
                uniqueKeysWithValues: analysis.samples.map { ($0.sample, $0.calls) }
            )
            return samples.map { sample in
                guard let calls = callsBySample[sample] else { return nil }
                let messages = calls
                    .sorted { $0.locus.localizedStandardCompare($1.locus) == .orderedAscending }
                    .compactMap { call -> String? in
                        guard call.status != .called, call.status != .notAssayed else { return nil }
                        let left = call.haplotype1
                        let right = call.haplotype2
                        let label = (left == right || right.isEmpty) ? left : "\(left)/\(right)"
                        return "\(call.locus): \(label)"
                    }
                return messages.isEmpty ? nil : messages.joined(separator: "; ")
            }
        }

        private static func makeAlleleRows(
            genotypeNames: [String],
            samples: [String],
            countsByGenotypeBySample: [String: [String: Int]]
        ) -> [AlleleRow] {
            let sortedNames = genotypeNames.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            return sortedNames.map { name in
                let perSample = countsByGenotypeBySample[name] ?? [:]
                let counts: [Int?] = samples.map { sample in
                    let count = perSample[sample] ?? 0
                    return count > 0 ? count : nil
                }
                return AlleleRow(name: name, counts: counts)
            }
        }

        private static func leadingNumericPrefix(_ genotype: String) -> String? {
            let scanner = Scanner(string: genotype)
            scanner.charactersToBeSkipped = nil
            var digits = ""
            while let scalar = scanner.scanCharacter(), scalar.isNumber {
                digits.append(scalar)
            }
            return digits.isEmpty ? nil : digits
        }

        private static func speciesPrefix(from analysis: GenotypeHaplotypeAnalysis?) -> String {
            // Prefer the canonical Mafa/Mamu code from the analysis manifest;
            // fall back to "Mafa" which matches the existing template.
            if let analysis {
                // GenotypeHaplotypeAnalysis stores speciesName, not the
                // shorthand code. Use the assay's definition set lookup if
                // possible by parsing the species name (e.g. "Macaca
                // fascicularis" → "Mafa"). When unparseable, fall back to
                // the first four characters of the species code if it looks
                // like a Mafa-style abbreviation.
                let speciesCode = inferSpeciesCode(speciesName: analysis.speciesName)
                if !speciesCode.isEmpty {
                    return speciesCode
                }
            }
            return "Mafa"
        }

        private static func inferSpeciesCode(speciesName: String) -> String {
            let lowered = speciesName.lowercased()
            if lowered.contains("fascicularis") { return "Mafa" }
            if lowered.contains("mulatta") { return "Mamu" }
            if lowered.contains("nemestrina") { return "Mane" }
            if lowered.contains("fuscata") { return "Mafu" }
            if lowered.contains("tonkeana") { return "Mato" }
            if lowered.contains("leonina") { return "Male" }
            if lowered.contains("thibetana") { return "Math" }
            // Unknown — return empty so caller falls back to "Mafa".
            return ""
        }

        /// XLSX sheet names are limited to 31 characters and cannot include
        /// `:`, `\`, `/`, `?`, `*`, `[`, `]`. Empty names fall back to
        /// "Genotype" to match the template behavior.
        static func sanitizedSheetName(_ name: String) -> String {
            let illegal: Set<Character> = [":", "\\", "/", "?", "*", "[", "]"]
            var sanitized = String(name.filter { !illegal.contains($0) })
            sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
            if sanitized.isEmpty {
                sanitized = "Genotype"
            }
            if sanitized.count > 31 {
                sanitized = String(sanitized.prefix(31))
            }
            return sanitized
        }
    }

    // MARK: - Workbook output

    private static func writeXLSX(
        to outputURL: URL,
        buildDir: URL,
        workbook: PivotWorkbook
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: buildDir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildDir.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: buildDir.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)

        try contentTypesXML.write(to: buildDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try rootRelsXML.write(to: buildDir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try makeWorkbookXML(sheetName: workbook.sheetName).write(to: buildDir.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
        try workbookRelsXML.write(to: buildDir.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
        try stylesXML.write(to: buildDir.appendingPathComponent("xl/styles.xml"), atomically: true, encoding: .utf8)
        try makePivotSheet(workbook).write(to: buildDir.appendingPathComponent("xl/worksheets/sheet1.xml"), atomically: true, encoding: .utf8)

        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = buildDir
        zip.arguments = ["-qr", outputURL.path, "."]
        try zip.run()
        zip.waitUntilExit()
        if zip.terminationStatus != 0 {
            throw GenotypeExportPivotXlsxError.zipFailed
        }
    }

    private static func makePivotSheet(_ workbook: PivotWorkbook) -> String {
        var sheet = sheetHeader()
        var rowIndex = 1

        // Row 1: "Animal ID" | (blank) | (blank) | samples...
        sheet += rowXML(
            index: rowIndex,
            cells: [.boldLabel("Animal ID"), .blank, .blank]
                + workbook.samples.map { Cell.boldLabel($0) }
        )
        rowIndex += 1

        // Row 2: "GS ID" | "Total" | "Average" | samples...
        sheet += rowXML(
            index: rowIndex,
            cells: [.boldLabel("GS ID"), .boldLabel("Total"), .boldLabel("Average")]
                + workbook.samples.map { Cell.boldLabel($0) }
        )
        rowIndex += 1

        // Row 3: Mapped Read Count
        let mappedTotal = workbook.mappedReadCounts.compactMap { $0 }.reduce(0, +)
        let mappedAverage = average(workbook.mappedReadCounts)
        sheet += rowXML(
            index: rowIndex,
            cells: [.label("Mapped Read Count"), .number(Double(mappedTotal)), averageCell(mappedAverage)]
                + workbook.mappedReadCounts.map { count in count.map { .number(Double($0)) } ?? .blank }
        )
        rowIndex += 1

        // Row 4: total_read_count
        sheet += rowXML(
            index: rowIndex,
            cells: [.label("total_read_count"), .blank, .blank]
                + workbook.totalReadCounts.map { count in count.map { .number(Double($0)) } ?? .blank }
        )
        rowIndex += 1

        // Row 5: percent_reads_unmapped
        sheet += rowXML(
            index: rowIndex,
            cells: [.label("percent_reads_unmapped"), .blank, .blank]
                + workbook.percentReadsUnmapped.map { value in value.map { .percent($0) } ?? .blank }
        )
        rowIndex += 1

        // Rows 6-19: Haplotype rows.
        for haplotypeRow in workbook.haplotypeRows {
            sheet += rowXML(
                index: rowIndex,
                cells: [.label(haplotypeRow.label), .blank, .blank]
                    + haplotypeRow.values.map { value in value.map { .label($0) } ?? .blank }
            )
            rowIndex += 1
        }

        // Row 20: Comments
        sheet += rowXML(
            index: rowIndex,
            cells: [.label("Comments"), .boldLabel("Subtotal"), .boldLabel("# Obs.")]
                + workbook.commentsRow.map { value in value.map { .label($0) } ?? .blank }
        )
        rowIndex += 1

        // Allele groups.
        for group in workbook.groups {
            // Bold header row.
            sheet += rowXML(
                index: rowIndex,
                cells: [.boldLabel(group.label), .blank, .blank]
                    + Array(repeating: Cell.blank, count: workbook.samples.count)
            )
            rowIndex += 1
            for allele in group.alleles {
                let subtotal = allele.counts.compactMap { $0 }.reduce(0, +)
                let obs = allele.counts.compactMap { $0 }.filter { $0 > 0 }.count
                sheet += rowXML(
                    index: rowIndex,
                    cells: [
                        .label(allele.name),
                        subtotal > 0 ? .number(Double(subtotal)) : .blank,
                        obs > 0 ? .number(Double(obs)) : .blank,
                    ] + allele.counts.map { count in count.map { .number(Double($0)) } ?? .blank }
                )
                rowIndex += 1
            }
        }

        sheet += sheetFooter()
        return sheet
    }

    private static func average(_ values: [Int?]) -> Double? {
        let presentValues = values.compactMap { $0 }
        guard !presentValues.isEmpty else { return nil }
        let sum = presentValues.reduce(0, +)
        return Double(sum) / Double(presentValues.count)
    }

    private static func averageCell(_ value: Double?) -> Cell {
        guard let value else { return .blank }
        return .number(value)
    }

    // MARK: - Cell helpers

    /// Cell variants used by the pivot sheet.
    private enum Cell {
        case blank
        case label(String)
        case boldLabel(String)
        case number(Double)
        case percent(Double)

        var styleID: Int {
            switch self {
            case .blank, .label: return 0
            case .boldLabel: return 1
            case .number: return 0
            case .percent: return 2
            }
        }
    }

    private static func sheetHeader() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>

        """
    }

    private static func sheetFooter() -> String {
        "</sheetData></worksheet>"
    }

    private static func rowXML(index: Int, cells: [Cell]) -> String {
        let cellXML = cells.enumerated().map { (col, cell) -> String in
            let ref = "\(columnLetter(col + 1))\(index)"
            switch cell {
            case .blank:
                return ""
            case .label(let value), .boldLabel(let value):
                let escaped = xmlEscape(value)
                return #"<c r="\#(ref)" s="\#(cell.styleID)" t="inlineStr"><is><t xml:space="preserve">\#(escaped)</t></is></c>"#
            case .number(let value):
                return #"<c r="\#(ref)" s="\#(cell.styleID)"><v>\#(formatNumber(value))</v></c>"#
            case .percent(let value):
                return #"<c r="\#(ref)" s="\#(cell.styleID)"><v>\#(formatNumber(value))</v></c>"#
            }
        }.joined()
        return #"<row r="\#(index)">\#(cellXML)</row>"# + "\n"
    }

    private static func formatNumber(_ value: Double) -> String {
        // Avoid emitting scientific notation; preserve up to 6 fractional
        // digits like the openpyxl pipeline output.
        if value.rounded() == value && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.6f", value)
    }

    private static func columnLetter(_ oneBased: Int) -> String {
        var n = oneBased
        var result = ""
        while n > 0 {
            n -= 1
            let scalar = UnicodeScalar(65 + (n % 26))!
            result = String(scalar) + result
            n /= 26
        }
        return result
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - Workbook scaffolding

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static func makeWorkbookXML(sheetName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="\(xmlEscape(sheetName))" sheetId="1" r:id="rId1"/>
          </sheets>
        </workbook>
        """
    }

    private static let workbookRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    /// Three styles:
    ///   0 = default (no fill, regular font)
    ///   1 = bold (for section headers and table headers)
    ///   2 = percent (uses numFmtId 9, "0%") — actually we use 0.0 so values
    ///       show with one decimal place to match `45.7`-style entries.
    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <numFmts count="1"><numFmt numFmtId="164" formatCode="0.0"/></numFmts>
      <fonts count="2">
        <font><sz val="11"/><name val="Aptos"/></font>
        <font><b/><sz val="11"/><name val="Aptos"/></font>
      </fonts>
      <fills count="2">
        <fill><patternFill patternType="none"/></fill>
        <fill><patternFill patternType="gray125"/></fill>
      </fills>
      <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
      <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
      <cellXfs count="3">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
      </cellXfs>
      <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
    </styleSheet>
    """
}

enum GenotypeExportPivotXlsxError: Error, LocalizedError {
    case zipFailed

    var errorDescription: String? {
        switch self {
        case .zipFailed: return "Failed to zip the pivot XLSX archive."
        }
    }
}
