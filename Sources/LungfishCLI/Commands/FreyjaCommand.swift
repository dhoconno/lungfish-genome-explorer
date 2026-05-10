import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

struct FreyjaCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "freyja",
        abstract: "Construct and run Freyja wastewater lineage demixing plans",
        subcommands: [DemixSubcommand.self]
    )

    struct DemixSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "demix",
            abstract: "Construct a Freyja demix command plan from variant and depth tables"
        )

        @Flag(name: .customLong("execute"), help: "Run Freyja through the wastewater-surveillance tool pack.")
        var execute: Bool = false

        @Flag(name: .customLong("dry-run"), help: "Write and print the command plan without running Freyja.")
        var dryRun: Bool = false

        @Option(name: .customLong("variants"), help: "Freyja variants table from freyja variants")
        var variantsPath: String

        @Option(name: .customLong("depths"), help: "Freyja depths table from freyja variants")
        var depthsPath: String

        @Option(name: .customLong("output-dir"), help: "Output directory for plan, provenance, and demix output")
        var outputDirectory: String

        @Option(name: .customLong("sample"), help: "Optional sample identifier")
        var sampleName: String?

        @Option(name: .customLong("extra-args"), parsing: .unconditional, help: "Additional Freyja demix arguments")
        var extraArgs: String = ""

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse freyja demix arguments.")
            }
            return parsed
        }

        func run() async throws {
            try await executeForTesting { print($0) }
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws {
            let startedAt = Date()
            let outputDirURL = URL(fileURLWithPath: outputDirectory)
            try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
            let plan = try buildPlan(outputDirURL: outputDirURL)
            let planURL = outputDirURL.appendingPathComponent("freyja-command-plan.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(plan).write(to: planURL, options: .atomic)

            emit(plan.shellCommand)
            if execute && !dryRun {
                let result = try await CondaManager.shared.runTool(
                    name: "freyja",
                    arguments: Array(plan.command.dropFirst()),
                    environment: "freyja",
                    workingDirectory: outputDirURL,
                    timeout: 24 * 60 * 60
                )
                guard result.exitCode == 0 else {
                    throw CLIError.workflowFailed(reason: result.stderr.isEmpty ? result.stdout : result.stderr)
                }
                emit("Freyja demix complete.")
            } else {
                emit("Command plan: \(planURL.path)")
            }

            let completedAt = Date()
            try VariantsCommand.writeCommandPlanProvenance(
                workflowName: plan.workflowName,
                workflowVersion: plan.workflowVersion,
                command: ["lungfish", "freyja", "demix"] + originalArguments(),
                inputs: plan.inputs,
                outputs: [ProvenanceRecorder.fileRecord(url: planURL, format: .json, role: .output)] + plan.outputs,
                parameters: [
                    "packID": .string(plan.packID),
                    "execute": .string(String(execute && !dryRun)),
                    "sampleName": .string(sampleName ?? ""),
                    "runtime": .string(plan.runtimeIdentity),
                    "containerRuntime": .string("none"),
                    "options": .dictionary(plan.options.mapValues { .string($0) }),
                    "resolvedDefaults": .dictionary(plan.resolvedDefaults.mapValues { .string($0) }),
                ],
                outputDirectory: outputDirURL,
                startedAt: startedAt,
                completedAt: completedAt
            )
        }

        private func buildPlan(outputDirURL: URL) throws -> FreyjaDemixPlan {
            FreyjaDemixPlan(
                configuration: FreyjaDemixConfiguration(
                    variantsURL: URL(fileURLWithPath: variantsPath),
                    depthsURL: URL(fileURLWithPath: depthsPath),
                    outputDirectory: outputDirURL,
                    sampleName: sampleName,
                    extraArguments: try GATKCLICommand.parseExtraArgs(extraArgs)
                ),
                toolVersion: PluginPack.builtInPack(id: "wastewater-surveillance")?
                    .toolRequirements.first(where: { $0.id == "freyja" })?.version ?? "unknown",
                runtimeIdentity: CondaManager.shared.rootPrefix
                    .appendingPathComponent("envs/freyja", isDirectory: true).path,
                workflowVersion: "lungfish-cli \(LungfishCLI.configuration.version)"
            )
        }

        private func originalArguments() -> [String] {
            var args = [
                "--variants", variantsPath,
                "--depths", depthsPath,
                "--output-dir", outputDirectory,
            ]
            if let sampleName {
                args += ["--sample", sampleName]
            }
            if !extraArgs.isEmpty {
                args += ["--extra-args", extraArgs]
            }
            if execute {
                args.append("--execute")
            }
            if dryRun {
                args.append("--dry-run")
            }
            return args
        }
    }
}
