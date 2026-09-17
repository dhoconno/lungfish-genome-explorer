import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

struct PrimerAnalysisCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analysis",
        abstract: "Inspect saved primer analysis results",
        subcommands: [PrimerAnalysisInspectCommand.self, PrimerAnalysisHistoryCommand.self,
                      PrimerAnalysisAuditCommand.self, PrimerAnalysisAnnotatedReferenceCommand.self]
    )
}

struct PrimerAnalysisInspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Verify stored file integrity and inspect a .lungfishprimeranalysis bundle"
    )

    @Argument(help: "Path to the saved analysis bundle.")
    var bundlePath: String

    @Flag(name: .long, help: "Print the verified manifest as JSON.")
    var json = false

    mutating func run() throws {
        print(try inspectionOutput())
    }

    func inspectionOutput() throws -> String {
        let bundle = try PrimerAnalysisBundle.load(from: URL(fileURLWithPath: bundlePath))
        let manifest = bundle.manifest
        let scientific = try Self.scientificSummary(bundle: bundle)
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(manifest), as: UTF8.self)
        }
        return """
        Analysis: \(manifest.analysisID.uuidString)
        Run: \(manifest.runID.uuidString)
        Grouping: \(manifest.grouping.rawValue)
        Inputs: \(manifest.inputs.count)
        Results: \(manifest.results.count)
        Artifacts: \(manifest.artifacts.count)
        Integrity verified
        \(scientific)
        """
    }

    private static func scientificSummary(bundle: PrimerAnalysisBundle) throws -> String {
        var lines: [String] = []
        for result in bundle.manifest.results {
            let suffix = "native/\(result.id.uuidString)/panel-optimizer.json"
            guard result.artifactPaths.contains(suffix),
                  let artifact = bundle.manifest.artifacts.first(where: { $0.relativePath == suffix }),
                  artifact.role == "nativeOutput" else { continue }
            let root = try JSONSerialization.jsonObject(
                with: Data(contentsOf: bundle.artifactURL(forRelativePath: suffix))) as? [String: Any]
            guard root?["schemaVersion"] as? String == "primalscheme3.panel-optimizer/v2",
                  let metric = root?["metric"] as? String,
                  let primary = root?["primaryTier"] as? String,
                  let profile = root?["profile"] as? [String: Any],
                  let profileName = profile["name"] as? String,
                  let stages = root?["stages"] as? [[String: Any]] else { continue }
            let labelClasses = try alleleLabels(bundle: bundle, result: result, optimizer: root!)
            var displayedLabelClasses = Set<String>()
            lines += ["", "Result: \(result.id.uuidString)", "Metric: \(metric)",
                      "Primary tier: \(primary)", "Profile: \(profileName)"]
            for stage in stages {
                guard let stageID = stage["stage_id"] as? String,
                      let coverage = stage["coverage"] as? [String: Any],
                      let goal = (coverage["goal"] as? NSNumber)?.doubleValue,
                      let targets = coverage["targets"] as? [[String: Any]],
                      let classes = coverage["classes"] as? [[String: Any]] else { continue }
                let mean = (coverage["mean_coverage"] as? NSNumber)?.doubleValue
                lines.append("Tier \(stageID): mean \(fraction(mean)); distinct classes \(classes.count); goal \(fraction(goal))")
                for target in targets {
                    guard let id = target["target_id"] as? String else { continue }
                    let targetFraction = (target["fraction"] as? NSNumber)?.doubleValue
                    let targetClasses = classes.filter { $0["target_id"] as? String == id }
                    let assessable = (target["assessable_classes"] as? NSNumber)?.intValue
                        ?? targetClasses.filter { ($0["fraction"] as? NSNumber) != nil }.count
                    let unassessable = (target["unassessable_classes"] as? NSNumber)?.intValue
                        ?? max(0, targetClasses.count - assessable)
                    let targetCovered = targetClasses.reduce(0) { $0 + (($1["covered_count"] as? NSNumber)?.intValue ?? 0) }
                    let targetObserved = targetClasses.reduce(0) { $0 + (($1["observed_count"] as? NSNumber)?.intValue ?? 0) }
                    let targetDropout = targetFraction == nil || targetObserved == 0
                        ? "unavailable" : (targetCovered == 0 ? "yes" : "no")
                    lines.append("  \(id): mean \(fraction(targetFraction)); assessable classes \(assessable); "
                        + "unassessable classes \(unassessable); covered \(targetCovered)/\(targetObserved); "
                        + "deficit \(deficit(targetFraction, goal: goal)); dropout \(targetDropout)")
                    for observation in targetClasses {
                        let identity = (observation["allele_id"] as? String) ?? "unknown-class"
                        let labelKey = classKey(targetID: id, alleleID: identity)
                        let aliasText: String
                        if let labelClasses {
                            guard let labelClass = labelClasses[labelKey] else {
                                throw ValidationError("The saved allele label map is missing class \(identity) for target \(id).")
                            }
                            displayedLabelClasses.insert(labelKey)
                            let labels = labelClass.rows.map { row in
                                var identifiers = ["native \(row.nativeRowID)"]
                                if let stable = row.stableLGERowID { identifiers.append("LGE \(stable)") }
                                identifiers.append("source \(row.sourceMSAIndex + 1) row \(row.rowIndex + 1)")
                                return "\(row.displayLabel) [\(identifiers.joined(separator: "; "))]"
                            }
                            aliasText = " (labels: \(labels.joined(separator: ", ")))"
                        } else {
                            let aliases = stringArray(observation["aliases"])
                                ?? stringArray(observation["row_ids"])
                                ?? stringArray(observation["source_labels"])
                            aliasText = aliases.map { $0.isEmpty ? "" : " (aliases: \($0.joined(separator: ", ")))" } ?? ""
                        }
                        let covered = (observation["covered_count"] as? NSNumber)?.intValue
                        let observed = (observation["observed_count"] as? NSNumber)?.intValue
                        let classFraction = (observation["fraction"] as? NSNumber)?.doubleValue
                        let counts = covered.flatMap { c in observed.map { "\(c)/\($0)" } } ?? "unavailable"
                        let dropout: String
                        if classFraction == nil || observed == nil || observed == 0 { dropout = "unavailable" }
                        else { dropout = covered == 0 ? "yes" : "no" }
                        lines.append("    Class \(identity)\(aliasText): covered \(counts); fraction \(fraction(classFraction)); "
                            + "deficit \(deficit(classFraction, goal: goal)); dropout \(dropout)")
                    }
                }
            }
            if let labelClasses, displayedLabelClasses != Set(labelClasses.keys) {
                throw ValidationError("The saved allele label map contains classes detached from the coverage report.")
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }

    private static func fraction(_ value: Double?) -> String {
        value.map { String(format: "%.4f", $0) } ?? "unavailable"
    }

    private static func deficit(_ value: Double?, goal: Double) -> String {
        value.map { String(format: "%.4f", max(0, goal - $0)) } ?? "unavailable"
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        if let strings = value as? [String] { return strings }
        if let string = value as? String { return [string] }
        return nil
    }

    private static func classKey(targetID: String, alleleID: String) -> String {
        "\(targetID)\u{1f}\(alleleID)"
    }

    private static func alleleLabels(bundle: PrimerAnalysisBundle, result: PrimerAnalysisResult,
                                     optimizer: [String: Any]) throws
        -> [String: PrimalScheme3AlleleLabelMap.AlleleClass]? {
        let reference = (optimizer["publication"] as? [String: Any])?["alleleLabelMap"] as? [String: Any]
        let paths = result.artifactPaths.filter { path in
            bundle.manifest.artifacts.contains { $0.relativePath == path && $0.role == "derived-label-map" }
        }
        guard reference != nil || !paths.isEmpty else { return nil }
        guard let reference,
              reference["schemaVersion"] as? String == "primalscheme3.allele-label-map/v1",
              let nativePath = reference["path"] as? String, !nativePath.isEmpty,
              paths.count == 1 else {
            throw ValidationError("The advertised allele label map is missing or ambiguous.")
        }
        let map: PrimalScheme3AlleleLabelMap
        do {
            map = try JSONDecoder().decode(PrimalScheme3AlleleLabelMap.self,
                from: Data(contentsOf: bundle.artifactURL(forRelativePath: paths[0])))
        } catch {
            throw ValidationError("The saved allele label map is malformed.")
        }
        guard map.schemaVersion == PrimalScheme3AlleleLabelMap.schemaVersion,
              map.resultID == result.id,
              map.nativeSchemaVersion == "primalscheme3.allele-label-map/v1",
              map.nativeLabelMapRelativePath == nativePath,
              !map.scope.isEmpty else {
            throw ValidationError("The saved allele label map is detached from its native result.")
        }
        var classes: [String: PrimalScheme3AlleleLabelMap.AlleleClass] = [:]
        var rowIDs = Set<String>()
        for alleleClass in map.classes {
            let key = classKey(targetID: alleleClass.targetID, alleleID: alleleClass.alleleID)
            guard !alleleClass.targetID.isEmpty, !alleleClass.alleleID.isEmpty,
                  alleleClass.multiplicity == alleleClass.rows.count,
                  !alleleClass.rows.isEmpty, classes[key] == nil else {
                throw ValidationError("The saved allele label map contains a malformed class.")
            }
            for row in alleleClass.rows {
                guard result.inputIDs.indices.contains(row.sourceMSAIndex),
                      result.inputIDs[row.sourceMSAIndex] == row.inputID,
                      row.rowIndex >= 0, !row.nativeRowID.isEmpty,
                      rowIDs.insert(row.nativeRowID).inserted,
                      !row.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !row.normalizedHeader.isEmpty,
                      row.nativeFASTARecordID == row.normalizedHeader,
                      row.nativeFASTADescription == row.normalizedHeader else {
                    throw ValidationError("The saved allele label map contains a detached row.")
                }
            }
            classes[key] = alleleClass
        }
        return classes
    }
}

struct PrimerAnalysisHistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "history",
        abstract: "Query retained lge.4 panel decision history")
    @Argument(help: "Path to the saved .lungfishprimeranalysis bundle.") var bundlePath: String
    @Option(name: .customLong("result-id")) var resultID: String
    @Option(name: .customLong("primalscheme3-path")) var executablePath: String
    @Option(name: .customLong("output")) var outputPath: String
    @Option var entity: String?; @Option var target: String?; @Option var region: String?
    @Option(help: "One-based pool number.") var pool: Int?
    @Option var stage: String?; @Option var profile: String?
    @Flag var lineage = false
    @Option(help: "Maximum rows to return (1...1000).") var limit = 100
    @Option var offset = 0
    func validate() throws {
        guard UUID(uuidString: resultID) != nil else { throw ValidationError("--result-id must be a UUID.") }
        guard entity != nil || target != nil || region != nil || stage != nil else {
            throw ValidationError("History requires --entity, --target, --region, or --stage.")
        }
        guard (1...1000).contains(limit), offset >= 0, pool.map({ $0 >= 1 }) ?? true else {
            throw ValidationError("History limit must be 1...1000, offset nonnegative, and pool one-based.")
        }
    }
    mutating func run() async throws {
        let output = try await PrimerAnalysisNativeInspectionService().history(
            analysisURL: URL(fileURLWithPath: bundlePath), resultID: UUID(uuidString: resultID)!,
            executableURL: URL(fileURLWithPath: executablePath), outputURL: URL(fileURLWithPath: outputPath),
            query: .init(entity: entity, target: target, region: region, pool: pool, stage: stage,
                         profile: profile, lineage: lineage, limit: limit, offset: offset),
            invocationArgv: CommandLine.arguments)
        print("Panel history written to \(output.path)")
    }
}

struct PrimerAnalysisAuditCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "audit",
        abstract: "Re-audit a retained lge.4 native panel from stored source alignments")
    @Argument(help: "Path to the saved .lungfishprimeranalysis bundle.") var bundlePath: String
    @Option(name: .customLong("result-id")) var resultID: String
    @Option(name: .customLong("primalscheme3-path")) var executablePath: String
    @Option(name: .customLong("output")) var outputPath: String
    @Option var tier: String?
    func validate() throws {
        guard UUID(uuidString: resultID) != nil else { throw ValidationError("--result-id must be a UUID.") }
    }
    mutating func run() async throws {
        let output = try await PrimerAnalysisNativeInspectionService().audit(
            analysisURL: URL(fileURLWithPath: bundlePath), resultID: UUID(uuidString: resultID)!,
            executableURL: URL(fileURLWithPath: executablePath), outputURL: URL(fileURLWithPath: outputPath),
            tier: tier, invocationArgv: CommandLine.arguments)
        print("Panel audit written to \(output.path)")
    }
}


struct PrimerAnalysisAnnotatedReferenceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "annotated-reference",
        abstract: "Create a native reference with linked annotations from a saved Primer3 result"
    )
    @Argument(help: "Path to the saved .lungfishprimeranalysis bundle.") var bundlePath: String
    @Option(name: .customLong("result-id"), help: "Result UUID from `primers analysis inspect --json`.") var resultID: String
    @Option(name: .customLong("output-directory"), help: "Existing destination directory.") var outputDirectory: String

    func validate() throws {
        guard UUID(uuidString: resultID) != nil else { throw ValidationError("--result-id must be a UUID from the saved analysis.") }
    }
    func run() async throws {
        guard let id = UUID(uuidString: resultID) else { throw ValidationError("Invalid result UUID.") }
        let output = try await PrimerAnalysisAnnotatedReferenceService().createReference(
            analysisURL: URL(fileURLWithPath: bundlePath), resultID: id,
            outputDirectory: URL(fileURLWithPath: outputDirectory), invocationArgv: CommandLine.arguments)
        print("Annotated reference written to \(output.path)")
    }
}
