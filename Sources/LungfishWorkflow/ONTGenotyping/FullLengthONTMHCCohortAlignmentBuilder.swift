import Foundation

public struct FullLengthONTMHCSampleAlignmentInput: Sendable, Equatable {
    public let sampleID: String
    public let originalClustersFASTAURL: URL
    public let clusterRecords: [FullLengthONTMHCClusterFASTARecord]

    public init(
        sampleID: String,
        originalClustersFASTAURL: URL,
        clusterRecords: [FullLengthONTMHCClusterFASTARecord]
    ) {
        self.sampleID = sampleID
        self.originalClustersFASTAURL = originalClustersFASTAURL.standardizedFileURL
        self.clusterRecords = clusterRecords
    }
}

public struct FullLengthONTMHCCohortAlignmentBuildRequest: Sendable, Equatable {
    public let samples: [FullLengthONTMHCSampleAlignmentInput]
    public let referenceAlleleFASTAURL: URL
    public let threads: Int
    public let outputDirectoryURL: URL
    public let workDirectoryURL: URL
    public let keepIntermediates: Bool

    public init(
        samples: [FullLengthONTMHCSampleAlignmentInput],
        referenceAlleleFASTAURL: URL,
        threads: Int,
        outputDirectoryURL: URL,
        workDirectoryURL: URL,
        keepIntermediates: Bool
    ) {
        self.samples = samples
        self.referenceAlleleFASTAURL = referenceAlleleFASTAURL.standardizedFileURL
        self.threads = max(1, threads)
        self.outputDirectoryURL = outputDirectoryURL.standardizedFileURL
        self.workDirectoryURL = workDirectoryURL.standardizedFileURL
        self.keepIntermediates = keepIntermediates
    }
}

public struct FullLengthONTMHCTargetNamespaceMapping: Sendable, Equatable, Codable {
    public let originalClusterID: String
    public let namespacedTargetID: String

    public init(originalClusterID: String, namespacedTargetID: String) {
        self.originalClusterID = originalClusterID
        self.namespacedTargetID = namespacedTargetID
    }
}

public struct FullLengthONTMHCSampleAlignmentMapping: Sendable, Equatable {
    public let sampleID: String
    public let readGroupID: String
    public let readGroupSample: String
    public let originalClustersFASTAURL: URL
    public let namespacedClustersFASTAURL: URL
    public let samURL: URL
    public let unsortedBAMURL: URL
    public let readGroupBAMURL: URL
    public let sortedBAMURL: URL
    public let targets: [FullLengthONTMHCTargetNamespaceMapping]
}

public struct FullLengthONTMHCCohortAlignmentCommandRecord: Sendable, Equatable {
    public let executableURL: URL
    public let toolVersion: String?
    public let argv: [String]
    public let arguments: [String]
    public let inputs: [URL]
    public let outputs: [URL]
    public let exitStatus: Int32
    public let stdout: String
    public let stderr: String
    public let startedAt: Date
    public let completedAt: Date
    public let wallTime: TimeInterval
}

public struct FullLengthONTMHCCohortAlignmentResult: Sendable, Equatable {
    public let bamURL: URL
    public let baiURL: URL
    public let sampleMappings: [FullLengthONTMHCSampleAlignmentMapping]
    public let commandRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]
    public let temporaryWorkDirectoryURL: URL
    public let mergedBAMURL: URL
}

public struct FullLengthONTMHCCohortAlignmentBuildError: Error, LocalizedError, Sendable {
    public let message: String
    public let retainedWorkDirectoryURL: URL
    public let commandRecords: [FullLengthONTMHCCohortAlignmentCommandRecord]

    public var errorDescription: String? { message }
}

public struct FullLengthONTMHCCohortAlignmentBuilder: @unchecked Sendable {
    private let executableDirectoryURL: URL?
    private let fileManager: FileManager

    public init(
        executableDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.executableDirectoryURL = executableDirectoryURL?.standardizedFileURL
        self.fileManager = fileManager
    }

