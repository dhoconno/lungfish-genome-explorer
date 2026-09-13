import Foundation

extension GenotypeExcelExportService {
    /// Rebinds a report's durable replay to its stored location. The surrounding
    /// bundle publication/copy transaction owns these edits. Captured scientific
    /// bytes and historical execution argv are never rewritten.
    public static func relocateReports(in storedRoot: URL, from sourceRoot: URL, to finalRoot: URL) throws {
        let fm = FileManager.default
        // Resolve aliases of the caller-owned parent (e.g. /tmp -> /private/tmp),
        // not symlinks introduced inside the copied bundle.
        let storedURL = storedRoot.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(storedRoot.lastPathComponent).standardizedFileURL
        let rootValues = try storedURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw ExportError.invalidInput("unsafe relocated report root")
        }
        guard let entries = fm.enumerator(at: storedURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        let source = sourceRoot.standardizedFileURL.path
        let final = finalRoot.standardizedFileURL.path
        let stored = storedURL.path
        let sourceAliases = Set([source, sourceRoot.resolvingSymlinksInPath().path])
        func mapped(_ value: String) -> String {
            let path = URL(fileURLWithPath: value).standardizedFileURL.path
            guard let prefix = sourceAliases.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return value }
            return final + path.dropFirst(prefix.count)
        }
        func physical(_ value: String) throws -> URL {
            let path = mapped(value)
            guard path.hasPrefix(final + "/") else { throw ExportError.invalidInput("report artifact outside relocated bundle: \(value)") }
            let url = URL(fileURLWithPath: stored + path.dropFirst(final.count)).standardizedFileURL
            guard url.path.hasPrefix(stored + "/"), url.resolvingSymlinksInPath().path == url.path else {
                throw ExportError.invalidInput("unsafe relocated report artifact: \(value)")
            }
            return url
        }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func descriptor(_ path: String) throws -> [String: Any] {
            let data = try Data(contentsOf: physical(path))
            return ["path": mapped(path), "sha256": GenotypeExcelSnapshotBuilder.digest(data), "sizeBytes": data.count]
        }
        for case let receiptURL as URL in entries {
            guard receiptURL.lastPathComponent.hasSuffix(".xlsx.provenance.json") else { continue }
            let values = try receiptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ExportError.invalidInput("unsafe report receipt")
            }
            guard var receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any],
                  receipt["toolName"] as? String == "lungfish genotype Excel export",
                  receipt["schemaVersion"] as? Int == 1 else { continue }
            // Validate all published descriptors before changing any bytes.
            for key in ["output", "snapshot", "script", "replayScript", "request"] {
                guard let prior = receipt[key] as? [String: Any] else {
                    throw ExportError.invalidInput("missing report \(key) descriptor")
                }
                guard let path = prior["path"] as? String else { throw ExportError.invalidInput("missing report path") }
                let current = try descriptor(path)
                guard current["sha256"] as? String == prior["sha256"] as? String,
                      current["sizeBytes"] as? Int == prior["sizeBytes"] as? Int else {
                    throw ExportError.invalidInput("changed report artifact: \(path)")
                }
            }
            guard let oldReplay = receipt["durableReplayArgv"] as? [String],
                  let requestFlag = oldReplay.firstIndex(of: "--provenance-request"), requestFlag + 1 < oldReplay.count,
                  let output = receipt["output"] as? [String: Any], let outputPath = output["path"] as? String,
                  let replay = receipt["replayScript"] as? [String: Any], let replayPath = replay["path"] as? String else {
                throw ExportError.invalidInput("missing report replay contract")
            }
            func checkedReplayPath(_ flag: String, matches descriptorKey: String) throws -> String {
                guard oldReplay.filter({ $0 == flag }).count == 1,
                      let index = oldReplay.firstIndex(of: flag), index + 1 < oldReplay.count,
                      let published = receipt[descriptorKey] as? [String: Any],
                      let publishedPath = published["path"] as? String,
                      try physical(oldReplay[index + 1]) == physical(publishedPath) else {
                    throw ExportError.invalidInput("replay \(flag) disagrees with its published descriptor")
                }
                return oldReplay[index + 1]
            }
            let requestPath = try checkedReplayPath("--provenance-request", matches: "request")
            _ = try checkedReplayPath("--snapshot", matches: "snapshot")
            _ = try checkedReplayPath("--output", matches: "output")
            guard let receiptPath = receipt["receiptPath"] as? String,
                  try physical(receiptPath) == receiptURL.standardizedFileURL else {
                throw ExportError.invalidInput("receipt identity disagrees with stored report")
            }
            for witness in receipt["inputs"] as? [[String: Any]] ?? [] {
                guard let captured = witness["capturedPath"] as? String else {
                    throw ExportError.invalidInput("missing captured input path")
                }
                let current = try descriptor(captured)
                guard current["sha256"] as? String == witness["sha256"] as? String,
                      current["sizeBytes"] as? Int == witness["sizeBytes"] as? Int else {
                    throw ExportError.invalidInput("changed captured input")
                }
            }
            let original = try JSONDecoder().decode(ProvenanceRequest.self, from: Data(contentsOf: physical(requestPath)))
            let request = ProvenanceRequest(workflowName: original.workflowName, toolVersion: original.toolVersion,
                argv: original.argv, options: original.options.mapValues(mapped), defaults: original.defaults.mapValues(mapped),
                runtimeContext: original.runtimeContext, inputs: original.inputs.map {
                    .init(path: mapped($0.path), data: $0.data, verifyCurrentFile: $0.verifyCurrentFile)
                })
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(request).write(to: physical(requestPath), options: .atomic)
            let replayArgv = oldReplay.map(mapped)
            guard let outputFlag = replayArgv.firstIndex(of: "--output"), outputFlag + 1 < replayArgv.count else {
                throw ExportError.invalidInput("missing replay output")
            }
            let replayScript = "#!/bin/sh\nreplay_default_output=" + quote(mapped(outputPath))
                + "\nexec " + replayArgv.prefix(outputFlag).map(quote).joined(separator: " ")
                + " --output \"${1:-$replay_default_output}\""
                + (replayArgv.dropFirst(outputFlag + 2).isEmpty ? "" : " " + replayArgv.dropFirst(outputFlag + 2).map(quote).joined(separator: " ")) + "\n"
            try Data(replayScript.utf8).write(to: physical(replayPath), options: .atomic)
            for key in ["output", "snapshot", "script", "replayScript"] {
                let prior = receipt[key] as! [String: Any]
                receipt[key] = try descriptor(prior["path"] as! String)
            }
            receipt["request"] = try descriptor(requestPath)
            receipt["options"] = (receipt["options"] as? [String: String])?.mapValues(mapped)
            receipt["resolvedDefaults"] = (receipt["resolvedDefaults"] as? [String: String])?.mapValues(mapped)
            receipt["durableReplayArgv"] = replayArgv
            receipt["replayCommand"] = replayArgv.map(quote).joined(separator: " ")
            receipt["receiptPath"] = mapped((receipt["receiptPath"] as? String) ?? receiptURL.path)
            receipt["inputs"] = (receipt["inputs"] as? [[String: Any]] ?? []).map { prior in
                var value = prior
                if let path = prior["path"] as? String { value["originPath"] = prior["originPath"] ?? path; value["path"] = mapped(path) }
                if let path = prior["capturedPath"] as? String { value["capturedPath"] = mapped(path) }
                return value
            }
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: receiptURL, options: .atomic)
        }
    }
}
