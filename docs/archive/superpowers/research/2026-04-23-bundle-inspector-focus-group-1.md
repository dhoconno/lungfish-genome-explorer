# Bundle Inspector Focus Group 1

Date: 2026-04-23

## Group Lens

This focus group simulates biologists with strong organism, assay, and surveillance knowledge, but limited familiarity with alignment file formats, track models, and sequencing-visualization conventions. Their mental model is closer to "sample, reference, mapped reads, consensus, variant support" than to "bundle, track, BAM, metadata DB, provenance sidecar."

## Participant Archetypes

1. Wet-lab virology lead
Works on outbreak response, amplicon validation, and genome finishing. Comfortable asking whether reads support a primer dropout or mixed infection signal. Not comfortable with BAM jargon.

2. Pathogen surveillance scientist
Reviews routine mapping outputs across many samples and wants to quickly confirm coverage, contamination concerns, and whether a filtered subset represents "cleaner reads" for interpretation.

3. Clinical research associate
Understands mapping quality in a general sense, but expects the software to explain what is being filtered and where the new result lives without needing to understand track architecture.

## Current-State Confusion Points

- The right Inspector uses icon-only tabs. `doc.text` and `cursorarrow.click` are not self-explanatory for this group. They would not reliably infer "analysis overview" versus "selected feature and read settings."
- `Document` and `Selection` are software-centric labels, not biology-task labels. A wet-lab user is more likely to look for "Run Details," "Reads," or "Filtering."
- BAM filtering appears inside the `Selection` tab, mixed with annotation editing, appearance controls, sample display, read display, duplicate workflows, consensus, and variant calling. That feels buried and conceptually unrelated.
- The `Selection` tab auto-switches when a read or annotation is clicked. That makes the filtering controls feel unstable or easy to lose.
- In the mapping `Document` sidecar, terms like `Source Data`, `Mapping Context`, and `Source Artifacts` are understandable only after orientation. `Artifacts` in particular sounds technical and indirect.
- The current wording assumes the user understands the difference between the mapping analysis directory, copied viewer bundle, bundle alignment track, and source BAM. This group would not.
- `Source Track`, `Output Track Name`, `Create Filtered Alignment Track`, and the success message about a `filtered alignment track` all rely on the word "track." Many participants would think in terms of "new alignment result" or "new read set," not track objects.
- Filter labels like `Primary Only`, `Minimum MAPQ`, `Exact Matches Only`, and duplicate mode choices such as `Exclude Marked` are not self-explanatory without help text in plain language.
- The success alert confirms creation, but it does not answer the first practical question: "Where did it go, and how do I compare it to the original?"

## Wording This Group Would Understand Better

Preferred tab/sidecar language:

- `Overview` instead of `Document`
- `Selected Feature` or `Reads & Features` instead of `Selection`
- `Run Inputs` instead of `Source Data`
- `Run Settings` instead of `Mapping Context`
- `Output Files` instead of `Source Artifacts`

Preferred BAM/filtering language:

- `Source alignment` or `Original alignment` instead of `Source Track`
- `New filtered alignment name` instead of `Output Track Name`
- `Create new filtered alignment` instead of `Create Filtered Alignment Track`
- `Keep mapped reads only` instead of `Mapped Only`
- `Keep best alignment only` instead of `Primary Only`
- `Minimum alignment confidence` instead of `Minimum MAPQ`
- `Remove duplicate reads` or `Hide duplicate-marked reads` instead of `Duplicates: Exclude Marked`
- `Keep perfect matches only` only if backed by a short note explaining that this uses alignment tags, not re-alignment

## Expected Findability Of A Newly Created Filtered Alignment

This group would expect the new result to appear immediately and separately from the source alignment, not just be silently added somewhere inside the same bundle.

Expected behavior:

- The new filtered alignment should appear as its own visible item in the alignment list/sidebar right after creation.
- It should remain next to the original alignment so the relationship is obvious.
- The source alignment should stay unchanged and still be selectable.
- The new item should include a plain-language derived label such as `Filtered from: Sample 1 alignment`.
- The app should optionally auto-select the new filtered alignment after creation, or offer a direct button like `Show New Filtered Alignment`.

What they would look for first:

- a new row under the same sample or alignment area
- a name containing `filtered`, `deduplicated`, or the specific filter summary
- a visual cue that distinguishes derived outputs from original imported alignments

## What Feels Overloaded Or Intimidating

- The `Selection` tab is overloaded because it combines feature editing, viewer styling, sample controls, read display controls, consensus settings, duplicate actions, variant calling, and BAM derivation in one long surface.
- The mixture of temporary display settings and permanent file-creating actions is especially intimidating. Users may not know whether they are just changing the view or generating a new dataset.
- Terms such as `track`, `MAPQ`, `primary`, `supplementary`, `provenance`, and `artifacts` add cognitive load when stacked together.
- A long control list with toggles, steppers, technical acronyms, and multiple workflow buttons signals "expert-only" rather than "guided analysis."
- Mapping-specific context is spread across one tab, while filtering actions are embedded in another. That separation makes the workflow harder to understand end to end.

## Prioritized Recommendations

1. Make the Inspector tabs text-labeled and task-labeled.
Use names like `Overview` and `Reads & Filtering`, not icon-only tabs and generic software nouns.

2. Separate permanent BAM derivation from temporary read display controls.
Put filtering in its own clearly named subsection or tab so users understand that it creates a new alignment result.

3. Use plain-language filter labels with short explanatory helper text.
Users should understand each filter without knowing SAM flags or BAM conventions.

4. Make the post-filter destination explicit.
After creation, show exactly where the new filtered alignment appears and offer one-click navigation to it.

5. Label derived outputs as related but separate.
The new filtered alignment should visually state that it was created from the original alignment, so comparison is obvious and accidental replacement is not feared.

## Top Design Takeaways

- This audience can understand the biological purpose of filtering quickly, but not the current information architecture.
- The biggest usability problem is not the existence of BAM filters; it is that permanent derivation actions are hidden inside an overloaded `Selection` surface and described with track-management language.
- Discoverability will improve most if the product clearly answers three questions in plain language: what am I filtering, what will be created, and where will the new result appear?
