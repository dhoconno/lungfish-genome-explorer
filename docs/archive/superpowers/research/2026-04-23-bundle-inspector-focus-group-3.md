# Bundle Inspector Focus Group 3

Date: 2026-04-23

## Group Lens

This focus group simulates biologists with strong biological judgment and practical wet-lab experience, but limited familiarity with sequencing file formats, alignment rendering controls, and BAM track-management concepts. Their frame of reference is closer to sample review, assay interpretation, and operational traceability than to viewer architecture.

## Participant Archetypes

- Molecular diagnostics director: comfortable judging coverage, variants, and assay quality, but expects terminology to map to clinical review tasks rather than file-processing concepts.
- Clinical genomics lab manager: understands reference, sample, and run provenance; expects clear separation between source data, derived outputs, and reportable artifacts.
- Senior technologist for infectious disease sequencing: experienced with alignments in practice, but wants obvious workflow cues and does not assume knowledge of BAM flags, MAPQ, or track provenance.

## Current-State Confusion Points

- The right-side Inspector uses icon-only tabs in multi-tab modes. `doc.text` and `cursorarrow.click` do not clearly mean "overview/provenance" versus "selected item and display controls" to this audience.
- The tab name `Selection` is too broad. In practice it contains selected feature/read details, annotation settings, sample display controls, read display controls, duplicate workflows, variant calling, and BAM filtering. That feels like a mixed utilities drawer rather than a coherent "selection" view.
- Auto-switching to `Selection` when a read or annotation is clicked will feel like the sidecar changed context on its own. Users with a diagnostics mindset may read that as losing their place rather than being helped.
- `Document` is understandable for a file, but less so for a mapping result or bundle with multiple tracks. This group would expect wording closer to "Overview", "Run Summary", or "Bundle Summary".
- BAM-filter entry points are buried inside `ReadStyleSection`, after many display and consensus controls. Users looking to create a derived alignment are unlikely to look inside what appears to be a rendering/settings area.
- The section title `Create Filtered Track` does not clearly communicate that this creates a new alignment result saved alongside the original, rather than temporarily filtering what is visible on screen.
- Terms like `Primary Only`, `MAPQ`, `Read Groups`, `Exact Matches Only`, and `Duplicates` are too compressed for this persona without helper text. They are recognizable to bioinformatics staff, but not self-explanatory to applied lab users.
- The success message says a filtered alignment track was created, but does not explain where to find it in the sidebar or how it relates to the source track. Reload behavior alone is not enough for discoverability.

## Wording This Group Would Understand Better

- Replace icon-only tab meaning with text labels such as `Overview` and `Selected Item`.
- Rename `Selection` to `Selected Item & View` if it must continue to contain both details and controls.
- Rename `Create Filtered Track` to `Create New Filtered Alignment`.
- Rename `Source Track` to `Starting Alignment`.
- Rename `Output Track Name` to `Name for New Alignment`.
- Add plain-language helper text:
  - `This creates a new alignment and keeps the original unchanged.`
  - `Minimum MAPQ (alignment confidence)`
  - `Primary alignments only (hide alternate/extra placements)`
  - `Exclude marked duplicates` and `Remove duplicates before saving new alignment`
- Use `Derived Alignments` or `Filtered Alignments` in user-facing language instead of relying on the word `track` alone.

## Expected Mental Model for a New Filtered Alignment

- Users would expect the original BAM/alignment to remain visible and unchanged.
- They would expect the new filtered alignment to appear as a separate sibling item directly under the same alignment area in the sidebar, not silently replace the source.
- They would expect an obvious visual cue after creation: auto-select the new item, reveal it in the sidebar, or show an inline message such as `New filtered alignment added under Alignments`.
- They would expect the new item name to preserve the source relationship, for example `Sample A alignment` and `Sample A alignment - filtered`.
- If the product stores filtered BAMs under an internal folder such as `alignments/filtered/`, that storage detail should stay internal. The user-facing model should stay "new derived alignment in this bundle".

## What Feels Overloaded or Intimidating

- The `Selection` sidecar is overloaded because it combines object inspection, styling, filtering, consensus, duplicate workflows, variant calling, and BAM derivation in one vertical stack.
- The read display area is intimidating because it mixes temporary view settings with durable data-creation actions. This makes it hard to tell what changes the screen versus what creates a new artifact.
- Consensus controls will feel advanced and unfamiliar to this persona when placed next to routine review tasks. They raise the apparent complexity of the whole panel.
- Duplicate handling plus filtered-track creation in the same area can read like destructive processing unless the UI repeatedly states that the original remains intact.
- Icon-only navigation increases cognitive load because users must remember symbols before they can reason about workflow.

## Prioritized Recommendations

1. Make Inspector tabs explicit with text labels, not icons alone. `Overview` and `Selected Item` would be immediately clearer than the current segmented symbols.
2. Separate durable alignment actions from view/display controls. Put BAM filtering and duplicate workflows in a clearly named subsection such as `Derived Alignments` or `Create New Alignment`.
3. State the outcome in plain language before launch and after completion: `Creates a new alignment. Original alignment stays unchanged.`
4. Improve discoverability of the new filtered result by revealing or selecting the new sidebar item after reload and naming where it was added.
5. Reduce jargon or annotate it inline. Where technical terms must remain, pair them with short biological or operational explanations.

## Three Main Conclusions

- This audience will not infer workflow meaning from the current icon/tab setup; text labels are needed.
- The current `Selection` sidecar feels conceptually crowded, especially because temporary display controls and permanent BAM-derivation actions are mixed together.
- Filtered BAM creation is understandable only if the UI makes the destination and relationship explicit: a new sibling alignment, separately visible from the original source BAM.
