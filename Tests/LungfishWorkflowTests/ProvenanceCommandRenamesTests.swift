// ProvenanceCommandRenamesTests.swift - The folders a rename moved, read from one record, and the command they move
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishWorkflow

/// Phase 2.12 lane 12.25, R-B2. The mapper reads a rename from the record alone and moves only resolved paths inside
/// the project (SWIFT 6). None of these calls touches the file system.
struct ProvenanceCommandRenamesTests {
    private let project = URL(fileURLWithPath: "/Volumes/Lab/Runs.lungfish", isDirectory: true)
    private var record: URL { project.appendingPathComponent("Analyses/trim renamed/.lungfish-provenance.json") }
    private let command = "fastp -i /Volumes/Lab/Runs.lungfish/Inputs/r.fq -o /Volumes/Lab/Runs.lungfish/Analyses/trim/out.fq"

    private func renames(_ command: String, files: [String]) -> [ProvenanceFolderRename] {
        ProvenanceCommandPresentation.folderRenames(
            commands: [command], filePaths: files, recordURL: record, projectURL: project
        )
    }

    @Test func aCommandThatNamesTheOldSiblingOfTheRecordsFolderMovesIntoIt() {
        let found = renames(command, files: ["/Volumes/Lab/Runs.lungfish/Inputs/r.fq", "/Volumes/Lab/Runs.lungfish/Analyses/trim renamed/out.fq"])
        #expect(found == [ProvenanceFolderRename(
            oldPath: "/Volumes/Lab/Runs.lungfish/Analyses/trim", newPath: "/Volumes/Lab/Runs.lungfish/Analyses/trim renamed"
        )])
        #expect(ProvenanceCommandPresentation.movingRenamedPaths(command, renames: found, projectURL: project)
            == "fastp -i /Volumes/Lab/Runs.lungfish/Inputs/r.fq -o '/Volumes/Lab/Runs.lungfish/Analyses/trim renamed/out.fq'")
        #expect(ProvenanceCommandPresentation.renameNote(found, projectURL: project)
            == "This command ran in Analyses/trim. The row and Copy Command name Analyses/trim renamed, where the record is now.")
    }

    @Test func noFileAtTheSamePathBelowTheNewFolderMeansNoRename() {
        #expect(renames(command, files: ["/Volumes/Lab/Runs.lungfish/Analyses/trim renamed/other.fq"]).isEmpty)
    }

    @Test func aFolderTheRecordsFilesStillNameWasNotRenamed() {
        let files = ["/Volumes/Lab/Runs.lungfish/Analyses/trim renamed/out.fq", "/Volumes/Lab/Runs.lungfish/Analyses/trim/kept.fq"]
        #expect(renames(command, files: files).isEmpty)
    }

    @Test func aHiddenWorkingFolderIsLeftAsRecorded() {
        let staged = "bgzip -f /Volumes/Lab/Runs.lungfish/Analyses/.trim.building/out.fq"
        #expect(renames(staged, files: ["/Volumes/Lab/Runs.lungfish/Analyses/trim renamed/out.fq"]).isEmpty)
    }

    @Test func unresolvedOutsideAndClimbingPathsStayAsRecorded() {
        let files = ["/Volumes/Lab/Runs.lungfish/Analyses/trim renamed/out.fq"]
        #expect(renames("fastp -o <workspace>/Analyses/trim/out.fq", files: files).isEmpty)
        #expect(renames("fastp -o /Volumes/Other.lungfish/Analyses/trim/out.fq", files: files).isEmpty)
        #expect(renames("fastp -o /Volumes/Lab/Runs.lungfish/../Runs.lungfish/Analyses/trim/out.fq", files: files).count == 1)
        #expect(renames("fastp -o /Volumes/Lab/Runs.lungfish/Analyses/../../Analyses/trim/out.fq", files: files).isEmpty)
    }

    /// Lane 13.45, ARCH C1. A Move keeps the folder's name and changes its parent, at any depth under the project.
    @Test func aMoveIntoAnotherFolderIsReadAsTheSameRelocation() {
        let movedRecord = project.appendingPathComponent("Analyses/Group/trim/.lungfish-provenance.json")
        let found = ProvenanceCommandPresentation.folderRenames(
            commands: [command],
            filePaths: ["/Volumes/Lab/Runs.lungfish/Inputs/r.fq", "/Volumes/Lab/Runs.lungfish/Analyses/Group/trim/out.fq"],
            recordURL: movedRecord, projectURL: project
        )
        #expect(found == [ProvenanceFolderRename(
            oldPath: "/Volumes/Lab/Runs.lungfish/Analyses/trim", newPath: "/Volumes/Lab/Runs.lungfish/Analyses/Group/trim"
        )])
        let toRoot = ProvenanceCommandPresentation.folderRenames(
            commands: [command], filePaths: ["/Volumes/Lab/Runs.lungfish/trim/out.fq"],
            recordURL: project.appendingPathComponent("trim/.lungfish-provenance.json"), projectURL: project
        )
        #expect(toRoot.map(\.oldPath) == ["/Volumes/Lab/Runs.lungfish/Analyses/trim"])
    }

    /// Two old folders that could each have moved to the record's folder map neither, and a Move that also renames
    /// is not read (the Known limit).
    @Test func twoOldFoldersForOneNewFolderAndAMoveWithARenameMapNothing() {
        let movedRecord = project.appendingPathComponent("Analyses/Group/trim/.lungfish-provenance.json")
        let files = ["/Volumes/Lab/Runs.lungfish/Analyses/Group/trim/out.fq"]
        let both = command + " --also /Volumes/Lab/Runs.lungfish/Other/trim/out.fq"
        #expect(ProvenanceCommandPresentation.folderRenames(
            commands: [both], filePaths: files, recordURL: movedRecord, projectURL: project
        ).isEmpty)
        let renamedToo = project.appendingPathComponent("Analyses/Group/trim 2/.lungfish-provenance.json")
        #expect(ProvenanceCommandPresentation.folderRenames(
            commands: [command], filePaths: ["/Volumes/Lab/Runs.lungfish/Analyses/Group/trim 2/out.fq"],
            recordURL: renamedToo, projectURL: project
        ).isEmpty)
    }

    @Test func aSiblingWhoseNameExtendsTheOldFoldersStaysAsRecorded() {
        let found = [ProvenanceFolderRename(
            oldPath: "/Volumes/Lab/Runs.lungfish/Analyses/trim", newPath: "/Volumes/Lab/Runs.lungfish/Analyses/trim renamed"
        )]
        let both = "cat /Volumes/Lab/Runs.lungfish/Analyses/trim-2/a.fq --out=/Volumes/Lab/Runs.lungfish/Analyses/trim/a.fq"
        #expect(ProvenanceCommandPresentation.movingRenamedPaths(both, renames: found, projectURL: project)
            == "cat /Volumes/Lab/Runs.lungfish/Analyses/trim-2/a.fq '--out=/Volumes/Lab/Runs.lungfish/Analyses/trim renamed/a.fq'")
        let script = "/bin/sh -c 'cat /Volumes/Lab/Runs.lungfish/Analyses/trim/a.fq > /Volumes/Lab/Runs.lungfish/Analyses/trim/b.fq'"
        let movedScript = ProvenanceCommandPresentation.movingRenamedPaths(script, renames: found, projectURL: project)
        let words = ProvenanceCommandPresentation.split(movedScript)?.compactMap { piece -> String? in
            if case .word(let word) = piece { return word.value }
            return nil
        }
        #expect(words?.prefix(2) == ["/bin/sh", "-c"])
        #expect(words.flatMap { ProvenanceCommandPresentation.pathWords(of: $0[2], projectURL: project) } == [
            "/Volumes/Lab/Runs.lungfish/Analyses/trim renamed/a.fq", "/Volumes/Lab/Runs.lungfish/Analyses/trim renamed/b.fq",
        ])
        #expect(ProvenanceCommandPresentation.movingRenamedPaths(command, renames: [], projectURL: project) == command)
    }
}
