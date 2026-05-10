# Bundle Inspector Focus Group 2

Date: 2026-04-23

## Group Lens

Independent focus group simulating biologists with strong comparative-genomics and annotation literacy, but limited familiarity with BAM internals, sequencing QC jargon, and bundle/track-management concepts.

## Participant Archetypes

- Comparative genomics PI who compares gene structure and synteny across species, and uses alignments mainly to check support for annotation calls.
- Genome annotation curator who spends most of the day in feature tables, exon models, CDS boundaries, and evidence tracks, but does not think in BAM flags.
- Evolutionary genomics postdoc who is comfortable with loci, transcripts, and structural interpretation, but expects read evidence tools to explain themselves in biological terms.

## Current-State Confusion Points

- The Inspector tabs are icon-only in multi-tab mode. This group would not reliably infer `Document` versus `Selection` from `doc.text` and `cursorarrow.click`.
- The right sidecar does not read like a biology workflow. `Document` sounds administrative, while `Selection` sounds like it should only show the currently selected feature, not broad viewer controls and BAM actions.
- `Selection` is overloaded. It appears to mix selected-feature details, annotation controls, sample controls, read display options, consensus settings, duplicate workflows, variant calling, and BAM filtering in one place.
- `ReadStyleSection` mixes temporary display settings with data-producing actions. A biologist can understand "show mismatches" as view state, but "Create Filtered Track" in the same section feels like a different category of action.
- `Create Filtered Track` is discoverable only after scrolling through a long expert-oriented panel. It does not stand out as "make a new derived alignment."
- The filter wording assumes BAM literacy. `MAPQ`, `Primary Only`, `Duplicates`, `Exact Matches Only`, and `% identity` are not self-explanatory to annotation-heavy users.
- The success language says a filtered alignment track was created, but does not clearly answer the user's first question: "Where did it go, and did it replace my original BAM?"
- The bundle model is hidden. Biology users will think in terms of "original alignment" and "new derived alignment," not "same bundle under alignments/filtered."

## Wording This Group Would Understand Better

- Replace icon-only tabs with visible text labels.
- Prefer `Dataset` or `Alignment Set` over `Document` in mapping/alignment contexts.
- Prefer `Selected Feature` or `Feature / Read Details` over `Selection`.
- Prefer `View Settings` for temporary display controls.
- Prefer `Create New Alignment Subset` or `Save Filtered Alignment as New Track` over `Create Filtered Track`.
- Prefer `Alignment to filter` over `Source Track`.
- Prefer `Keep mapped reads only` over `Mapped Only`.
- Prefer `Keep one primary alignment per read` over `Primary Only`.
- Prefer `Minimum alignment confidence` with `MAPQ` shown secondarily, not as the main label.
- Prefer `Duplicate handling` with options explained as biological outcomes, for example `Keep all reads`, `Hide reads already marked as duplicates`, `Find and remove duplicate reads first`.
- Prefer `Keep reads with zero mismatches to reference` over `Exact Matches Only`.
- Prefer `Minimum identity to reference (%)` over `Minimum % identity`.
- Prefer `Name of new derived alignment` over `Output Track Name`.

## How This Group Expects To Find a Newly Created Filtered Alignment

- As a separate alignment entry, not as a silent modification of the source BAM.
- Immediately visible in the left alignment list or track list after creation.
- Positioned next to the source alignment, or nested under it as a derived child.
- Labeled with an obvious relationship such as `Filtered from <source name>` or a `Derived` / `Filtered` badge.
- Auto-selected or highlighted after creation so users do not have to hunt for it.
- Shown with the original alignment still present, so the distinction between source and derived data is unmistakable.

## What Feels Overloaded or Intimidating

- One right-side panel that asks users to understand feature selection, styling, consensus, duplicate processing, variant calling, and BAM filtering at once feels like an expert console, not a guided biology workflow.
- The density of sequencing terms is intimidating: `MAPQ`, `read groups`, `duplicates`, `primary`, `supplementary`, `consensus`, and identity filters appear before the user has a simple mental model of what they are changing.
- The current structure makes it too easy to confuse "change how this alignment looks" with "create a new derived alignment file."
- `Document` plus icon-only tabs makes the sidecar feel generic and software-centric rather than focused on biological interpretation.

## Prioritized Recommendations

1. Replace icon-only Inspector tabs with text labels, and use mapping/alignment-specific names that describe user intent rather than internal UI structure.
2. Split temporary read-display controls from data-creating workflows. `View Settings` and `Create New Alignment Subset` should be separate sections.
3. Add explicit plain-language guidance that filtering creates a new alignment track and does not alter the source alignment.
4. Reword BAM filter controls around biological outcomes, with technical terms shown as secondary help text rather than primary labels.
5. After creation, automatically reveal and select the new filtered alignment and show its relationship to the source track in the track list and confirmation message.

## Bottom Line

This group can understand why a filtered alignment is useful, but the current Inspector asks them to learn the software's internal model before they can act. The main design need is not more power. It is clearer separation between `viewing`, `selected-item details`, and `create a new derived alignment`, plus language that explains read filtering in biological terms.
