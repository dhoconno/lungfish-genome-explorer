// GenotypeSmartCohortSection.swift - Inspector Document tab section listing genotype smart cohorts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishKit
import LungfishCore
import LungfishIO

/// Inspector Document tab section listing `GenotypeCohortSmartFilter` saved cohorts with counts.
///
/// Each row shows the cohort name, a star icon for user-scope cohorts, the matching subject count,
/// and a contextual delete button. Tapping a row selects the cohort; the "+ Add" affordance at the
/// bottom invokes `onAdd` so the caller can present a "Save current filter" sheet.
///
/// The viewer's active cohort, the one state the filter bar pill also reads, shows with a
/// checkmark and the selected accessibility trait, and a second click on it clears it (walk star
/// 10). Restore Built-In Cohorts is enabled when a built-in cohort is missing (plan decision S13).
public struct GenotypeSmartCohortSection: View {
    private let typographyModel = ContentTypographyModel.shared
    private var contentBodyFont: Font { typographyModel.font(for: .body) }
    private var contentHeadingFont: Font { typographyModel.font(for: .emphasizedBody) }

    public struct DisplayedCohort: Identifiable, Equatable {
        public let filter: GenotypeCohortSmartFilter
        public let count: Int
        /// Whether this is the viewer's active cohort.
        public var isActive: Bool
        public var id: String { filter.name + "/" + filter.scope }

        public init(filter: GenotypeCohortSmartFilter, count: Int, isActive: Bool = false) {
            self.filter = filter
            self.count = count
            self.isActive = isActive
        }
    }

    /// What a row shows and tells assistive technology.
    public struct RowPresentation: Equatable {
        public let showsCheckmark: Bool
        public let isSelected: Bool
        public let accessibilityLabel: String
        public let accessibilityValue: String
        public let accessibilityHint: String
    }

    let cohorts: [DisplayedCohort]
    var onSelect: (GenotypeCohortSmartFilter) -> Void
    var onDelete: (GenotypeCohortSmartFilter) -> Void
    var onAdd: () -> Void
    var onRestoreBuiltIns: (() -> Void)?

    @State private var isExpanded = true

    public init(
        cohorts: [DisplayedCohort],
        onSelect: @escaping (GenotypeCohortSmartFilter) -> Void,
        onDelete: @escaping (GenotypeCohortSmartFilter) -> Void,
        onAdd: @escaping () -> Void,
        onRestoreBuiltIns: (() -> Void)? = nil
    ) {
        self.cohorts = cohorts
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.onAdd = onAdd
        self.onRestoreBuiltIns = onRestoreBuiltIns
    }

    /// The id of the active cohort, or nil when no cohort filters the viewer.
    public var activeCohortID: String? {
        cohorts.first(where: \.isActive)?.id
    }

    /// The built-in cohorts the list lacks, which Restore Built-In Cohorts brings back.
    public var restorableBuiltInNames: [String] {
        let shown = Set(cohorts.map(\.filter.name))
        return GenotypeAnnotationStore.builtInSmartCohorts.map(\.name).filter { !shown.contains($0) }
    }

    public static func rowPresentation(for cohort: DisplayedCohort) -> RowPresentation {
        let matches = cohort.count == 1 ? "1 sample" : "\(cohort.count) samples"
        return RowPresentation(
            showsCheckmark: cohort.isActive,
            isSelected: cohort.isActive,
            accessibilityLabel: cohort.filter.name,
            accessibilityValue: cohort.isActive ? "Active, \(matches)" : matches,
            accessibilityHint: cohort.isActive
                ? "Clears this cohort filter."
                : "Filters the viewer to this cohort."
        )
    }

    /// The rows for `filters`, each counting the subjects its predicate matches,
    /// with the viewer's active cohort marked.
    public static func displayedCohorts(
        _ filters: [GenotypeCohortSmartFilter],
        subjects: [GenotypeCohortSubject],
        active: GenotypeCohortSmartFilter? = nil
    ) -> [DisplayedCohort] {
        marking(filters.map { filter in
            DisplayedCohort(filter: filter, count: subjects.filter { filter.predicate.evaluate($0) }.count)
        }, active: active)
    }

    /// `cohorts` with only the row of `active`, matched by name and scope, marked active.
    public static func marking(_ cohorts: [DisplayedCohort], active: GenotypeCohortSmartFilter?) -> [DisplayedCohort] {
        cohorts.map { cohort in
            var marked = cohort
            marked.isActive = active.map { $0.name == cohort.filter.name && $0.scope == cohort.filter.scope } ?? false
            return marked
        }
    }

    public var body: some View {
        DisclosureGroup("Smart Cohorts", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                if cohorts.isEmpty {
                    Text("No saved cohorts.")
                        .font(contentBodyFont)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(cohorts) { cohort in
                        cohortRow(cohort)
                    }
                }

                Button(action: onAdd) {
                    Label("Save Current Filter\u{2026}", systemImage: "plus.circle")
                        .font(contentBodyFont)
                }
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .padding(.top, 4)
                .accessibilityIdentifier("genotypeSmartCohortAddButton")

                if let onRestoreBuiltIns {
                    Button(action: onRestoreBuiltIns) {
                        Label("Restore Built-In Cohorts", systemImage: "arrow.uturn.backward.circle")
                            .font(contentBodyFont)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.regular)
                    .disabled(restorableBuiltInNames.isEmpty)
                    .help(restorableBuiltInNames.isEmpty
                        ? "Every built-in cohort is in the list."
                        : "Bring back " + restorableBuiltInNames.joined(separator: ", "))
                    .accessibilityIdentifier("genotypeSmartCohortRestoreButton")
                }
            }
            .padding(.top, 4)
        }
        .font(contentHeadingFont)
    }

    @ViewBuilder
    private func cohortRow(_ cohort: DisplayedCohort) -> some View {
        let presentation = Self.rowPresentation(for: cohort)
        // The delete button is an icon, so these words are all a person hears or reads. They name the cohort, since
        // every row has the same button (walk WO-7).
        let removeLabel = "Remove \(cohort.filter.name)"
        let deleteHelp = "Delete the \(cohort.filter.name) cohort"
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
                        .font(contentBodyFont)
                        .fontWeight(cohort.isActive ? .semibold : .regular)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if presentation.showsCheckmark {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityIdentifier("genotypeSmartCohortActiveCheckmark")
                    }
                    Text("\(cohort.count)")
                        .font(contentBodyFont.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityValue(presentation.accessibilityValue)
            .accessibilityHint(presentation.accessibilityHint)
            .accessibilityAddTraits(presentation.isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("genotypeSmartCohortRow")

            Button(action: { onDelete(cohort.filter) }) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .help(deleteHelp)
            .accessibilityLabel(removeLabel)
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
