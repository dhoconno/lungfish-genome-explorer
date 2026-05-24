// GenotypeSmartCohortSection.swift - Inspector Document tab section listing genotype smart cohorts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore
import LungfishIO

/// Inspector Document tab section listing `GenotypeCohortSmartFilter` saved cohorts with counts.
///
/// Each row shows the cohort name, a star icon for user-scope cohorts, the matching subject count,
/// and a contextual delete button. Tapping a row selects the cohort; the "+ Add" affordance at the
/// bottom invokes `onAdd` so the caller can present a "Save current filter" sheet.
struct GenotypeSmartCohortSection: View {
    struct DisplayedCohort: Identifiable, Equatable {
        let filter: GenotypeCohortSmartFilter
        let count: Int
        var id: String { filter.name + "/" + filter.scope }

        init(filter: GenotypeCohortSmartFilter, count: Int) {
            self.filter = filter
            self.count = count
        }
    }

    let cohorts: [DisplayedCohort]
    var onSelect: (GenotypeCohortSmartFilter) -> Void
    var onDelete: (GenotypeCohortSmartFilter) -> Void
    var onAdd: () -> Void

    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup("Smart Cohorts", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if cohorts.isEmpty {
                    Text("No saved cohorts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(cohorts) { cohort in
                        cohortRow(cohort)
                    }
                }

                Button(action: onAdd) {
                    Label("Save Current Filter\u{2026}", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.top, 4)
                .accessibilityIdentifier("genotypeSmartCohortAddButton")
            }
            .padding(.top, 4)
        }
        .font(.caption.weight(.semibold))
    }

    @ViewBuilder
    private func cohortRow(_ cohort: DisplayedCohort) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: { onSelect(cohort.filter) }) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: cohort.filter.isStarred ? "star.fill" : "star")
                        .foregroundStyle(
                            cohort.filter.scope == "user" || cohort.filter.isStarred
                            ? Color.accentColor
                            : Color.secondary
                        )
                        .accessibilityIdentifier("genotypeSmartCohortStar")
                    Text(cohort.filter.name)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(cohort.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("genotypeSmartCohortRow")

            Button(action: { onDelete(cohort.filter) }) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Delete cohort")
            .accessibilityIdentifier("genotypeSmartCohortDeleteButton")
        }
    }
}

#if DEBUG
#Preview("Smart Cohorts") {
    ScrollView {
        GenotypeSmartCohortSection(
            cohorts: [
                .init(
                    filter: GenotypeCohortSmartFilter(
                        name: "Needs Review",
                        scope: "bundle",
                        isStarred: false,
                        predicate: .hasAnalystFlag(.needsReview)
                    ),
                    count: 7
                ),
                .init(
                    filter: GenotypeCohortSmartFilter(
                        name: "Bw6+ carriers",
                        scope: "user",
                        isStarred: true,
                        predicate: .commentContains("Bw6")
                    ),
                    count: 12
                ),
                .init(
                    filter: GenotypeCohortSmartFilter(
                        name: "Homozygous at A",
                        scope: "bundle",
                        isStarred: false,
                        predicate: .isHomozygousAcrossAll
                    ),
                    count: 3
                ),
            ],
            onSelect: { _ in },
            onDelete: { _ in },
            onAdd: { }
        )
        .padding()
    }
    .frame(width: 280, height: 220)
}
#endif
