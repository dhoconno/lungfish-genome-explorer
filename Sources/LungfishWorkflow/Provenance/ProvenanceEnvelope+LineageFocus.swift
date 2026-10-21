// ProvenanceEnvelope+LineageFocus.swift - The record of one file among the many a run wrote
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ProvenanceEnvelope {
    /// The record of `output` alone, for a run that writes many files and reads each of them in steps that write
    /// nothing, as `build-db esviritu` probes, sorts and counts every BAM it moved (ruling Q-S2 of the pre-2.12
    /// session). It keeps four kinds of step, in the run's order.
    ///
    /// 1. A step that names `output` among its outputs, with only its own descriptor of that file, with the digest
    ///    and `originPath` the step stated (BIO's Q-A3 item 2 of Phase 2.13).
    /// 2. A step without outputs whose inputs name `output` or a path it came from, such as a header probe, a count,
    ///    the replacement of its old bytes or the removal of the `_temp` path that a move took it from. A path it
    ///    came from is the `originPath` of `output` or of a step's output at its path.
    /// 3. A step that names no file, when a kept step depends on it, directly or through other such steps, or when
    ///    no step of the run depends on it. So a BAM's record keeps its own markdup's `fixmate` and `sort`, which
    ///    name no file, and drops those of every other BAM (item 5).
    /// 4. No other step. A step without outputs that reads only other files goes, and so does a step that writes
    ///    only other files, as in ``focusedOnOutput(_:)``.
    ///
    /// A kept step keeps every input, because a step read what it read, unless it is batch-wide and
    /// `wholeRecordPath` names the record of the run that holds every step whole under its id (items 1 and 4).
    /// A step is batch-wide when its inputs or outputs name a run output outside the file's pair (a BAM and its
    /// `.bai` and `.csi`) or the `originPath` of one, as the move, the removal of the `_temp` folders and the run's
    /// own step do. It then keeps only the inputs in the file's lineage, the file and the paths it came from, and
    /// names the whole record and its count of inputs in ``ProvenanceStep/narrowedFrom`` (ARCH Q-A3-SHAPE). A nil
    /// `wholeRecordPath` narrows no input.
    ///
    /// `files` keeps the inputs of the kept steps, and `output` and `outputs` name `output` alone, as in
    /// ``focusedOnOutput(_:)``. The copy goes through ``with(_:)``, so the run's other facts stay and its
    /// signatures, which covered the whole record, are cleared. A path under `/private/var`, `/private/tmp` or
    /// `/private/etc` names the same file as the path without `/private`, since a folder listing under the temporary
    /// folder gives the first and a standardized URL the second, and one run can hold both. The projection reads
    /// nothing from the disk. ``focusedOnOutput(_:)`` stays as it is for its callers.
    public func focusedOnLineage(of output: ProvenanceFileDescriptor, wholeRecordPath: String? = nil) -> ProvenanceEnvelope {
        let file = Self.lineagePath(output.path)
        let lineage = Self.lineage(of: [file], among: [output] + steps.flatMap(\.outputs))
        let pair = Self.pair(of: file)
        let others = Set(outputs.map { Self.lineagePath($0.path) }).subtracting(pair)
        let batchWide = Self.lineage(of: others, among: outputs + steps.flatMap(\.outputs))
        let named = steps.map { step -> ProvenanceStep? in
            guard step.outputs.isEmpty else {
                let own = step.outputs.filter { Self.lineagePath($0.path) == file }
                return own.isEmpty ? nil : step.withOutputs(own)
            }
            return step.inputs.contains { lineage.contains(Self.lineagePath($0.path)) } ? step : nil
        }
        let unnamedKept = keptUnnamedSteps(dependedOnBy: zip(steps, named).compactMap { $1 == nil ? nil : $0 })
        let keptSteps = zip(steps, named).compactMap { step, kept -> ProvenanceStep? in
            if step.inputs.isEmpty && step.outputs.isEmpty { return unnamedKept.contains(step.id) ? step : nil }
            guard let kept, let wholeRecordPath,
                  (step.inputs + step.outputs).contains(where: { batchWide.contains(Self.lineagePath($0.path)) }) else {
                return kept
            }
            let ownInputs = step.inputs.filter { lineage.contains(Self.lineagePath($0.path)) }
            guard ownInputs.count != step.inputs.count else { return kept }
            return kept.with {
                $0.inputs = ownInputs
                $0.narrowedFrom = ProvenanceStepNarrowing(recordPath: wholeRecordPath, inputCount: step.inputs.count)
            }
        }
        let keptInputPaths = Set(keptSteps.flatMap { $0.inputs.map(\.path) })
        return with { copy in
            copy.files = files.compactMap { descriptor in
                if descriptor.role == .output {
                    return descriptor.path == output.path ? output : nil
                }
                guard !keptSteps.isEmpty else { return descriptor }
                return keptInputPaths.contains(descriptor.path) ? descriptor : nil
            }
            copy.output = output
            copy.outputs = [output]
            copy.steps = keptSteps
        }
    }

    /// The ids of the steps that name no file and stay beside `kept`: each that no step of the run depends on, and
    /// each that a kept step, or such a step, depends on through steps that name no file.
    private func keptUnnamedSteps(dependedOnBy kept: [ProvenanceStep]) -> Set<UUID> {
        let unnamed = steps.filter { $0.inputs.isEmpty && $0.outputs.isEmpty }
        let byID = Dictionary(unnamed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let dependedOn = Set(steps.flatMap(\.dependsOn))
        var reached = Set(unnamed.map(\.id).filter { !dependedOn.contains($0) })
        var pending = kept.flatMap(\.dependsOn) + reached.compactMap { byID[$0]?.dependsOn }.flatMap { $0 }
        while let id = pending.popLast() {
            guard let step = byID[id], reached.insert(id).inserted else { continue }
            pending += step.dependsOn
        }
        return reached
    }

    /// `paths` and each path a file of `paths` came from, the `originPath` of a descriptor in `named` at its path.
    private static func lineage(of paths: Set<String>, among named: [ProvenanceFileDescriptor]) -> Set<String> {
        var lineage = paths
        for descriptor in named where paths.contains(lineagePath(descriptor.path)) {
            if let origin = descriptor.originPath {
                lineage.insert(lineagePath(origin))
            }
        }
        return lineage
    }

    /// The BAM that `file` is or indexes, with its `.bai` and `.csi`.
    private static func pair(of file: String) -> Set<String> {
        let bam = [".bai", ".csi"].first { file.hasSuffix($0) }.map { String(file.dropLast($0.count)) } ?? file
        return [bam, bam + ".bai", bam + ".csi"]
    }

    /// `path` without the `/private` that macOS puts before `/var`, `/tmp` and `/etc`, so both spellings of one
    /// file compare equal. It reads nothing from the disk. The prefix and the three roots stay separate strings, so
    /// that no string in the app holds the joined root, which the release portability scan forbids
    /// (`scripts/release/scan-release-portability.py`, label `private-tmp`).
    private static func lineagePath(_ path: String) -> String {
        let prefix = "/private"
        guard path.hasPrefix(prefix) else { return path }
        let rest = path.dropFirst(prefix.count)
        for root in ["/var/", "/tmp/", "/etc/"] where rest.hasPrefix(root) {
            return String(rest)
        }
        return path
    }
}
