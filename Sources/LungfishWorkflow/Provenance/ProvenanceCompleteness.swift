// ProvenanceCompleteness.swift - The one rule for whether a provenance record is complete
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The one rule for whether a provenance record is complete.
///
/// The Inspector's coverage audit reads a record as Complete or Incomplete with it, and a
/// writer's test can ask it about the record that writer just made, so both ask the same
/// question. The rule only reports. Nothing refuses a write because of what it finds.
public enum ProvenanceCompleteness {
    /// The gaps in `envelope`, one sentence each, in a fixed order and without repeats.
    ///
    /// The list is empty for a complete record. The Inspector shows these sentences as warnings,
    /// so their wording and their order are part of what a scientist reads.
    public static func issues(in envelope: ProvenanceEnvelope) -> [String] {
        var found: [String] = []

        if envelope.workflowName.isBlankOrUnknown {
            found.append("Workflow name is missing.")
        }
        if envelope.workflowVersion.isBlankOrUnknown {
            found.append("Workflow version is missing.")
        }
        if envelope.toolName.isBlankOrUnknown {
            found.append("Tool name is missing.")
        }
        if envelope.toolVersion.isBlankOrUnknown {
            found.append("Tool version is missing.")
        }
        if envelope.argv.isEmpty && envelope.reproducibleCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append("Exact argv or reproducible command is missing.")
        }
        if envelope.files.isEmpty {
            found.append("Input/reference/output file descriptors are missing.")
        }
        if envelope.output == nil && envelope.outputs.isEmpty && !envelope.files.contains(where: { $0.role == .output }) {
            found.append("Output descriptors are missing.")
        }
        if envelope.steps.isEmpty {
            found.append("Workflow step list is missing.")
        }
        if envelope.exitStatus == nil {
            found.append("Exit status is missing.")
        }
        if envelope.wallTimeSeconds == nil {
            found.append("Wall time is missing.")
        }
        if let exitStatus = envelope.exitStatus,
           exitStatus != 0,
           envelope.stderr == nil {
            found.append("stderr is missing for the failed workflow.")
        }
        if envelope.steps.contains(where: { ($0.exitStatus ?? 0) != 0 && $0.stderr == nil }) {
            found.append("stderr is missing for one or more failed workflow steps.")
        }

        let descriptorIssues = missingFileMetadataDescriptors(in: envelope)
        if !descriptorIssues.isEmpty {
            found.append(missingFileMetadataMessage(for: descriptorIssues))
        }

        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    private static func allFileDescriptors(in envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        envelope.files
            + (envelope.output.map { [$0] } ?? [])
            + envelope.outputs
            + envelope.steps.flatMap { $0.inputs + $0.outputs }
    }

    private static func descriptorLooksLikeDirectory(_ descriptor: ProvenanceFileDescriptor) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: descriptor.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func missingFileMetadataDescriptors(in envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        let failedOutputPaths = Set(
            envelope.steps
                .filter { ($0.exitStatus ?? 0) != 0 }
                .flatMap { $0.outputs.map(\.path) }
        )
        var seen = Set<String>()
        return allFileDescriptors(in: envelope).filter { descriptor in
            let path = descriptor.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, !descriptorLooksLikeDirectory(descriptor) else { return false }
            // A stream between two piped steps (`pipe:stdout:bcftools-mpileup`)
            // is not a file, so it has no checksum or size to record.
            guard !path.hasPrefix("pipe:") else { return false }
            guard descriptor.checksumSHA256 == nil || descriptor.fileSize == nil else { return false }
            if failedOutputPaths.contains(descriptor.path),
               !FileManager.default.fileExists(atPath: descriptor.path) {
                return false
            }
            return seen.insert(descriptor.path).inserted
        }
    }

    private static func missingFileMetadataMessage(for descriptors: [ProvenanceFileDescriptor]) -> String {
        let count = descriptors.count
        let examples = descriptors.prefix(4).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        let remaining = count - examples.count
        let suffix = remaining > 0 ? " and \(remaining) more" : ""
        let noun = count == 1 ? "file descriptor" : "file descriptors"
        return "Missing checksum or size for \(count) \(noun): \(examples.joined(separator: ", "))\(suffix)."
    }
}

private extension String {
    var isBlankOrUnknown: Bool {
        let normalized = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty || normalized == "unknown"
    }
}