    public func build(
        _ request: FullLengthONTMHCCohortAlignmentBuildRequest
    ) async throws -> FullLengthONTMHCCohortAlignmentResult {
        let temporaryWorkDirectoryURL = request.workDirectoryURL.appendingPathComponent(
            "full-length-ont-mhc-cohort-alignment-\(UUID().uuidString)",
            isDirectory: true
        )
        var commandRecords: [FullLengthONTMHCCohortAlignmentCommandRecord] = []

        do {
            try fileManager.createDirectory(
                at: temporaryWorkDirectoryURL,
                withIntermediateDirectories: true
            )
            let minimap2URL = try executableURL(named: "minimap2")
            let samtoolsURL = try executableURL(named: "samtools")
            let samples = try validatedSamples(request.samples)
            try requireRegularFile(request.referenceAlleleFASTAURL, role: "reference allele FASTA")

            var mappings: [FullLengthONTMHCSampleAlignmentMapping] = []
            var namespacedTargets = Set<String>()
            for (index, sample) in samples.enumerated() {
                try requireRegularFile(sample.originalClustersFASTAURL, role: "cluster FASTA for \(sample.sampleID)")
                guard !sample.clusterRecords.isEmpty else {
                    throw BuildFailure("Sample '\(sample.sampleID)' has no cluster records.")
                }
                let sampleDirectory = temporaryWorkDirectoryURL.appendingPathComponent(
                    String(format: "%04d-%@", index + 1, sample.sampleID),
                    isDirectory: true
                )
                try fileManager.createDirectory(at: sampleDirectory, withIntermediateDirectories: true)
                let namespacedFASTAURL = sampleDirectory.appendingPathComponent("\(sample.sampleID).namespaced-clusters.fa")
                let samURL = sampleDirectory.appendingPathComponent("\(sample.sampleID).sam")
                let unsortedBAMURL = sampleDirectory.appendingPathComponent("\(sample.sampleID).unsorted.bam")
                let readGroupBAMURL = sampleDirectory.appendingPathComponent("\(sample.sampleID).rg.bam")
                let sortedBAMURL = sampleDirectory.appendingPathComponent("\(sample.sampleID).sorted.bam")
                let targets = try writeNamespacedFASTA(
                    sample: sample,
                    to: namespacedFASTAURL,
                    namespacedTargets: &namespacedTargets
                )
                mappings.append(FullLengthONTMHCSampleAlignmentMapping(
                    sampleID: sample.sampleID,
                    readGroupID: sample.sampleID,
                    readGroupSample: sample.sampleID,
                    originalClustersFASTAURL: sample.originalClustersFASTAURL,
                    namespacedClustersFASTAURL: namespacedFASTAURL,
                    samURL: samURL,
                    unsortedBAMURL: unsortedBAMURL,
                    readGroupBAMURL: readGroupBAMURL,
                    sortedBAMURL: sortedBAMURL,
                    targets: targets
                ))
            }

            for mapping in mappings {
                try run(
                    executableURL: minimap2URL,
                    arguments: [
                        "-a", "-x", "splice", "--eqx",
                        "-t", String(request.threads),
                        "-N", "100", "--secondary=yes",
                        mapping.namespacedClustersFASTAURL.path,
                        request.referenceAlleleFASTAURL.path,
                    ],
                    inputs: [mapping.namespacedClustersFASTAURL, request.referenceAlleleFASTAURL],
                    outputs: [mapping.samURL],
                    stdoutURL: mapping.samURL,
                    workingDirectoryURL: temporaryWorkDirectoryURL,
                    commandRecords: &commandRecords
                )
                try run(
                    executableURL: samtoolsURL,
                    arguments: ["view", "-b", "-o", mapping.unsortedBAMURL.path, mapping.samURL.path],
                    inputs: [mapping.samURL],
                    outputs: [mapping.unsortedBAMURL],
                    workingDirectoryURL: temporaryWorkDirectoryURL,
                    commandRecords: &commandRecords
                )
                try run(
                    executableURL: samtoolsURL,
                    arguments: [
                        "addreplacerg",
                        "-r", "ID:\(mapping.sampleID)",
                        "-r", "SM:\(mapping.sampleID)",
                        "-o", mapping.readGroupBAMURL.path,
                        mapping.unsortedBAMURL.path,
                    ],
                    inputs: [mapping.unsortedBAMURL],
                    outputs: [mapping.readGroupBAMURL],
                    workingDirectoryURL: temporaryWorkDirectoryURL,
                    commandRecords: &commandRecords
                )
                try run(
                    executableURL: samtoolsURL,
                    arguments: ["sort", "-o", mapping.sortedBAMURL.path, mapping.readGroupBAMURL.path],
                    inputs: [mapping.readGroupBAMURL],
                    outputs: [mapping.sortedBAMURL],
                    workingDirectoryURL: temporaryWorkDirectoryURL,
                    commandRecords: &commandRecords
                )
            }

            let mergedBAMURL = temporaryWorkDirectoryURL.appendingPathComponent("cohort.merged.bam")
            try run(
                executableURL: samtoolsURL,
                arguments: ["merge", "-f", "-o", mergedBAMURL.path] + mappings.map { $0.sortedBAMURL.path },
                inputs: mappings.map(\.sortedBAMURL),
                outputs: [mergedBAMURL],
                workingDirectoryURL: temporaryWorkDirectoryURL,
                commandRecords: &commandRecords
            )

            let alignmentDirectoryURL = request.outputDirectoryURL.appendingPathComponent(
                "artifacts/alignments",
                isDirectory: true
            )
            try fileManager.createDirectory(at: alignmentDirectoryURL, withIntermediateDirectories: true)
            let stagingDirectoryURL = alignmentDirectoryURL.appendingPathComponent(
                ".genotyping-evidence-staging-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: stagingDirectoryURL, withIntermediateDirectories: false)
            let stagedBAMURL = stagingDirectoryURL.appendingPathComponent("genotyping-evidence.bam")
            let stagedBAIURL = stagingDirectoryURL.appendingPathComponent("genotyping-evidence.bam.bai")

            try run(
                executableURL: samtoolsURL,
                arguments: ["sort", "-o", stagedBAMURL.path, mergedBAMURL.path],
                inputs: [mergedBAMURL],
                outputs: [stagedBAMURL],
                workingDirectoryURL: temporaryWorkDirectoryURL,
                commandRecords: &commandRecords
            )
            try run(
                executableURL: samtoolsURL,
                arguments: ["index", stagedBAMURL.path, stagedBAIURL.path],
                inputs: [stagedBAMURL],
                outputs: [stagedBAIURL],
                workingDirectoryURL: temporaryWorkDirectoryURL,
                commandRecords: &commandRecords
            )
            try run(
                executableURL: samtoolsURL,
                arguments: ["quickcheck", stagedBAMURL.path],
                inputs: [stagedBAMURL, stagedBAIURL],
                outputs: [],
                workingDirectoryURL: temporaryWorkDirectoryURL,
                commandRecords: &commandRecords
            )
            try run(
                executableURL: samtoolsURL,
                arguments: ["idxstats", stagedBAMURL.path],
                inputs: [stagedBAMURL, stagedBAIURL],
                outputs: [],
                workingDirectoryURL: temporaryWorkDirectoryURL,
                commandRecords: &commandRecords
            )

            let finalBAMURL = alignmentDirectoryURL.appendingPathComponent("genotyping-evidence.bam")
            let finalBAIURL = alignmentDirectoryURL.appendingPathComponent("genotyping-evidence.bam.bai")
            try publishPair(
                stagedBAMURL: stagedBAMURL,
                stagedBAIURL: stagedBAIURL,
                finalBAMURL: finalBAMURL,
                finalBAIURL: finalBAIURL,
                transactionDirectoryURL: stagingDirectoryURL
            )
            try? fileManager.removeItem(at: stagingDirectoryURL)
            if !request.keepIntermediates {
                try? fileManager.removeItem(at: temporaryWorkDirectoryURL)
            }

            return FullLengthONTMHCCohortAlignmentResult(
                bamURL: finalBAMURL,
                baiURL: finalBAIURL,
                sampleMappings: mappings,
                commandRecords: commandRecords,
                temporaryWorkDirectoryURL: temporaryWorkDirectoryURL,
                mergedBAMURL: mergedBAMURL
            )
        } catch {
            if let error = error as? FullLengthONTMHCCohortAlignmentBuildError {
                throw error
            }
            throw FullLengthONTMHCCohortAlignmentBuildError(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                retainedWorkDirectoryURL: temporaryWorkDirectoryURL,
                commandRecords: commandRecords
            )
        }
    }

    private func validatedSamples(
        _ samples: [FullLengthONTMHCSampleAlignmentInput]
    ) throws -> [FullLengthONTMHCSampleAlignmentInput] {
        guard !samples.isEmpty else { throw BuildFailure("At least one sample alignment is required.") }
        var sampleIDs = Set<String>()
        for sample in samples {
            guard Self.isSafeSampleID(sample.sampleID) else {
                throw BuildFailure("Unsafe stable sample ID '\(sample.sampleID)'.")
            }
            guard sampleIDs.insert(sample.sampleID).inserted else {
                throw BuildFailure("Duplicate stable sample ID '\(sample.sampleID)'.")
            }
        }
        return samples.sorted { $0.sampleID < $1.sampleID }
    }

    private static func isSafeSampleID(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private func writeNamespacedFASTA(
        sample: FullLengthONTMHCSampleAlignmentInput,
        to url: URL,
        namespacedTargets: inout Set<String>
    ) throws -> [FullLengthONTMHCTargetNamespaceMapping] {
        var text = ""
        var mappings: [FullLengthONTMHCTargetNamespaceMapping] = []
        for record in sample.clusterRecords {
            guard !record.name.isEmpty,
                  !record.name.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
                  !record.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw BuildFailure("Cluster ID '\(record.name)' is not a safe SAM target identifier.")
            }
            let targetID = "\(sample.sampleID)|\(record.name)"
            guard namespacedTargets.insert(targetID).inserted else {
                throw BuildFailure("Namespaced target collision for '\(targetID)'.")
            }
            mappings.append(.init(originalClusterID: record.name, namespacedTargetID: targetID))
            text += ">\(targetID)\n"
            var sequence = record.sequence
            while !sequence.isEmpty {
                let chunk = String(sequence.prefix(80))
                text += chunk + "\n"
                sequence.removeFirst(chunk.count)
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return mappings
    }

    private func executableURL(named name: String) throws -> URL {
        if let executableDirectoryURL {
            let candidate = executableDirectoryURL.appendingPathComponent(name)
            guard fileManager.isExecutableFile(atPath: candidate.path) else {
                throw BuildFailure("Executable '\(name)' is missing from \(executableDirectoryURL.path).")
            }
            return candidate
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw BuildFailure("Executable '\(name)' was not found on PATH.")
    }

    private func requireRegularFile(_ url: URL, role: String) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BuildFailure("Missing \(role): \(url.path)")
        }
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        inputs: [URL],
        outputs: [URL],
        stdoutURL: URL? = nil,
        workingDirectoryURL: URL,
        commandRecords: inout [FullLengthONTMHCCohortAlignmentCommandRecord]
    ) throws {
        let record = try execute(
            executableURL: executableURL,
            arguments: arguments,
            inputs: inputs,
            outputs: outputs,
            stdoutURL: stdoutURL,
            workingDirectoryURL: workingDirectoryURL
        )
        commandRecords.append(record)
        guard record.exitStatus == 0 else {
            throw BuildFailure(
                "\(executableURL.lastPathComponent) failed with exit status \(record.exitStatus): \(record.stderr)"
            )
        }
        for output in outputs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: output.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw BuildFailure(
                    "\(executableURL.lastPathComponent) exited successfully without creating \(output.path)."
                )
            }
        }
    }

