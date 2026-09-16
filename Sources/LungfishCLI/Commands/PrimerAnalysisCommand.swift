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
        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(manifest), as: UTF8.self)
        }
        let scientific = try Self.scientificSummary(bundle: bundle)
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
            lines += ["", "Result: \(result.id.uuidString)", "Metric: \(metric)",
                      "Primary tier: \(primary)", "Profile: \(profileName)"]
            for stage in stages {
                guard let stageID = stage["stage_id"] as? String,
                      let coverage = stage["coverage"] as? [String: Any],
                      let mean = (coverage["mean_coverage"] as? NSNumber)?.doubleValue,
                      let goal = (coverage["goal"] as? NSNumber)?.doubleValue,
                      let targets = coverage["targets"] as? [[String: Any]],
                      let classes = coverage["classes"] as? [[String: Any]] else { continue }
                lines.append(String(format: "Tier %@: mean %.4f; distinct classes %d", stageID, mean, classes.count))
                for target in targets {
                    guard let id = target["target_id"] as? String,
                          let fraction = (target["fraction"] as? NSNumber)?.doubleValue else { continue }
                    let targetClasses = classes.filter { $0["target_id"] as? String == id }
                    let denominator = targetClasses.reduce(0) { $0 + (($1["observed_count"] as? NSNumber)?.intValue ?? 0) }
                    lines.append(String(format: "  %@: mean %.4f; denominator %d; deficit %.4f",
                                        id, fraction, denominator, max(0, goal - fraction)))
                }
            }
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
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
    @Option var pool: Int?; @Option var stage: String?; @Option var profile: String?
    @Flag var lineage = false; @Option var limit = 100; @Option var offset = 0
    func validate() throws {
        guard UUID(uuidString: resultID) != nil else { throw ValidationError("--result-id must be a UUID.") }
        guard entity != nil || target != nil || region != nil || stage != nil else {
            throw ValidationError("History requires --entity, --target, --region, or --stage.")
        }
        guard limit > 0, offset >= 0, pool.map({ $0 >= 0 }) ?? true else {
            throw ValidationError("History limit must be positive and offset/pool nonnegative.")
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
