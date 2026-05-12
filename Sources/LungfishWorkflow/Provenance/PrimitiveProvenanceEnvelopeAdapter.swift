// PrimitiveProvenanceEnvelopeAdapter.swift - Compatibility bridge for pre-canonical provenance JSON
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

enum PrimitiveProvenanceEnvelopeAdapter {
    static func decode(_ data: Data, sourceURL: URL?, fallbackCreatedAt: Date? = nil) throws -> ProvenanceEnvelope {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let json = object as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Primitive provenance must be a JSON object"
                )
            )
        }

        let provenanceJSON = latestLogEntry(in: json) ?? json
        let createdAt = date(provenanceJSON, keys: [
            "createdAt",
            "created_at",
            "timestamp",
            "assembly_date",
            "startTime",
            "startedAt",
            "completedAt",
            "endTime",
            "extractionDate",
            "extraction_date",
            "recordedAt",
            "recorded_at",
        ]) ?? fallbackCreatedAt ?? Date(timeIntervalSince1970: 0)
        let runtime = runtimeIdentity(provenanceJSON)
        let inputs = inputDescriptors(provenanceJSON)
        var outputs = outputDescriptors(provenanceJSON)
        if outputs.isEmpty, let contextOutput = contextualOutputDescriptor(sourceURL: sourceURL) {
            outputs.append(contextOutput)
        }

        let files = deduplicated(
            inputs
                + outputs
                + fileMapDescriptors(provenanceJSON)
                + checksumMapDescriptors(provenanceJSON)
        )
        let workflowName = inferredWorkflowName(provenanceJSON)
        let toolName = inferredToolName(provenanceJSON, workflowName: workflowName)
        let toolVersion = inferredToolVersion(provenanceJSON)
        let argv = stringArray(provenanceJSON, keys: ["argv", "command"]) ?? []
        let reproducibleCommand = string(provenanceJSON, keys: [
            "reproducibleCommand",
            "reproducibleShellCommand",
            "command",
            "command_line",
            "commandLine",
            "launcher_command",
            "launcherCommand",
        ]) ?? argv.map(shellEscape).joined(separator: " ")
        let steps = primitiveSteps(
            provenanceJSON,
            defaultToolName: toolName,
            defaultToolVersion: toolVersion,
            argv: argv,
            reproducibleCommand: reproducibleCommand,
            inputs: inputs,
            outputs: outputs,
            createdAt: createdAt
        )

        return ProvenanceEnvelope(
            schemaVersion: int(json, keys: ["schemaVersion", "schema_version"]) ?? 1,
            createdAt: createdAt,
            workflowName: workflowName,
            workflowVersion: inferredWorkflowVersion(provenanceJSON),
            toolName: toolName,
            toolVersion: toolVersion,
            argv: argv,
            reproducibleCommand: reproducibleCommand,
            options: provenanceOptions(provenanceJSON),
            runtimeIdentity: runtime,
            files: files,
            output: outputs.first,
            outputs: outputs,
            steps: steps,
            wallTimeSeconds: double(provenanceJSON, keys: ["wallTimeSeconds", "wall_time_seconds", "wallTime"]),
            exitStatus: int(provenanceJSON, keys: ["exitStatus", "exit_status", "exitCode"]),
            stderr: string(provenanceJSON, keys: ["stderr"])
        )
    }

    private static func latestLogEntry(in json: [String: Any]) -> [String: Any]? {
        guard let entries = json["entries"] as? [[String: Any]],
              !entries.isEmpty else {
            return nil
        }
        return entries.max { lhs, rhs in
            let lhsDate = date(lhs, keys: ["recordedAt", "recorded_at", "createdAt", "timestamp"])
                ?? Date(timeIntervalSince1970: 0)
            let rhsDate = date(rhs, keys: ["recordedAt", "recorded_at", "createdAt", "timestamp"])
                ?? Date(timeIntervalSince1970: 0)
            return lhsDate < rhsDate
        }
    }

    private static func inferredWorkflowName(_ json: [String: Any]) -> String {
        if let assembler = string(json, keys: ["assembler"]) {
            return "assembly.\(machineToken(assembler))"
        }
        if let workflowName = string(json, keys: ["workflowName", "workflow_name", "name", "operation", "actionID"]) {
            return workflowName
        }
        if json["extractionDate"] != nil || json["extraction_date"] != nil {
            return "read-extraction"
        }
        if looksLikeTreeProvenance(json) {
            return "phylogenetic-tree-import"
        }
        if let toolName = string(json, keys: ["toolName", "tool_name"]) {
            return machineToken(toolName)
        }
        return "unknown"
    }

    private static func inferredWorkflowVersion(_ json: [String: Any]) -> String {
        string(json, keys: ["workflowVersion", "workflow_version", "lungfish_version", "lungfishVersion", "appVersion"])
            ?? WorkflowRun.currentAppVersion
    }

    private static func inferredToolName(_ json: [String: Any], workflowName: String) -> String {
        if let toolName = string(json, keys: ["toolName", "tool_name"]) {
            return toolName
        }
        if let tool = dictionary(json["tool"]),
           let toolName = string(tool, keys: ["name", "toolName", "tool_name"]) {
            return toolName
        }
        if let assembler = string(json, keys: ["assembler"]) {
            return assembler
        }
        if let operation = string(json, keys: ["operation"]) {
            return operation
        }
        return workflowName
    }

    private static func inferredToolVersion(_ json: [String: Any]) -> String {
        if let toolVersion = string(json, keys: ["toolVersion", "tool_version"]) {
            return toolVersion
        }
        if let tool = dictionary(json["tool"]),
           let toolVersion = string(tool, keys: ["version", "toolVersion", "tool_version"]) {
            return toolVersion
        }
        return string(json, keys: [
            "assembler_version",
            "assemblerVersion",
            "workflowVersion",
            "workflow_version",
            "lungfish_version",
            "lungfishVersion",
        ]) ?? "unknown"
    }

    private static func runtimeIdentity(_ json: [String: Any]) -> ProvenanceRuntimeIdentity {
        let runtime = dictionary(json["runtimeIdentity"])
            ?? dictionary(json["runtime_identity"])
            ?? dictionary(json["runtime"])
            ?? [:]
        return ProvenanceRuntimeIdentity(
            appVersion: string(runtime, keys: ["appVersion", "app_version"])
                ?? string(json, keys: ["lungfish_version", "lungfishVersion", "workflowVersion", "workflow_version"])
                ?? WorkflowRun.currentAppVersion,
            executablePath: string(runtime, keys: ["executablePath", "executable_path", "executable"])
                ?? ProvenanceRuntimeIdentity.currentExecutablePath,
            processIdentifier: int(runtime, keys: ["processIdentifier", "process_identifier", "pid"])
                ?? Int(ProcessInfo.processInfo.processIdentifier),
            operatingSystemVersion: string(runtime, keys: [
                "operatingSystemVersion",
                "operating_system_version",
                "operatingSystem",
                "operating_system",
                "hostOS",
                "host_os",
            ])
                ?? string(json, keys: ["host_os", "hostOS"])
                ?? WorkflowRun.currentHostOS,
            architecture: string(runtime, keys: ["architecture", "arch", "hostArchitecture", "host_architecture"])
                ?? string(json, keys: ["host_architecture", "hostArchitecture"])
                ?? ProvenanceRuntimeIdentity.currentArchitecture,
            user: string(runtime, keys: ["user"]),
            condaEnvironment: string(runtime, keys: ["condaEnvironment", "conda_environment", "managedEnvironment", "managed_environment"])
                ?? string(json, keys: ["managed_environment", "managedEnvironment"]),
            condaPrefix: string(runtime, keys: ["condaPrefix", "conda_prefix"]),
            pluginPack: string(runtime, keys: ["pluginPack", "plugin_pack"]),
            containerImage: string(runtime, keys: ["containerImage", "container_image"])
                ?? string(json, keys: ["container_image", "containerImage"]),
            containerDigest: string(runtime, keys: ["containerDigest", "container_digest"])
                ?? string(json, keys: ["container_image_digest", "containerImageDigest"])
        )
    }

    private static func provenanceOptions(_ json: [String: Any]) -> ProvenanceOptions {
        var explicit: [String: ParameterValue] = [:]
        mergeOptions(from: dictionary(json["options"]), into: &explicit)
        mergeOptions(from: dictionary(json["parameters"]), into: &explicit)
        mergeOptions(from: dictionary(json["resolvedOptions"]), into: &explicit)
        mergeOptions(from: dictionary(json["resolved_options"]), into: &explicit)
        if let value = string(json, keys: ["execution_backend", "executionBackend"]) {
            explicit["executionBackend"] = .string(value)
        }
        if let value = string(json, keys: ["managed_environment", "managedEnvironment"]) {
            explicit["managedEnvironment"] = .string(value)
        }
        return ProvenanceOptions(explicit: explicit)
    }

    private static func mergeOptions(from dictionary: [String: Any]?, into explicit: inout [String: ParameterValue]) {
        guard let dictionary else { return }
        for (key, value) in dictionary {
            explicit[key] = parameterValue(value)
        }
    }

    private static func inputDescriptors(_ json: [String: Any]) -> [ProvenanceFileDescriptor] {
        descriptors(json["input"], role: .input)
            + descriptors(json["inputs"], role: .input)
            + descriptors(json["inputFiles"], role: .input)
            + descriptors(json["input_files"], role: .input)
            + descriptors(json["inputFileInfo"], role: .input)
            + descriptors(json["input_file_info"], role: .input)
            + descriptors(json["inputPaths"], role: .input)
            + descriptors(json["input_paths"], role: .input)
            + descriptors(json["stagedInputPaths"], role: .input)
            + descriptors(json["staged_input_paths"], role: .input)
            + descriptors(json["inputBundle"], role: .input)
            + descriptors(json["input_bundle"], role: .input)
            + descriptors(json["sourceAlignmentBundlePath"], role: .input)
            + descriptors(json["source_alignment_bundle_path"], role: .input)
            + descriptors(json["inputAlignmentFile"], role: .input)
            + descriptors(json["input_alignment_file"], role: .input)
            + descriptors(json["inputTreeFile"], role: .input)
            + descriptors(json["input_tree_file"], role: .input)
    }

    private static func outputDescriptors(_ json: [String: Any]) -> [ProvenanceFileDescriptor] {
        deduplicated(
            descriptors(json["output"], role: .output)
                + descriptors(json["outputs"], role: .output)
                + descriptors(json["outputFile"], role: .output)
                + descriptors(json["output_file"], role: .output)
                + descriptors(json["outputFiles"], role: .output)
                + descriptors(json["output_files"], role: .output)
                + descriptors(json["outputFileInfo"], role: .output)
                + descriptors(json["output_file_info"], role: .output)
                + descriptors(json["outputPaths"], role: .output)
                + descriptors(json["output_paths"], role: .output)
                + descriptors(json["outputBundlePath"], role: .output)
                + descriptors(json["output_bundle_path"], role: .output)
                + descriptors(json["outputBundle"], role: .output)
                + descriptors(json["output_bundle"], role: .output)
                + descriptors(json["metadataFile"], role: .output)
                + descriptors(json["metadata_file"], role: .output)
                + descriptors(json["metadataFiles"], role: .output)
                + descriptors(json["metadata_files"], role: .output)
        )
    }

    private static func fileMapDescriptors(_ json: [String: Any]) -> [ProvenanceFileDescriptor] {
        guard let files = json["files"] else { return [] }
        if let array = files as? [Any] {
            return array.compactMap { fileDescriptor($0, role: .output) }
        }
        guard let map = dictionary(files) else { return [] }
        return map.keys.sorted().compactMap { key in
            fileDescriptor(map[key], role: .output, fallbackPath: key)
        }
    }

    private static func checksumMapDescriptors(_ json: [String: Any]) -> [ProvenanceFileDescriptor] {
        guard let checksums = dictionary(json["checksums"]) else { return [] }
        let sizes = dictionary(json["fileSizes"]) ?? dictionary(json["file_sizes"]) ?? [:]
        return checksums.keys.sorted().map { path in
            ProvenanceFileDescriptor(
                path: path,
                checksumSHA256: stringValue(checksums[path]),
                fileSize: unsignedInt(sizes[path]),
                role: .output
            )
        }
    }

    private static func descriptors(_ value: Any?, role: FileRole) -> [ProvenanceFileDescriptor] {
        guard let value else { return [] }
        if let array = value as? [Any] {
            return array.compactMap { fileDescriptor($0, role: role) }
        }
        if let descriptor = fileDescriptor(value, role: role) {
            return [descriptor]
        }
        return []
    }

    private static func fileDescriptor(
        _ value: Any?,
        role: FileRole,
        fallbackPath: String? = nil
    ) -> ProvenanceFileDescriptor? {
        guard let value else { return nil }
        if let path = stringValue(value) {
            return ProvenanceFileDescriptor(path: path, role: role)
        }
        guard let json = dictionary(value) else { return nil }
        let path = string(json, keys: ["path", "originalPath", "original_path", "filename"]) ?? fallbackPath
        guard let path, !path.isEmpty else { return nil }
        let decodedRole = string(json, keys: ["role"]).flatMap(FileRole.init(rawValue:)) ?? role
        let format = string(json, keys: ["format"]).flatMap(FileFormat.init(rawValue:))
        return ProvenanceFileDescriptor(
            path: path,
            checksumSHA256: string(json, keys: ["checksumSHA256", "sha256", "checksum"]),
            fileSize: unsignedInt(json["fileSize"])
                ?? unsignedInt(json["fileSizeBytes"])
                ?? unsignedInt(json["sizeBytes"])
                ?? unsignedInt(json["size_bytes"])
                ?? unsignedInt(json["size"]),
            format: format,
            role: decodedRole,
            originPath: string(json, keys: ["originPath", "origin_path"]),
            sourceProvenancePath: string(json, keys: ["sourceProvenancePath", "source_provenance_path"])
        )
    }

    private static func primitiveSteps(
        _ json: [String: Any],
        defaultToolName: String,
        defaultToolVersion: String,
        argv: [String],
        reproducibleCommand: String,
        inputs: [ProvenanceFileDescriptor],
        outputs: [ProvenanceFileDescriptor],
        createdAt: Date
    ) -> [ProvenanceStep] {
        let decodedSteps = array(json["steps"]).compactMap {
            step(
                $0,
                fallbackToolName: defaultToolName,
                fallbackToolVersion: defaultToolVersion,
                createdAt: createdAt
            )
        }
        if !decodedSteps.isEmpty {
            return stepsWithFallbackIO(decodedSteps, inputs: inputs, outputs: outputs)
        }

        let externalSteps = array(json["externalToolInvocations"]).compactMap {
            step(
                $0,
                fallbackToolName: "external-tool",
                fallbackToolVersion: defaultToolVersion,
                createdAt: createdAt
            )
        } + descriptorsForExternalTool(json["externalTool"], createdAt: createdAt, defaultToolVersion: defaultToolVersion)
        if !externalSteps.isEmpty {
            return stepsWithFallbackIO(externalSteps, inputs: inputs, outputs: outputs)
        }

        guard !argv.isEmpty || !reproducibleCommand.isEmpty else {
            return []
        }
        return [
            ProvenanceStep(
                toolName: defaultToolName,
                toolVersion: defaultToolVersion,
                argv: argv,
                reproducibleCommand: reproducibleCommand,
                inputs: inputs,
                outputs: outputs,
                exitStatus: int(json, keys: ["exitStatus", "exit_status", "exitCode"]),
                wallTimeSeconds: double(json, keys: ["wallTimeSeconds", "wall_time_seconds", "wallTime"]),
                stderr: string(json, keys: ["stderr"]),
                startedAt: createdAt,
                completedAt: double(json, keys: ["wallTimeSeconds", "wall_time_seconds", "wallTime"])
                    .map { createdAt.addingTimeInterval($0) }
            )
        ]
    }

    private static func stepsWithFallbackIO(
        _ steps: [ProvenanceStep],
        inputs: [ProvenanceFileDescriptor],
        outputs: [ProvenanceFileDescriptor]
    ) -> [ProvenanceStep] {
        guard !steps.isEmpty else { return [] }
        let lastIndex = steps.index(before: steps.endIndex)
        return steps.enumerated().map { index, step in
            let stepInputs = step.inputs.isEmpty && index == steps.startIndex ? inputs : step.inputs
            let stepOutputs = step.outputs.isEmpty && index == lastIndex ? outputs : step.outputs
            guard stepInputs != step.inputs || stepOutputs != step.outputs else {
                return step
            }
            return ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                argv: step.argv,
                reproducibleCommand: step.reproducibleCommand,
                inputs: stepInputs,
                outputs: stepOutputs,
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }
    }

    private static func descriptorsForExternalTool(
        _ value: Any?,
        createdAt: Date,
        defaultToolVersion: String
    ) -> [ProvenanceStep] {
        guard let value,
              let step = step(
                value,
                fallbackToolName: "external-tool",
                fallbackToolVersion: defaultToolVersion,
                createdAt: createdAt
              ) else {
            return []
        }
        return [step]
    }

    private static func step(
        _ value: Any,
        fallbackToolName: String,
        fallbackToolVersion: String,
        createdAt: Date
    ) -> ProvenanceStep? {
        guard let json = dictionary(value) else { return nil }
        let toolName = string(json, keys: ["toolName", "tool_name", "name", "stepName", "workflowName"])
            ?? fallbackToolName
        let toolVersion = string(json, keys: ["toolVersion", "tool_version", "version"])
            ?? fallbackToolVersion
        let argv = stringArray(json, keys: ["argv", "command"])
            ?? commandFromExecutableAndArguments(json)
        let reproducibleCommand = string(json, keys: ["reproducibleCommand", "command", "shellCommand"])
            ?? argv.map(shellEscape).joined(separator: " ")
        let startedAt = date(json, keys: ["startedAt", "startTime", "timestamp"]) ?? createdAt
        let completedAt = date(json, keys: ["completedAt", "endTime"])
            ?? double(json, keys: ["wallTimeSeconds", "wall_time_seconds", "wallTime"])
                .map { startedAt.addingTimeInterval($0) }
        return ProvenanceStep(
            toolName: toolName,
            toolVersion: toolVersion,
            argv: argv,
            reproducibleCommand: reproducibleCommand,
            inputs: descriptors(json["inputs"], role: .input) + descriptors(json["input"], role: .input),
            outputs: descriptors(json["outputs"], role: .output) + descriptors(json["output"], role: .output),
            exitStatus: int(json, keys: ["exitStatus", "exit_status", "exitCode"]),
            wallTimeSeconds: double(json, keys: ["wallTimeSeconds", "wall_time_seconds", "wallTime"]),
            stderr: string(json, keys: ["stderr"]),
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private static func commandFromExecutableAndArguments(_ json: [String: Any]) -> [String] {
        let executable = string(json, keys: ["executable", "executablePath", "executable_path"])
        let arguments = stringArray(json, keys: ["arguments"]) ?? []
        guard let executable else { return [] }
        return [executable] + arguments
    }

    private static func contextualOutputDescriptor(sourceURL: URL?) -> ProvenanceFileDescriptor? {
        guard let sourceURL else { return nil }
        let standardized = sourceURL.standardizedFileURL
        if standardized.lastPathComponent == "provenance.json",
           standardized.deletingLastPathComponent().lastPathComponent == "assembly" {
            return ProvenanceFileDescriptor(
                path: standardized
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .path,
                role: .output
            )
        }
        if standardized.lastPathComponent == ProvenanceRecorder.provenanceFilename {
            let parent = standardized.deletingLastPathComponent()
            if ProvenanceWriter.isBundleDirectory(parent) {
                return ProvenanceFileDescriptor(path: parent.path, role: .output)
            }
        }
        if standardized.lastPathComponent == "extraction-metadata.json" {
            let parent = standardized.deletingLastPathComponent()
            if ProvenanceWriter.isBundleDirectory(parent) {
                return ProvenanceFileDescriptor(path: parent.path, role: .output)
            }
        }
        return nil
    }

    private static func parameterValue(_ value: Any) -> ParameterValue {
        if value is NSNull {
            return .null
        }
        if let bool = value as? Bool {
            return .boolean(bool)
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            let doubleValue = number.doubleValue
            if doubleValue.rounded() == doubleValue {
                return .integer(number.intValue)
            }
            return .number(doubleValue)
        }
        if let string = value as? String {
            return .string(string)
        }
        if let array = value as? [Any] {
            return .array(array.map(parameterValue))
        }
        if let dictionary = value as? [String: Any] {
            return .dictionary(dictionary.mapValues(parameterValue))
        }
        return .string(String(describing: value))
    }

    private static func deduplicated(_ descriptors: [ProvenanceFileDescriptor]) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors {
            let key = "\(descriptor.role.rawValue)\u{0}\(descriptor.path)"
            if seen.insert(key).inserted {
                result.append(descriptor)
            }
        }
        return result
    }

    private static func machineToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let token = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar).lowercased() : "-"
        }.joined()
        return token
            .split(separator: "-")
            .joined(separator: "-")
    }

    private static func looksLikeTreeProvenance(_ json: [String: Any]) -> Bool {
        if json["inputTreeFile"] != nil || json["input_tree_file"] != nil {
            return true
        }
        if let outputPath = descriptors(json["output"], role: .output).first?.path,
           outputPath.hasSuffix(".lungfishtree") {
            return true
        }
        if let checksums = dictionary(json["checksums"]),
           checksums.keys.contains(where: { $0.hasPrefix("tree/") || $0.hasSuffix(".nwk") }) {
            return true
        }
        return false
    }

    private static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func stringArray(_ json: [String: Any], keys: [String]) -> [String]? {
        for key in keys {
            if let array = json[key] as? [String] {
                return array
            }
        }
        return nil
    }

    private static func string(_ json: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(json[key]), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func int(_ json: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = intValue(json[key]) {
                return value
            }
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func double(_ json: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = doubleValue(json[key]) {
                return value
            }
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private static func unsignedInt(_ value: Any?) -> UInt64? {
        switch value {
        case let value as UInt64:
            return value
        case let value as Int where value >= 0:
            return UInt64(value)
        case let value as NSNumber where value.int64Value >= 0:
            return UInt64(value.int64Value)
        case let value as String:
            return UInt64(value)
        default:
            return nil
        }
    }

    private static func date(_ json: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            guard let value = stringValue(json[key]) else { continue }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let parsed = fractional.date(from: value)
                ?? plain.date(from: value) {
                return parsed
            }
        }
        return nil
    }
}