    private func execute(
        executableURL: URL,
        arguments: [String],
        inputs: [URL],
        outputs: [URL],
        stdoutURL: URL?,
        workingDirectoryURL: URL
    ) throws -> FullLengthONTMHCCohortAlignmentCommandRecord {
        let startedAt = Date()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectoryURL
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe: Pipe?
        let stdoutHandle: FileHandle?
        if let stdoutURL {
            fileManager.createFile(atPath: stdoutURL.path, contents: nil)
            guard let handle = FileHandle(forWritingAtPath: stdoutURL.path) else {
                throw BuildFailure("Could not open stdout destination \(stdoutURL.path).")
            }
            stdoutHandle = handle
            stdoutPipe = nil
            process.standardOutput = handle
        } else {
            let pipe = Pipe()
            stdoutPipe = pipe
            stdoutHandle = nil
            process.standardOutput = pipe
        }
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        let stdoutData = ProcessDataBox()
        let stderrData = ProcessDataBox()
        let group = DispatchGroup()
        if let stdoutPipe {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                stdoutData.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
        } catch {
            try? stdoutHandle?.close()
            try? stdoutPipe?.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            group.wait()
            let completedAt = Date()
            return FullLengthONTMHCCohortAlignmentCommandRecord(
                executableURL: executableURL,
                toolVersion: nil,
                argv: [executableURL.path] + arguments,
                arguments: arguments,
                inputs: inputs,
                outputs: outputs,
                exitStatus: -1,
                stdout: "",
                stderr: error.localizedDescription,
                startedAt: startedAt,
                completedAt: completedAt,
                wallTime: completedAt.timeIntervalSince(startedAt)
            )
        }
        process.waitUntilExit()
        try? stdoutHandle?.close()
        group.wait()
        let completedAt = Date()
        return FullLengthONTMHCCohortAlignmentCommandRecord(
            executableURL: executableURL,
            toolVersion: nil,
            argv: [executableURL.path] + arguments,
            arguments: arguments,
            inputs: inputs,
            outputs: outputs,
            exitStatus: process.terminationStatus,
            stdout: String(data: stdoutData.data, encoding: .utf8) ?? "",
            stderr: String(data: stderrData.data, encoding: .utf8) ?? "",
            startedAt: startedAt,
            completedAt: completedAt,
            wallTime: completedAt.timeIntervalSince(startedAt)
        )
    }

