// ExtractReadsCommand+Provenance.swift - The command a record of lungfish-cli extract reads names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

extension ExtractReadsSubcommand {

    func provenanceCommand(outputURL: URL) -> [String] {
        var command = [CLICommandIdentity.executableName, "extract", "reads"]
        if byId {
            command.append("--by-id")
            if let idsFile {
                command += ["--ids", idsFile]
            }
            if let bamFile {
                command += ["--bam", bamFile]
                if includeSecondaryFlag {
                    command.append("--include-secondary")
                }
                if excludeDuplicatesFlag {
                    command.append("--exclude-duplicates")
                }
                command += ["--read-format", classifierFormat]
            } else {
                for sourceFile in sourceFiles {
                    command += ["--source", sourceFile]
                }
                if keepReadPairs {
                    command.append("--keep-read-pairs")
                }
                if noKeepReadPairs {
                    command.append("--no-keep-read-pairs")
                }
            }
        } else if byRegion {
            command.append("--by-region")
            if let bamFile {
                command += ["--bam", bamFile]
            }
            for region in regions {
                command += ["--region", region]
            }
            if excludeUnmapped {
                command.append("--exclude-unmapped")
            }
        } else if byDb {
            command.append("--by-db")
            if let databaseFile {
                command += ["--database", databaseFile]
            }
            if let sample {
                command += ["--db-sample", sample]
            }
            for taxID in taxIds {
                command += ["--db-taxid", taxID]
            }
            for accession in accessions {
                command += ["--db-accession", accession]
            }
            if let maxReads {
                command += ["--max-reads", "\(maxReads)"]
            }
        } else {
            command.append("--by-classifier")
            if let classifierTool {
                command += ["--tool", classifierTool]
            }
            if let classifierResult {
                command += ["--result", classifierResult]
            }
            command += classifierSelectionReplayArguments(rawArgs: effectiveClassifierRawArguments())
            command += ["--read-format", classifierFormat]
            if includeUnmappedMates {
                command.append("--include-unmapped-mates")
            }
        }
        command += ["--output", outputURL.path]
        if createBundle {
            command.append("--bundle")
        }
        if let bundleName {
            command += ["--bundle-name", bundleName]
        }
        command += timeLimit.argumentWords
        return command
    }
}
