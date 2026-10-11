// Kraken2Command.swift - The kraken2 command group
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser

/// The `kraken2` group, whose one subcommand is `classify`.
///
/// `kraken2 classify` is `ClassifyCommand`, the type that `conda` has always
/// registered as `conda classify` (plan decision S19, vote V14). The group lists
/// the type itself and never a wrapper, because tests, `RecordedCLICommand` among
/// them, cast a parsed root to `ClassifyCommand`, and a run records the command
/// line as it was typed. Recorded commands keep `conda classify` until
/// sub-phase 2.7, so no builder in the app changes. The group sits at the top
/// level beside `esviritu` and `taxtriage` so the root help shows Kraken2 as the
/// peer of the other two classifiers.
struct Kraken2Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kraken2",
        abstract: "Run Kraken2 taxonomic classification, with optional Bracken abundance profiling",
        discussion: """
        Classify metagenomic reads or assembled sequences against an installed
        Kraken2 database, and add a Bracken abundance profile with --profile.
        Manage databases with `lungfish-cli conda db`.

        `lungfish-cli conda classify` is the older spelling of the same command
        and still works.
        """,
        subcommands: [
            ClassifyCommand.self,
        ]
    )
}