    private func publishPair(
        stagedBAMURL: URL,
        stagedBAIURL: URL,
        finalBAMURL: URL,
        finalBAIURL: URL,
        transactionDirectoryURL: URL
    ) throws {
        let backupBAMURL = transactionDirectoryURL.appendingPathComponent("previous-genotyping-evidence.bam")
        let backupBAIURL = transactionDirectoryURL.appendingPathComponent("previous-genotyping-evidence.bam.bai")
        var backedUpBAM = false
        var backedUpBAI = false
        var installedBAM = false
        do {
            if fileManager.fileExists(atPath: finalBAMURL.path) {
                try fileManager.moveItem(at: finalBAMURL, to: backupBAMURL)
                backedUpBAM = true
            }
            if fileManager.fileExists(atPath: finalBAIURL.path) {
                try fileManager.moveItem(at: finalBAIURL, to: backupBAIURL)
                backedUpBAI = true
            }
            try fileManager.moveItem(at: stagedBAMURL, to: finalBAMURL)
            installedBAM = true
            try fileManager.moveItem(at: stagedBAIURL, to: finalBAIURL)
        } catch {
            if installedBAM { try? fileManager.removeItem(at: finalBAMURL) }
            var rollbackMessages: [String] = []
            if backedUpBAM {
                do { try fileManager.moveItem(at: backupBAMURL, to: finalBAMURL) }
                catch { rollbackMessages.append("BAM rollback failed: \(error.localizedDescription)") }
            }
            if backedUpBAI {
                do { try fileManager.moveItem(at: backupBAIURL, to: finalBAIURL) }
                catch { rollbackMessages.append("BAI rollback failed: \(error.localizedDescription)") }
            }
            let suffix = rollbackMessages.isEmpty ? "" : " " + rollbackMessages.joined(separator: " ")
            throw BuildFailure("Could not publish cohort BAM/index pair: \(error.localizedDescription).\(suffix)")
        }
    }
}

private struct BuildFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class ProcessDataBox: @unchecked Sendable {
    var data = Data()
}
